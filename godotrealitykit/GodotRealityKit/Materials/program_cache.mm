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

#import "program_cache.h"
#import "bridge.h"

#import "Loaders/Resources/material_loader.h"
#import "base_material_builder.h"
#import "node_defs.h"
#import "snippets.h"
#import "visual_program_builder.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_loader.hpp>

static GodotRealityKit::SGLMaterial broken_material = GodotRealityKit::SGLMaterial::brokenMaterial();

namespace gdrk {

ProgramCache::ProgramCache(ProgramLoadedCallback &&callback, const char *p_export_directory) :
		notify_program_loaded(std::move(callback)), compiler(GodotRealityKit::Compiler::init(get_node_def_files())), export_directory(p_export_directory) {
}

godot::String ProgramCache::read_file(godot::String p_path) const {
	godot::Ref<godot::FileAccess> file = godot::FileAccess::open(p_path, godot::FileAccess::READ);
	if (!file.is_valid()) {
		return "";
	}

	return file->get_as_text();
}

godot::String ProgramCache::read_from_cache(godot::String p_path) const {
	godot::String prefix = export_directory + godot::String("/");
	godot::String cache_path = p_path.replace("res://", prefix);
	return read_file(cache_path);
}

void ProgramCache::load_usda(uint32_t p_base_program_idx, swift::String &content) {
	GodotRealityKit::SGLProgram::load("/bm", content,
			GDRKMaterialLoadDelegate([this, p_base_program_idx](void *p_material_load_result) {
				GodotRealityKit::SGLMaterialLoadResult material_load_result =
						GodotRealityKit::SGLMaterialLoadResult::fromRawPointer(p_material_load_result);

				gdrk::emplace_replace(&base_programs[p_base_program_idx].value, material_load_result.getResult());
				base_loading_idxs.remove(p_base_program_idx);

				if (material_load_result.getErrorDescription().isSome()) {
					GodotRealityKit::errPrint(material_load_result.getErrorDescription().getSome());
				}

				finalize_pending_variants(p_base_program_idx);
			}));
}

bool ProgramCache::make_usda(uint32_t p_base_program_idx,
		const swift::Array<GodotRealityKit::ProgramPart> &p_program_parts) {
	swift::Optional<swift::String> program_usda = compiler.get().compile(p_program_parts);
	bool success = false;
	if (!program_usda.isNone()) {
		success = true;
		swift::String usda = program_usda.get();
		load_usda(p_base_program_idx, usda);
	}

	return success;
}

bool ProgramCache::load_usda_from_file(uint32_t p_base_program_idx, godot::String p_resource_path) {
	godot::String usda_content = read_from_cache(p_resource_path);
	if (usda_content.length() == 0) {
		ERR_PRINT(std::format("Failed to load USDA associated with {} from cache directory", to_std_string(p_resource_path)).c_str());
		return false;
	}
	swift::String usda = to_swift_string(usda_content);
	load_usda(p_base_program_idx, usda);
	return true;
}

uint32_t ProgramCache::alloc_variant(const ProgramDescription &p_desc) {
	const uint32_t variant_idx = programs.size();
	programs.push_back(Program({
			.description = p_desc,
	}));

	program_loading_idxs.resize(programs.size());
	program_loading_idxs.insert(variant_idx);
	program_description_to_idx.insert(p_desc.hash, variant_idx);
	return variant_idx;
}

void ProgramCache::finalize_variant(uint32_t p_variant_idx, uint32_t p_base_idx) {
	gdrk::emplace_replace(&programs[p_variant_idx].value, base_programs[p_base_idx].value.makeVariant());

	GodotRealityKit::SGLProgram &program = programs[p_variant_idx].value;
	ProgramDescription &desc = programs[p_variant_idx].description;

	if (desc.material_type == MATERIAL_TYPE_BASE_MATERIAL3D) {
		BaseMaterialBuilder::finalize(desc.asBaseMaterial3D(), program);
	} else if (desc.material_type == MATERIAL_TYPE_SHADER_MATERIAL) {
		const ShaderMaterialDescription &base_shader = base_programs[p_base_idx].description.asShaderMaterial();
		ShaderMaterialDescription &variant_shader = desc.asShaderMaterial();
		variant_shader.uniforms = base_shader.uniforms;
		variant_shader.transparent = base_shader.transparent;
		VisualProgramBuilder::finalize(desc.asShaderMaterial(), program);
	} else {
		programs[p_variant_idx].value.setIsBrokenMaterial(true);
	}

	program_loading_idxs.remove(p_variant_idx);
	notify_program_loaded(p_variant_idx);
}

void ProgramCache::finalize_pending_variants(uint32_t p_base_index) {
	if (auto pending_variants = loading_variants.getptr(p_base_index)) {
		for (uint32_t pending_variant : *pending_variants) {
			finalize_variant(pending_variant, p_base_index);
		}
		loading_variants.erase(p_base_index);
	}
}

bool ProgramCache::load_cached_visual_shader(uint32_t p_base_program_index, ShaderMaterialDescription &p_program_description) {
	godot::Ref<godot::VisualShader> shader = p_program_description.shader;
	godot::String resource_path = shader->get_path();

	godot::String metadata_string = read_from_cache(resource_path + ".meta.json");
	if (loading_mode != LoadingMode::DISABLE_CACHE && metadata_string.length() != 0) {
		VisualProgramMetadata meta;
		bool success = VisualProgramMetadata::unserialize(metadata_string, shader, meta);
		if (success) {
			p_program_description.uniforms = meta.uniforms;
			p_program_description.transparent = meta.is_transparent;
			success = load_usda_from_file(p_base_program_index, resource_path + ".usda");

			if (success) {
				return true;
			}
		}
	}

	return false;
}

template <>
bool ProgramCache::create_program_async<MaterialType::MATERIAL_TYPE_SHADER_MATERIAL>(uint32_t p_base_program_idx, ProgramDescription &p_program_description) {
	ShaderMaterialDescription &description = p_program_description.asShaderMaterial();
	godot::Ref<godot::VisualShader> shader = description.shader;
	if (!shader.is_valid()) {
		return false;
	}

	bool success = load_cached_visual_shader(p_base_program_idx, description);
	if (success) {
		return true;
	}

	if (loading_mode == LoadingMode::FORCE_CACHE) {
		return false;
	}

	VisualProgramBuilder builder(compiler, p_program_description.asShaderMaterial());
	swift::Array<GodotRealityKit::ProgramPart> program_parts = swift::Array<GodotRealityKit::ProgramPart>::init();
	success = builder.build(program_parts);
	if (!success) {
		return false;
	}

	VisualProgramMetadata meta = builder.get_metadata();
	description.uniforms = meta.uniforms;
	description.transparent = meta.is_transparent;
	return make_usda(p_base_program_idx, program_parts);
}

template <>
bool ProgramCache::create_program_async<MaterialType::MATERIAL_TYPE_BASE_MATERIAL3D>(uint32_t p_base_program_idx, ProgramDescription &p_program_description) {
	BaseMaterialBuilder builder(compiler, p_program_description.asBaseMaterial3D());
	swift::Array<GodotRealityKit::ProgramPart> program_parts = swift::Array<GodotRealityKit::ProgramPart>::init();
	bool success = builder.build(program_parts);
	if (!success) {
		return false;
	}

	return make_usda(p_base_program_idx, program_parts);
}

void ProgramCache::preload_program(godot::String p_path) {
	godot::Ref<godot::Resource> resource = godot::ResourceLoader::get_singleton()->load(p_path);
	if (!resource.is_valid()) {
		return;
	}

	godot::Ref<godot::VisualShader> visual_shader = godot::Object::cast_to<godot::VisualShader>(resource.ptr());
	if (visual_shader.is_valid()) {
		ShaderMaterialDescription shader_desc(visual_shader.ptr(), 0);
		ProgramDescription desc(shader_desc);
		preload_base_program(desc);
		preloaded_materials.push_back(resource);
		return;
	}

	godot::Ref<godot::Material> material = godot::Object::cast_to<godot::Material>(resource.ptr());
	if (material.is_valid()) {
		ProgramDescription desc = MaterialLoader::program_description_for_material(*material.ptr());
		if (!desc.is_valid()) {
			return;
		}

		preload_base_program(desc);
		preloaded_materials.push_back(resource);
	}
}

bool ProgramCache::preload_base_program(const ProgramDescription &p_program_description) {
	const uint32_t base_hash = p_program_description.base_program_hash;
	if (auto *found_base = base_program_hash_to_base_idx.getptr(base_hash)) {
		return true;
	}

	const uint32_t base_idx = base_programs.size();
	base_programs.push_back(BaseProgram({ .description = p_program_description }));

	ProgramDescription &base_program_description = base_programs[base_idx].description;
	base_loading_idxs.resize(base_programs.size());
	base_loading_idxs.insert(base_idx);
	base_program_hash_to_base_idx.insert(base_hash, base_idx);

	bool success = false;
	if (base_program_description.material_type == MATERIAL_TYPE_BASE_MATERIAL3D) {
		success = create_program_async<MATERIAL_TYPE_BASE_MATERIAL3D>(base_idx, base_program_description);
	} else if (base_program_description.material_type == MATERIAL_TYPE_SHADER_MATERIAL) {
		success = create_program_async<MATERIAL_TYPE_SHADER_MATERIAL>(base_idx, base_program_description);
	}

	if (!success) {
		base_loading_idxs.remove(base_idx);
		base_program_hash_to_base_idx.erase(base_hash);
	}

	return success;
}

uint32_t ProgramCache::create_program_async(const ProgramDescription &p_program_description) {
	if (compiler.isNone()) {
		return UINT32_MAX;
	}

	if (auto found_program = program_description_to_idx.find(p_program_description.hash)) {
		return found_program->value;
	}

	const uint32_t base_hash = p_program_description.base_program_hash;
	const uint32_t variant_idx = alloc_variant(p_program_description);

	if (auto *found_base = base_program_hash_to_base_idx.getptr(base_hash)) {
		const uint32_t base_idx = *found_base;

		if (!base_loading_idxs.has(base_idx)) {
			finalize_variant(variant_idx, base_idx);
		} else {
			loading_variants[base_idx].push_back(variant_idx);
		}
		return variant_idx;
	}

	const uint32_t base_idx = base_programs.size();
	base_programs.push_back(BaseProgram({ .description = p_program_description }));
	loading_variants[base_idx].push_back(variant_idx);

	ProgramDescription &base_program_description = base_programs[base_idx].description;
	base_loading_idxs.resize(base_programs.size());
	base_loading_idxs.insert(base_idx);
	base_program_hash_to_base_idx.insert(base_hash, base_idx);

	bool success = false;
	if (p_program_description.material_type == MATERIAL_TYPE_BASE_MATERIAL3D) {
		success = create_program_async<MATERIAL_TYPE_BASE_MATERIAL3D>(base_idx, base_program_description);
	} else if (p_program_description.material_type == MATERIAL_TYPE_SHADER_MATERIAL) {
		success = create_program_async<MATERIAL_TYPE_SHADER_MATERIAL>(base_idx, base_program_description);
	}

	if (!success) {
		program_loading_idxs.remove(variant_idx);
		base_loading_idxs.remove(base_idx);
		base_program_hash_to_base_idx.erase(base_hash);
		loading_variants.erase(base_idx);
		return create_broken_program_async();
	}

	return variant_idx;
}

#if DEBUG
#define _SG_VALIDATE                                                                \
	ERR_FAIL_COND_V_MSG(compiler.get().compile(program_parts).isNone(), UINT32_MAX, \
			"Unable to generate invalid material ShaderGraph: error validating snippet");
#else
#define _SG_VALIDATE
#endif

#define SG(snippet)                                                                                      \
	{                                                                                                    \
		swift::String snippet_string = #snippet;                                                         \
		swift::Optional<GodotRealityKit::ProgramPart> part = compiler.get().parse(snippet_string, true); \
		if (!part.isNone()) {                                                                            \
			program_parts.append(part.get());                                                            \
			_SG_VALIDATE                                                                                 \
		} else {                                                                                         \
			return UINT32_MAX;                                                                           \
		}                                                                                                \
	}

#define SG_DECLARATIONS(val)                                                                             \
	{                                                                                                    \
		swift::String snippet_string = sgl::builtin::val();                                              \
		swift::Optional<GodotRealityKit::ProgramPart> part = compiler.get().parse(snippet_string, true); \
		if (!part.isNone()) {                                                                            \
			program_parts.append(part.get());                                                            \
			_SG_VALIDATE                                                                                 \
		} else {                                                                                         \
			return UINT32_MAX;                                                                           \
		}                                                                                                \
	}

uint32_t ProgramCache::create_broken_program_async() {
	if (broken_material_index != UINT32_MAX) {
		return broken_material_index;
	}

	if (compiler.isNone()) {
		return UINT32_MAX;
	}

	swift::Array<GodotRealityKit::ProgramPart> program_parts = swift::Array<GodotRealityKit::ProgramPart>::init();

	SG_DECLARATIONS(utility_functions);
	SG_DECLARATIONS(swizzle);
	SG_DECLARATIONS(constants);
	SG_DECLARATIONS(vertex::attributes);

	SG(
			let geometry_modifier = ND_realitykit_geometrymodifier_2_0_vertexshader(-, -, normal_attribute, bitangent_attribute);)

	SG(
			let scaled_position = ND_multiply_vector3(position_attribute, (10.0f, 10.0f, 10.0f));
			let u_step = ND_round_float(ND_dotproduct_vector3(scaled_position, (1.0f, 1.0f, 1.0f)));
			let u_mix = ND_modulo_float(u_step, 2.0f);
			let base_color = ND_mix_color3((0.7h, 0.7h, 0.7h)c, (1.0h, 1.0h, 1.0h)c, u_mix);
			let surface_shader = ND_realitykit_pbr_surfaceshader(base_color);)

	SG(
			(geometry_modifier, surface_shader);)

	ProgramDescription desc = ProgramDescription();
	broken_material_index = alloc_variant(desc);
	const uint32_t base_idx = base_programs.size();
	loading_variants[base_idx].push_back(broken_material_index);
	base_programs.push_back(BaseProgram({ .description = desc }));

	ProgramDescription &base_desc = base_programs[base_idx].description;
	uint32_t base_hash = base_desc.base_program_hash;
	base_loading_idxs.resize(base_programs.size());
	base_loading_idxs.insert(base_idx);
	base_program_hash_to_base_idx.insert(base_hash, base_idx);

	bool success = make_usda(base_idx, program_parts);
	ERR_FAIL_COND_V(!success, UINT32_MAX);

	return broken_material_index;
}

void ProgramCache::reset() {
	ERR_FAIL_COND_MSG(has_loading(), "Cannot reset ProgramCache while programs are still loading");

	programs.clear();
	program_loading_idxs.clear();
	program_description_to_idx.clear();

	base_programs.clear();
	base_programs_descriptions.clear();
	base_loading_idxs.clear();
	base_program_hash_to_base_idx.clear();
	loading_variants.clear();

	preloaded_materials.clear();
	snippet_cache.clear();
	broken_material_index = UINT32_MAX;
}

GodotRealityKit::SGLMaterial ProgramCache::create_material(uint32_t p_program_idx) {
	ERR_FAIL_COND_V(program_loading_idxs.has(p_program_idx), broken_material);
	GodotRealityKit::SGLProgram program = programs[p_program_idx].value;
	GodotRealityKit::SGLMaterial material = program.instantiate();
	return material;
}

void ProgramCache::update() {
}

} // namespace gdrk
