//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc.
//
// Licensed under the MIT license (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// LICENSE
//
//===----------------------------------------------------------------------===//

#include "bridge.h"
#include "utility.h"

#include "program_description.h"
#include "visual_program_builder.h"
#include "visual_shader_node_wrapper.h"

#include "VisualNodes/VisualShaderNodeOutput.h"
#include "VisualNodes/VisualShaderNodeVarying.h"
#include "snippets.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/visual_shader_node_varying_getter.hpp>
#include <godot_cpp/core/error_macros.hpp>

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>

#define ENABLE_SGL_COMMENT 0
#define PRINT_SGL_CODE 0

using namespace gdrk;
using namespace godot;
using VS = godot::VisualShader;

#pragma mark - VisualProgramMetadata

int VisualProgramMetadata::version = 3;

godot::String VisualProgramMetadata::serialize(int p_version) {
	godot::Dictionary metadata;
	godot::Array uniform_array;

	metadata.set("version", p_version);
	metadata.set("is_transparent", is_transparent);

	for (auto desc : uniforms) {
		godot::Dictionary uniform;
		uniform.set("shader_type", desc.shader_type);
		uniform.set("node_type", desc.node_type);
		uniform.set("node_index", desc.node_index);
		uniform_array.push_back(uniform);
	}
	metadata.set("uniforms", uniform_array);

	return JSON::stringify(metadata);
}

bool VisualProgramMetadata::unserialize(godot::String p_json, const godot::Ref<godot::VisualShader> &p_shader, VisualProgramMetadata &p_out) {
	if (!p_shader.is_valid()) {
		return false;
	}
	godot::Dictionary metadata = JSON::parse_string(p_json);
	int version = metadata.get("version", -99999999);
	if (version != VisualProgramMetadata::version) {
		ERR_PRINT(std::format("VisualProgramMetadata: invalid version. Expected {}, got: {}. Consider re-exporting your project", VisualProgramMetadata::version, version).c_str());
		return false;
	}
	p_out.is_transparent = metadata.get("is_transparent", false);
	godot::Array uniforms = metadata.get("uniforms", godot::Array());

	uint32_t index = 0;
	for (godot::Dictionary uniform : uniforms) {
		// Extracting uniform metadata
		gdrk::VisualShaderNodeType node_type = (gdrk::VisualShaderNodeType)(uint8_t)uniform.get("node_type", gdrk::VisualShaderNodeType::Unknown);
		uint32_t node_index = (uint32_t)uniform.get("node_index", UINT32_MAX);
		gdrk::ShaderType shader_type = (gdrk::ShaderType)(uint8_t)uniform.get("shader_type", gdrk::ShaderType::ST_COUNT);
		godot::VisualShader::Type godot_shader_type = shader_type == gdrk::ShaderType::ST_VERTEX ? godot::VisualShader::Type::TYPE_VERTEX
																								 : godot::VisualShader::Type::TYPE_FRAGMENT;
		godot::Ref<godot::VisualShaderNode> node = p_shader->get_node(godot_shader_type, node_index);
		if (!node.is_valid()) {
			ERR_PRINT(std::format("VisualProgramMetadata: invalid node retrieved for at index {}", node_index).c_str());
			return false;
		}

		VisualShaderNodeProcTable &vtable = VisualShaderNodeProcTable::all_tables[node_type];
		godot::String expected_class_name = node->get_class();
		if (expected_class_name != vtable.type_name()) {
			ERR_PRINT(std::format("VisualProgramMetadata: invalid class name retrieved on runtime shader. Expected: {}, got: {}", vtable.type_name(), to_std_string(expected_class_name)).c_str());
			return false;
		}

		// Rebuilding uniform descriptor from not iteself.
		OptionalUniformDescriptor udesc = vtable.get_uniform_descriptor(node.ptr(), shader_type, node_index);

		if (udesc == std::nullopt) {
			ERR_PRINT(std::format("VisualProgramMetadata: Failed to unserialize metadata: uniform {} references a node that doesn't produce a parameter.", index).c_str());
			return false;
		}

		udesc->shader_type = shader_type;
		udesc->node_index = node_index;
		udesc->node_type = node_type;

		p_out.uniforms.push_back(*udesc);
		index++;
	}

	return true;
}

#pragma mark - VisualProgramBuilderContext

std::string VisualProgramBuilderContext::get_input_expression(uint32_t p_connection_index, ShaderType p_shader_type) {
	const Connection &c = all_connections[p_shader_type][p_connection_index];
	const VisualShaderNodeWrapper &node = all_nodes[p_shader_type][c.src_index];
	return node.get_input_expression(*this, c.src_port);
}

#pragma mark - VisualProgramBuilder

inline godot::VisualShader::Type to_godot_shader_type(gdrk::ShaderType p_type) {
	return p_type == ShaderType::ST_VERTEX ? godot::VisualShader::Type::TYPE_VERTEX
										   : godot::VisualShader::Type::TYPE_FRAGMENT;
}

void print_dict(const godot::Dictionary &dict) {
	godot::Array keys = dict.keys();
	for (godot::Variant key : keys) {
		godot::Variant value = dict[key];

		UtilityFunctions::print(key.stringify() + " -> " + value.stringify());
	}
}

void print_code(const std::vector<std::string> &p_code_parts) {
	int index = 0;
	for (auto part : p_code_parts) {
		index++;
		UtilityFunctions::print(part.c_str());
	}
}

VisualProgramBuilder::VisualProgramBuilder(swift::Optional<GodotRealityKit::Compiler> p_compiler,
		const ShaderMaterialDescription &p_description) :
		compiler(p_compiler), shader(p_description.shader) {
	context.material_description = &p_description;
}

bool VisualProgramBuilder::check_for_errors(const char *step) {
	if (context.warnings.size() > context.warning_index) {
		WARN_PRINT(std::format("{} - Warnings: ////////////////////////////////////////////////////////", step).c_str());
		for (uint32_t i = context.warning_index; i < context.warnings.size(); i++) {
			WARN_PRINT(context.warnings[i].c_str());
		}
		WARN_PRINT("////////////////////////////////////////////////////////");
		context.warning_index = (uint32_t)context.warnings.size();
	}

	if (context.errors.size()) {
		ERR_PRINT(std::format("{} - Errors: ////////////////////////////////////////////////////////", step).c_str());
		for (const std::string &error : context.errors) {
			ERR_PRINT(error.c_str());
		}
		ERR_PRINT("////////////////////////////////////////////////////////");
		return false;
	}

	return true;
}

#define STAGE(step, content)           \
	{                                  \
		content;                       \
		if (!check_for_errors(step)) { \
			return false;              \
		}                              \
	}

bool VisualProgramBuilder::build(swift::Array<GodotRealityKit::ProgramPart> &p_program_parts) {
	context.varying_allocator.reset();
	context.all_connections[ShaderType::ST_VERTEX].clear();
	context.all_connections[ShaderType::ST_FRAGMENT].clear();
	context.errors.clear();
	context.all_connections[ShaderType::ST_VERTEX].push_back(Connection::Invalid());
	context.all_connections[ShaderType::ST_FRAGMENT].push_back(Connection::Invalid());

	STAGE("Graph initialization", build_graph());
	STAGE("Uniform binding", analyze_graph());
	STAGE("Varying allocations", allocate_varyings());
	STAGE("SGL generation", generate_sgl());
	STAGE("Material compilation", {
		for (const std::string &code_part : context.code_parts) {
			swift::Optional<GodotRealityKit::ProgramPart> opt_program_part = compiler.get().parse(code_part, false);
			if (opt_program_part.isNone()) {
				ERR_FAIL_V_MSG(false, "Unable to generate material ShaderGraph: error parsing source snippet.");
			}

			p_program_parts.append(opt_program_part.get());
		}
	});

	return true;
}

void VisualProgramBuilder::fill_nodes(ShaderType p_type) {
	godot::VisualShader::Type godot_type = to_godot_shader_type(p_type);
	PackedInt32Array node_list = shader->get_node_list(godot_type);
	context.max_node_indices[p_type] = 0;
	context.node_count[p_type] = static_cast<unsigned int>(node_list.size());

	for (int32_t idx : node_list) {
		context.max_node_indices[p_type] = godot::MAX(context.max_node_indices[p_type], idx);
		if (idx >= context.all_nodes[p_type].size()) {
			context.all_nodes[p_type].resize(idx + 1);
		}

		VisualShaderNodeWrapper &node_wrapper = context.all_nodes[p_type][idx];
		node_wrapper.initialize(context, p_type, shader->get_node(godot_type, idx).ptr(), idx);
		if (context.all_nodes[p_type][idx].node_type == VisualShaderNodeType::VisualShaderNodeOutput ||
				context.all_nodes[p_type][idx].node_type == VisualShaderNodeType::VisualShaderNodeVaryingSetter) {
			context.output_nodes[p_type].push_back(idx);
		}

		if (!node_wrapper.supported()) {
			context.errors.push_back(std::format("Use of unsupported node type: {}", node_wrapper.type_name()));
		}

		if (node_wrapper.declares_uniforms()) {
			context.uniform_declarators[p_type].push_back(idx);
		}
	}
}

void VisualProgramBuilder::fill_connections(ShaderType p_type) {
	godot::VisualShader::Type godot_type = to_godot_shader_type(p_type);
	TypedArray<Dictionary> connection_list = shader->get_node_connections(godot_type);
	for (const godot::Dictionary connection : connection_list) {
		uint32_t src_index = connection["from_node"];
		uint32_t src_port = connection["from_port"];

		uint32_t dst_index = connection["to_node"];
		uint32_t dst_port = connection["to_port"];

		VisualShaderNodeWrapper *src_node = &context.all_nodes[p_type][src_index];
		VisualShaderNodeWrapper *dst_node = &context.all_nodes[p_type][dst_index];
		if (!dst_node->supported() || !src_node->supported()) {
			return;
		}

		uint32_t connection_index = context.all_connections[p_type].size();
		Connection c = {
			.src_index = src_index,
			.src_port = src_port,
			.dst_index = dst_index,
			.dst_port = dst_port,
		};
		if (!c.is_valid()) {
			continue;
		}
		context.all_connections[p_type].push_back(std::move(c));
		dst_node->upstream_connections[dst_port] = connection_index;
		src_node->downstream_connections.push_back(connection_index);
	}
}

void VisualProgramBuilder::traverse_graph(ShaderType p_type,
		std::function<void(VisualShaderNodeWrapper &)> p_callback) {
	for (uint32_t node_index : context.traversal_buffers[p_type]) {
		VisualShaderNodeWrapper &node = context.all_nodes[p_type][node_index];
		p_callback(node);
	}
}

void VisualProgramBuilder::fill_node_declarations(ShaderType p_type) {
	gdrk::LocalBitVector type_declared;

	type_declared.resize(VisualShaderNodeType::Count);
	traverse_graph(p_type, [&type_declared, this](VisualShaderNodeWrapper &node) {
		if (type_declared.has(node.node_type)) {
			return;
		}

		node.sg_declare(context);
		type_declared.insert(node.node_type);
	});
}

void VisualProgramBuilder::fill_node_expressions(ShaderType p_type) {
	traverse_graph(p_type, [&](VisualShaderNodeWrapper &node) {
		node.sg_expression(context);
		node.fill_swizzle_outputs(context);
	});
}

void VisualProgramBuilder::build_stage(ShaderType p_type) {
	fill_nodes(p_type);
	fill_connections(p_type);
}

void VisualProgramBuilder::build_traversal_buffer(ShaderType p_type) {
	uint32_t buffer_size = context.max_node_indices[p_type] + 1;

	int depths[buffer_size];
	std::vector<uint32_t> visitor_buffer;

	// Traverse the whole graph to create a topologically sorted list of node to traverse the graph
	// that can then be reused for various traversal. Topological traversal has to happen at least once
	// in order to output the code it the right order, so we run it once at the begining and cache traversal
	// result in the builder context

	for (int i = 0; i < buffer_size; i++) {
		depths[i] = -1; // node not visited at all and shouldn't be part of the traversal
	}

	uint32_t read_index = 0;
	int depth = 0;
	for (uint32_t output_index : context.output_nodes[p_type]) {
		depths[output_index] = depth++;
		visitor_buffer.push_back(output_index);
	}

	while (read_index < visitor_buffer.size()) {
		uint32_t node_index = visitor_buffer[read_index++];
		int depth = depths[node_index];
		VisualShaderNodeWrapper &node = context.all_nodes[p_type][node_index];
		for (uint32_t connection_index : node.upstream_connections) {
			const Connection &connection = context.all_connections[p_type][connection_index];

			if (!connection.is_valid()) {
				continue;
			}
			int recorded_depth = depths[connection.src_index];
			int new_depth = depth + 1;
			if (recorded_depth >= new_depth) {
				continue;
			}
			depths[connection.src_index] = new_depth;
			visitor_buffer.push_back(connection.src_index);
		}
	}

	context.traversal_buffers[p_type].clear();
	context.traversal_buffers[p_type].reserve(context.node_count[p_type]);

	for (int i = 0; i < buffer_size; i++) {
		if (depths[i] >= 0) {
			context.traversal_buffers[p_type].push_back(i);
		}
	}

	std::sort(context.traversal_buffers[p_type].begin(), context.traversal_buffers[p_type].end(), [&](uint32_t idx1, uint32_t idx2) {
		return depths[idx1] > depths[idx2];
	});
}

void VisualProgramBuilder::build_graph() {
	build_stage(ShaderType::ST_VERTEX);

	// Move `VisualShaderNodeOutput` at the end of the traversal
	std::vector<uint32_t> &vertex_output_nodes = context.output_nodes[ShaderType::ST_VERTEX];
	for (int i = 1; i < vertex_output_nodes.size(); i++) {
		uint32_t node_index = vertex_output_nodes[i];
		uint8_t node_type = context.all_nodes[ShaderType::ST_VERTEX][node_index].node_type;
		if (node_type == VisualShaderNodeType::VisualShaderNodeOutput) {
			std::swap(vertex_output_nodes[i], vertex_output_nodes[0]);
			break;
		}
	}
	build_traversal_buffer(ShaderType::ST_VERTEX);

	build_stage(ShaderType::ST_FRAGMENT);
	build_traversal_buffer(ShaderType::ST_FRAGMENT);
}

void VisualProgramBuilder::analyze_graph(ShaderType p_shader_type) {
	godot::LocalVector<uint32_t> &declarators = context.uniform_declarators[p_shader_type];
	for (uint32_t index : declarators) {
		VisualShaderNodeWrapper &node = context.all_nodes[p_shader_type][index];
		node.analyze(context);
	}
}

void VisualProgramBuilder::analyze_graph() {
	analyze_graph(ShaderType::ST_VERTEX);
	analyze_graph(ShaderType::ST_FRAGMENT);
}

void VisualProgramBuilder::allocate_varyings() {
	if (context.uv_is_default && !context.uv_used) {
		context.varying_allocator.release_uv0_slot();
	}

	if (context.uv2_is_default && !context.uv2_used) {
		context.varying_allocator.release_uv1_slot();
	}

	// Traverse the graph to find the connected VisualShaderNodeVaryingGetter and allocate their varyings
	traverse_graph(ShaderType::ST_FRAGMENT, [this](VisualShaderNodeWrapper &p_node_wrapper) {
		if (p_node_wrapper.node_type == VisualShaderNodeType::VisualShaderNodeVaryingGetter) {
			godot::VisualShaderNodeVaryingGetter *node = (godot::VisualShaderNodeVaryingGetter *)p_node_wrapper.node;
			PortType type = vs::to_port_type(node->get_varying_type());
			godot::String name = node->get_varying_name();
			std::string error;
			const VaryingAllocator::VaryingDescriptor *desc = context.varying_allocator.allocate(name, type, error);
			if (!desc) {
				context.errors.push_back(std::format("Failed to allocate varying '{}': {}", to_std_string(name), error));
			}
		}
	});
}

void VisualProgramBuilder::comment(std::string p_str, uint8_t p_lines_after) {
	static uint32_t i = 0;

	context.code_parts.push_back(std::format("let c{} =                                       \"{}\";", i++, p_str));
	for (int j = 0; j < p_lines_after; j++) {
		context.code_parts.push_back("");
	}
}

void VisualProgramBuilder::section(const char *p_str, std::function<void()> p_callback) {
#if ENABLE_SGL_COMMENT
	comment(std::format("-------------- {}", p_str), 1);
	p_callback();
	comment("------------------------------------------", 4);
#else
	p_callback();
#endif
}

void VisualProgramBuilder::fill_uniform_declarations() {
	for (auto shader_type : { gdrk::ShaderType::ST_VERTEX, gdrk::ShaderType::ST_FRAGMENT }) {
		traverse_graph(shader_type, [shader_type, this](VisualShaderNodeWrapper &p_node_wrapper) {
			OptionalUniformDescriptor udesc = p_node_wrapper.get_uniform_descriptor();
			if (udesc == std::nullopt) {
				return;
			}

			udesc->node_index = p_node_wrapper.index;
			udesc->node_type = p_node_wrapper.node_type;
			udesc->shader_type = shader_type;

			context.uniforms.insert(udesc->name, *udesc);
		});
	}

	for (auto &descIt : context.uniforms) {
		UniformDescriptor &desc = descIt.value;
		godot::VisualShader::Type godot_shader_type = (desc.shader_type == gdrk::ShaderType::ST_VERTEX) ? godot::VisualShader::Type::TYPE_VERTEX
																										: godot::VisualShader::Type::TYPE_FRAGMENT;
		godot::Ref<godot::VisualShaderNode> node = shader->get_node(godot_shader_type, desc.node_index);
		VisualShaderNodeProcTable &vtable = VisualShaderNodeProcTable::all_tables[desc.node_type];
		context.code_parts.push_back(std::format("uniform {}: {} = {}", to_std_string(desc.name), port_type_name(desc.type), gdrk::stringify_value(desc.type, desc.default_value)));
	}
}

void VisualProgramBuilder::generate_sgl() {
	section("Header", [this]() {
		context.code_parts.push_back(sgl::builtin::constants());
		context.code_parts.push_back(sgl::builtin::utility_functions());
		context.code_parts.push_back(sgl::builtin::color_functions());
		context.code_parts.push_back(sgl::builtin::swizzle());
		context.code_parts.push_back(sgl::builtin::vertex::attributes(&context.material_description->render_mode));
		context.code_parts.push_back(sgl::builtin::cast_declarations());
	});

	section("Uniform Declaration", [this]() {
		fill_uniform_declarations();
	});

	section("Vertex Declarations", [this]() {
		fill_node_declarations(ShaderType::ST_VERTEX);
	});

	section("Fragment Declarations", [this]() {
		fill_node_declarations(ShaderType::ST_FRAGMENT);
	});

	section("Vertex Expressions", [this]() {
		fill_node_expressions(ShaderType::ST_VERTEX);
	});

	section("fill_uv_read_declarations()", [this]() {
		context.varying_allocator.fill_uv_read_declarations(context);
	});

	section("Fragment Expressions", [this]() {
		fill_node_expressions(ShaderType::ST_FRAGMENT);
	});

	context.code_parts.push_back("(geometry_modifier, surface_shader);");

#if PRINT_SGL_CODE
	UtilityFunctions::print("Generated code: ////////////////////////////////////////////////////////");
	UtilityFunctions::print(context.material_description->shader->get_path());
	print_code(context.code_parts);
	UtilityFunctions::print("////////////////////////////////////////////////////////");
#endif
}

// pragma - bind_uniform
template <PortType T>
void bind_uniform(GodotRealityKit::SGLProgram &, ShaderMaterialDescription &, const UniformDescriptor &) { ERR_FAIL_MSG(std::format("Unsupported uniform type:", port_type_name(T)).c_str()); }

template <>
void bind_uniform<PortType::BOOL>(GodotRealityKit::SGLProgram &p_program, ShaderMaterialDescription &, const UniformDescriptor &p_uniform) {
	p_program.bindBoolParameter(to_swift_string(p_uniform.name), (bool)p_uniform.default_value);
}

template <>
void bind_uniform<PortType::INT>(GodotRealityKit::SGLProgram &p_program, ShaderMaterialDescription &, const UniformDescriptor &p_uniform) {
	p_program.bindIntParameter(to_swift_string(p_uniform.name), (int32_t)p_uniform.default_value);
}

template <>
void bind_uniform<PortType::FLOAT>(GodotRealityKit::SGLProgram &p_program, ShaderMaterialDescription &, const UniformDescriptor &p_uniform) {
	p_program.bindFloatParameter(to_swift_string(p_uniform.name), (float)p_uniform.default_value);
}
template <>
void bind_uniform<PortType::VEC2F>(GodotRealityKit::SGLProgram &p_program, ShaderMaterialDescription &, const UniformDescriptor &p_uniform) {
	godot::Vector2 v = (godot::Vector2)p_uniform.default_value;
	p_program.bindFloat2Parameter(to_swift_string(p_uniform.name), GodotRealityKit::Vector2::init(v.x, v.y));
}

template <>
void bind_uniform<PortType::VEC3F>(GodotRealityKit::SGLProgram &p_program, ShaderMaterialDescription &, const UniformDescriptor &p_uniform) {
	godot::Vector3 v = (godot::Vector3)p_uniform.default_value;
	p_program.bindFloat3Parameter(to_swift_string(p_uniform.name), GodotRealityKit::Vector3::init(v.x, v.y, v.z));
}

template <>
void bind_uniform<PortType::VEC4F>(GodotRealityKit::SGLProgram &p_program, ShaderMaterialDescription &, const UniformDescriptor &p_uniform) {
	godot::Vector4 v = (godot::Vector4)p_uniform.default_value;
	godot::Variant::Type godot_type = p_uniform.default_value.get_type();
	if (godot_type == godot::Variant::QUATERNION) {
		godot::Quaternion v = (godot::Quaternion)p_uniform.default_value;
		p_program.bindFloat4Parameter(to_swift_string(p_uniform.name), GodotRealityKit::Vector4::init(v.x, v.y, v.z, v.w));
	} else if (godot_type == godot::Variant::COLOR) {
		godot::Color v = ((godot::Color)p_uniform.default_value).srgb_to_linear();
		p_program.bindFloat4Parameter(to_swift_string(p_uniform.name), GodotRealityKit::Vector4::init(v.r, v.g, v.b, v.a));
	} else {
		godot::Vector4 v = (godot::Vector4)p_uniform.default_value;
		p_program.bindFloat4Parameter(to_swift_string(p_uniform.name), GodotRealityKit::Vector4::init(v.x, v.y, v.z, v.w));
	}
}

template <>
void bind_uniform<PortType::SAMPLER2D>(GodotRealityKit::SGLProgram &p_program, ShaderMaterialDescription &p_desc, const UniformDescriptor &p_uniform) {
	uint8_t index = p_program.bindTextureParameter(to_swift_string(p_uniform.name), GodotRealityKit::TextureResource::init());
	p_desc.texture_idxs.push_back(index);
}

DEFINE_ENUM_FUNCTION_TABLE(bind_uniform_table, PortType, PT_COUNT, bind_uniform)
void bind_uniform(PortType p_port_type, GodotRealityKit::SGLProgram &p_program, ShaderMaterialDescription &p_desc, const UniformDescriptor &p_uniform) {
	bind_uniform_table[p_port_type](p_program, p_desc, p_uniform);
}

void VisualProgramBuilder::finalize(ShaderMaterialDescription &p_desc, GodotRealityKit::SGLProgram &p_program) {
	const bool is_transparent = p_desc.is_transparent();
	const bool no_depth_test = p_desc.render_mode.get_flag(RenderModeDescription::FLAG_DEPTH_TEST_DISABLED);
	const bool depth_prepass = p_desc.render_mode.get_flag(RenderModeDescription::FLAG_DEPTH_PREPASS_ALPHA);

#define WARN_UNSUPPORTED_BLEND_MODE(mode)                                                                        \
	if (p_desc.render_mode.blend == RenderModeDescription::BlendMode::BLEND_##mode) {                            \
		WARN_COMPAT_MSG("Blend mode " #mode " not supported when rendering with RealityKit, defaulting to MIX"); \
	}

	WARN_UNSUPPORTED_BLEND_MODE(ADD)
	WARN_UNSUPPORTED_BLEND_MODE(SUB)
	WARN_UNSUPPORTED_BLEND_MODE(MUL)
	WARN_UNSUPPORTED_BLEND_MODE(PREMUL_ALPHA)

	if (p_desc.render_mode.depth_test == RenderModeDescription::DEPTH_TEST_INVERTED) {
		WARN_COMPAT_MSG("Depth test INVERTED not supported when rendering with RealityKit");
	}

#define WARN_UNSUPPORTED_FLAG(flag, godot_flag)                                              \
	if (p_desc.render_mode.get_flag(RenderModeDescription::flag)) {                          \
		WARN_COMPAT_MSG(godot_flag " ON, but not supported when rendering with RealityKit"); \
	}

	WARN_UNSUPPORTED_FLAG(FLAG_SSS_MODE_SKIN, "flags/sss_mode_skin")
	WARN_UNSUPPORTED_FLAG(FLAG_WIREFRAME, "flags/wireframe")
	WARN_UNSUPPORTED_FLAG(FLAG_DEPTH_PREPASS_ALPHA, "flags/depth_prepass_alpha ")
	WARN_UNSUPPORTED_FLAG(FLAG_WORLD_VERTEX_COORDS, "flags/world_vertex_coords")
	WARN_UNSUPPORTED_FLAG(FLAG_ENSURE_CORRECT_NORMALS, "flags/ensure_correct_normals")
	WARN_UNSUPPORTED_FLAG(FLAG_SHADOWS_DISABLED, "flags/shadow_disabled")
	WARN_UNSUPPORTED_FLAG(FLAG_AMBIENT_LIGHT_DISABLED, "flags/ambient_light_disabled")
	WARN_UNSUPPORTED_FLAG(FLAG_SHADOW_TO_OPACITY, "flags/shadow_to_opacity")
	WARN_UNSUPPORTED_FLAG(FLAG_VERTEX_LIGHTING, "flags/vertex_lighting")
	WARN_UNSUPPORTED_FLAG(FLAG_PARTICLE_TRAILS, "flags/particle_trails")
	WARN_UNSUPPORTED_FLAG(FLAG_ALPHA_TO_COVERAGE, "flags/alpha_to_coverage")
	WARN_UNSUPPORTED_FLAG(FLAG_ALPHA_TO_COVERAGE_AND_ONE, "flags/alpha_to_coverage_and_one")
	WARN_UNSUPPORTED_FLAG(FLAG_DEBUG_SHADOW_SPLITS, "flags/debug_shadow_splits")
	WARN_UNSUPPORTED_FLAG(FLAG_FOG_DISABLED, "flags/fog_disabled")
	WARN_UNSUPPORTED_FLAG(FLAG_SPECULAR_OCCLUSION_DISABLED, "flags/specular_occlusion_disabled")

	p_program.setCullMode(p_desc.render_mode.cull);

	if (is_transparent) {
		p_program.setSortOrder(p_desc.render_priority);
		p_program.setSortGroup(p_desc.depth_pass_mode == DepthPassMode::DepthPostpass ? 2 : 1); // depth postPass vs. standard transparency
	}

	p_program.setReadsDepth(!no_depth_test);

	switch (p_desc.render_mode.depth_draw) {
		case RenderModeDescription::DEPTH_DRAW_OPAQUE: {
			p_program.setWritesDepth(!is_transparent && !no_depth_test);
			break;
		}
		case RenderModeDescription::DEPTH_DRAW_ALWAYS: {
			p_program.setWritesDepth(!no_depth_test);
			break;
		}
		case RenderModeDescription::DEPTH_DRAW_NEVER: {
			p_program.setWritesDepth(false);

			break;
		}
		default: {
			WARN_COMPAT_MSG("Unhandled depth draw mode");
		}
	}

	uint32_t index = 0;
	for (const UniformDescriptor &uniform : p_desc.uniforms) {
		bind_uniform(uniform.type, p_program, p_desc, uniform);
		if (uniform.type == PortType::SAMPLER2D) {
			p_desc.texture_idxs.push_back(index);
			godot::RID rid = (godot::RID)uniform.default_value;
			if (rid.is_valid()) {
				p_desc.const_texture_idxs.push_back(index);
			}
		}
		++index;
	}
}
