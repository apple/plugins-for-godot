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

#include "VisualShaderNodeOutput.h"
#include "Supported.h"

#include "../program_description.h"

#include <godot_cpp/classes/visual_shader_node_output.hpp>
using namespace gdrk;
using namespace gdrk::vs;

// FLT_MIN expressed as an SGL float literal. Bound as the alpha-scissor threshold for opaque
// materials that don't author one, so the scissor path runs but never actually clips a fragment
// ("always pass").
static constexpr const char *kAlwaysPassOpacityThreshold = "0.0000000000000000000000000000000000000117549435082228750f";

// clang-format off
DEFINE_SUPPORTED_NODE(VisualShaderNodeOutput)
	INLET_COUNT_F(p_type) {
		return p_type == ShaderType::ST_FRAGMENT ? (uint32_t)FragmentOutput::FO_COUNT
												 : (uint32_t)VertexOutput::VO_COUNT;
	}



	inline static Span<std::string> init_fragment_defaults() {
		// The documentation for the the VisualShader nodes is very limited in godot, the best
		// way to lookup whant those inputs are doing is by attaching them to constants in the
		// graph editor and read the code it generates, then cross reference it with the spatial shader
		// reference:
		// https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html#built-ins
		
		static std::string fragment_defaults[FragmentOutput::FO_COUNT] = {};
		fragment_defaults[FragmentOutput::FO_ALBEDO] = sgl::color::rgb::white();
		fragment_defaults[FragmentOutput::FO_ALPHA] = sgl::number::one<float>();
		fragment_defaults[FragmentOutput::FO_METALLIC] = sgl::number::zero<float>();
		fragment_defaults[FragmentOutput::FO_ROUGHNESS] = sgl::number::value(1.0f);
		fragment_defaults[FragmentOutput::FO_SPECULAR] = sgl::number::value(0.5f);
		fragment_defaults[FragmentOutput::FO_EMISSION] = sgl::color::rgb::black();

		fragment_defaults[FragmentOutput::FO_AO] = sgl::number::one<float>();
		fragment_defaults[FragmentOutput::FO_AO_LIGHT_EFFECT] = sgl::number::zero<float>();

		fragment_defaults[FragmentOutput::FO_NORMAL] = sgl::builtin::normal::view();
		fragment_defaults[FragmentOutput::FO_NORMAL_MAP] = sgl::builtin::normal::tangent();
		fragment_defaults[FragmentOutput::FO_NORMAL_MAP_DEPTH] = sgl::number::one<float>();
		
		// Not supported
		fragment_defaults[FO_RIM] = sgl::number::zero<float>();
		fragment_defaults[FO_RIM_TINT] = sgl::number::one<float>();
		
		fragment_defaults[FO_CLEAR_COAT] = sgl::number::zero<float>();
		fragment_defaults[FO_CLEAR_COAT_ROUGHNESS] = sgl::number::value(0.5f);
		
		fragment_defaults[FO_ANISOTROPY] = sgl::number::zero<float>();
		fragment_defaults[FO_ANISOTROPY_FLOW] = sgl::vec2::zeros();
		
		fragment_defaults[FO_SUBSRUFACE_SCATTER] = sgl::number::zero<float>();
		fragment_defaults[FO_BACKLIGHT] = sgl::color::rgb::black();
		
		fragment_defaults[FO_ALPHA_SCISSOR_THRESHOLD] = sgl::number::zero<float>();
		fragment_defaults[FO_ALPHA_HASH_SCALE] = sgl::number::one<float>();
		fragment_defaults[FO_ALPHA_AA_EDGE] = sgl::number::zero<float>();
		fragment_defaults[FO_ALPHA_UV] = sgl::vec2::zeros();
		
		fragment_defaults[FO_DEPTH] = sgl::number::zero<float>();
		fragment_defaults[FO_BENT_NORMAL_MAP] = sgl::number::zero<float>();

		return fragment_defaults;
	}

	inline static Span<std::string> init_vertex_defaults() {
		static std::string vertex_defaults[VertexOutput::VO_COUNT] = {};
		vertex_defaults[VertexOutput::VO_POSITION] = gdrk::sgl::builtin::vertex::position();
		vertex_defaults[VertexOutput::VO_COLOR] = std::format("vec4f_to_vec3f({})", sgl::builtin::vertex::color());
		vertex_defaults[VertexOutput::VO_ALPHA] = std::format("v4_w({})", sgl::builtin::vertex::color());

		vertex_defaults[VertexOutput::VO_UV] = sgl::builtin::vertex::uv0();
		vertex_defaults[VertexOutput::VO_UV2] = sgl::builtin::vertex::uv1();
		
		// Attributes are encoded and need to potentially be decoded.
		vertex_defaults[VertexOutput::VO_TANGENT] = sgl::builtin::vertex::tangent();
		vertex_defaults[VertexOutput::VO_BINORMAL] = sgl::builtin::vertex::bitangent();
		vertex_defaults[VertexOutput::VO_NORMAL] = sgl::builtin::vertex::normal();
		
		return vertex_defaults;
	}

	DEFAULT_INPUT_VALUE_F(p_node_wrapper, p_input_index) {
		static Span<std::string> fragment_defaults = init_fragment_defaults();
		static Span<std::string> vertex_defaults = init_vertex_defaults();

		return p_node_wrapper.is_vertex_shader() ? vertex_defaults[p_input_index] : fragment_defaults[p_input_index];
	}

	inline static PortType *init_fragment_port_types() {
		static PortType port_types[FragmentOutput::FO_COUNT] = {};
		port_types[FragmentOutput::FO_ALBEDO] = PortType::VEC3F;
		port_types[FragmentOutput::FO_ALPHA] = PortType::FLOAT;
		port_types[FragmentOutput::FO_METALLIC] = PortType::FLOAT;
		port_types[FragmentOutput::FO_ROUGHNESS] = PortType::FLOAT;
		port_types[FragmentOutput::FO_SPECULAR] = PortType::FLOAT;
		port_types[FragmentOutput::FO_EMISSION] = PortType::VEC3F;

		port_types[FragmentOutput::FO_AO] = PortType::FLOAT;
		port_types[FragmentOutput::FO_AO_LIGHT_EFFECT] = PortType::FLOAT;

		port_types[FragmentOutput::FO_NORMAL] = PortType::VEC3F;
		port_types[FragmentOutput::FO_NORMAL_MAP] = PortType::VEC3F;
		port_types[FragmentOutput::FO_NORMAL_MAP_DEPTH] = PortType::FLOAT;
		
		// Not supported
		port_types[FO_RIM] = PortType::FLOAT;
		port_types[FO_RIM_TINT] = PortType::FLOAT;
		
		port_types[FO_CLEAR_COAT] = PortType::FLOAT;
		port_types[FO_CLEAR_COAT_ROUGHNESS] = PortType::FLOAT;
		
		port_types[FO_ANISOTROPY] = PortType::FLOAT;
		port_types[FO_ANISOTROPY_FLOW] = PortType::VEC2F;
		
		port_types[FO_SUBSRUFACE_SCATTER] = PortType::FLOAT;
		port_types[FO_BACKLIGHT] = PortType::VEC3F;
		
		port_types[FO_ALPHA_SCISSOR_THRESHOLD] = PortType::FLOAT;
		port_types[FO_ALPHA_HASH_SCALE] = PortType::FLOAT;
		port_types[FO_ALPHA_AA_EDGE] = PortType::FLOAT;
		port_types[FO_ALPHA_UV] = PortType::VEC2F;
		
		port_types[FO_DEPTH] = PortType::FLOAT;
		port_types[FO_BENT_NORMAL_MAP] = PortType::FLOAT;
		return port_types;
	}
	inline static PortType *init_vertex_port_types() {
		static PortType port_types[VertexOutput::VO_COUNT] = {};
		port_types[VertexOutput::VO_POSITION] = PortType::VEC3F;
		port_types[VertexOutput::VO_NORMAL] = PortType::VEC3F;
		port_types[VertexOutput::VO_COLOR] = PortType::VEC3F;
		port_types[VertexOutput::VO_ALPHA] = PortType::FLOAT;
		
		port_types[VertexOutput::VO_TANGENT] = PortType::VEC3F;
		port_types[VertexOutput::VO_BINORMAL] = PortType::VEC3F;
		port_types[VertexOutput::VO_UV] = PortType::VEC2F;
		port_types[VertexOutput::VO_UV2] = PortType::VEC2F;
		return port_types;
	}

	INPUT_TYPE_F(p_node_wrapper, p_input_index) {
		static PortType *fragment_port_types = init_fragment_port_types();
		static PortType *vertex_port_types  = init_vertex_port_types();
		
		return p_node_wrapper.is_vertex_shader() ? vertex_port_types[p_input_index] : fragment_port_types[p_input_index];
	}


	ANALYZE(p_context, p_node_wrapper) {
		if (p_node_wrapper.is_fragment_shader()) {
			return;
		}
	   if (p_node_wrapper.get_input_var_name(p_context, VertexOutput::VO_UV) == std::nullopt) {
		   p_context.uv_is_default = true;
	   }
		if (p_node_wrapper.get_input_var_name(p_context, VertexOutput::VO_UV2) == std::nullopt) {
			p_context.uv2_is_default = true;
		}
	}

	// Returns the r-value expression for the tangent-space normal handed to
	// `ND_realitykit_pbr_surfaceshader`. FO_NORMAL is authored in view space; FO_NORMAL_MAP is already
	// tangent space; the surface shader wants tangent space. We only pay for view<->tangent transforms
	// when FO_NORMAL is actually driven — otherwise the geometric-normal contribution is just the
	// unperturbed tangent normal (0, 0, 1), so the whole basis round-trip collapses to a tangent-space
	// blend (or nothing at all). When the view-space path is taken the TBN basis and conversion
	// helpers are emitted as their own code part so the returned expression can reference them.
	static std::string get_fragment_normal_expression(VisualProgramBuilderContext &p_context,
			const VisualShaderNodeWrapper &p_node_wrapper) {
		bool normal_is_default = false;
		bool normal_map_is_default = false;
		const std::string normal = p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_NORMAL, normal_is_default);
		const std::string normal_map = p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_NORMAL_MAP, normal_map_is_default);
		const std::string normal_map_depth = p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_NORMAL_MAP_DEPTH);

		// Nothing perturbs the surface: the unperturbed tangent normal, no transforms.
		if (normal_is_default && normal_map_is_default) {
			return "-";
		}

		// Only a tangent-space normal map is connected: blend it against the unperturbed normal
		// entirely in tangent space — still no view<->tangent transforms.
		if (normal_is_default) {
			return std::format("ND_mix_vector3({}, {}, {})", sgl::builtin::normal::tangent(), normal_map, normal_map_depth);
		}

		// FO_NORMAL is driven in view space: declare the view-space TBN basis and conversion helpers,
		// then combine in view space and convert the result back to tangent space.
		p_context.code_parts.push_back(std::format(R"""(
				let VisualShaderNodeOutput_tangent_view = {0};
				let VisualShaderNodeOutput_bitangent_view = {1};
				let VisualShaderNodeOutput_normal_view = {2};
				let VisualShaderNodeOutput_view_to_tangent = {{ (dir) in
					let x = ND_dotproduct_vector3(dir, VisualShaderNodeOutput_tangent_view);
					let y = ND_dotproduct_vector3(dir, VisualShaderNodeOutput_bitangent_view);
					let z = ND_dotproduct_vector3(dir, VisualShaderNodeOutput_normal_view);
					ND_normalize_vector3(ND_combine3_vector3(x, y, z))
				}};
				let VisualShaderNodeOutput_tangent_to_view = {{ (dir) in
					let vx = ND_multiply_vector3FA(VisualShaderNodeOutput_tangent_view, v3_x(dir));
					let vy = ND_multiply_vector3FA(VisualShaderNodeOutput_bitangent_view, v3_y(dir));
					let vz = ND_multiply_vector3FA(VisualShaderNodeOutput_normal_view, v3_z(dir));
					ND_add_vector3(ND_add_vector3(vx, vy), vz)
				}};
			)""",
				gdrk::sgl::builtin::tangent::view(),
				gdrk::sgl::builtin::bitangent::view(),
				gdrk::sgl::builtin::normal::view()));

		return std::format(
				"VisualShaderNodeOutput_view_to_tangent(ND_mix_vector3({}, VisualShaderNodeOutput_tangent_to_view({}), {}))",
				normal, normal_map, normal_map_depth);
	}

	static std::string get_vertex_position_offset_expression(VisualProgramBuilderContext &p_context,
			const VisualShaderNodeWrapper &p_node_wrapper) {
		bool position_is_default = true;
		std::string position_expression = p_node_wrapper.get_input_expression(p_context, VertexOutput::VO_POSITION, position_is_default);
		
		if (position_is_default) {
			return "-";
		}
		
		p_context.code_parts.push_back(std::format(R"""(
				let VisualShaderNodeOutput_input_position = {};
				let VisualShaderNodeOutput_position_offset = compute_position_offset(VisualShaderNodeOutput_input_position);
		)""", position_expression));
		
		return "VisualShaderNodeOutput_position_offset";
	}

	EXPRESSION(p_context, p_node_wrapper) {
		bool default_alpha = true;
		if (p_node_wrapper.is_vertex_shader()) {
			// TODO: Add support for Model View Matrix override
			// TODO: Add support for Projection matrix override
			// TODO: Point size override
			// TODO: Add support for ROUGHNESS for vertex lighthing
			std::optional<InputExpression> uv0_var = p_node_wrapper.get_input_var_name(p_context, VertexOutput::VO_UV);
			std::optional<InputExpression> uv1_var = p_node_wrapper.get_input_var_name(p_context, VertexOutput::VO_UV2);
			std::string uv0_expression;
			std::string uv1_expression;
			
			if (!p_context.uv_is_default || p_context.uv_used) {
				uv0_expression = p_node_wrapper.get_input_expression(p_context, VertexOutput::VO_UV);
			} else {
				uv0_expression = p_context.varying_allocator.get_vertex_expression_for_uv(0);
			}
			
			if (!p_context.uv2_is_default || p_context.uv2_used) {
				uv1_expression = p_node_wrapper.get_input_expression(p_context, VertexOutput::VO_UV2);
			} else {
				uv1_expression = p_context.varying_allocator.get_vertex_expression_for_uv(1);
			}
			
			bool default_vertex_color = true;
			std::string vertex_color_expression = p_node_wrapper.get_input_expression(p_context, VertexOutput::VO_COLOR, default_vertex_color);
			std::string alpha_expression = p_node_wrapper.get_input_expression(p_context, VertexOutput::VO_ALPHA, default_alpha);
			std::string vertex_color_param = default_vertex_color && default_alpha ? "-" : "VisualShaderNodeOutput_vertex_color";
			
			p_context.code_parts.push_back(std::format(R"""(
						let VisualShaderNodeOutput_color = {1};
						let VisualShaderNodeOutput_alpha = {3};
						let VisualShaderNodeOutput_normal = compute_normal({4});
						let VisualShaderNodeOutput_tangent = {5};
						let VisualShaderNodeOutput_bitangent = compute_bitangent({6});
						let VisualShaderNodeOutput_vertex_color = ND_combine4_color4(v3_x(VisualShaderNodeOutput_color), v3_y(VisualShaderNodeOutput_color), v3_z(VisualShaderNodeOutput_color), VisualShaderNodeOutput_alpha);
	   
						let geometry_modifier = ND_realitykit_geometrymodifier_2_0_vertexshader(
							{0},
							{2},
							VisualShaderNodeOutput_normal, 
							VisualShaderNodeOutput_bitangent,
							{7}, {8}, {9}, {10}, {11}, {12}, {13}, {14}
						);
				)""",
				    get_vertex_position_offset_expression(p_context, p_node_wrapper),
					vertex_color_expression,
					vertex_color_param,
					alpha_expression,
					p_node_wrapper.get_input_expression(p_context, VertexOutput::VO_NORMAL),
					p_node_wrapper.get_input_expression(p_context, VertexOutput::VO_TANGENT),
					p_node_wrapper.get_input_expression(p_context, VertexOutput::VO_BINORMAL),
					uv0_expression,
					uv1_expression,
					p_context.varying_allocator.get_vertex_expression_for_uv(2),
					p_context.varying_allocator.get_vertex_expression_for_uv(3),
					p_context.varying_allocator.get_vertex_expression_for_uv(4),
					p_context.varying_allocator.get_vertex_expression_for_uv(5),
					p_context.varying_allocator.get_vertex_expression_for_uv(6),
					p_context.varying_allocator.get_vertex_expression_for_uv(7)
													   
			));
		} else {
			
			const bool unshaded = p_context.material_description->render_mode.get_flag(RenderModeDescription::FLAG_UNSHADED);
			const char *selected_surface_shader = unshaded ? "surface_shader_unlit" : "surface_shader_pbr";

			const std::string surface_normal_expression = get_fragment_normal_expression(p_context, p_node_wrapper);

			// Alpha policy: decide whether the material is transparent and how the alpha-scissor
			// threshold is bound. A connected ALPHA, a non-mix blend, depth_draw_never or
			// depth_test_disabled all make the material transparent; an authored alpha-scissor
			// threshold promotes it back to opaque. Transparent materials disable the scissor with the
			// '-' sentinel; opaque materials keep the scissor path, defaulting to an always-pass
			// threshold so nothing is actually clipped when none was authored.
			bool alpha_is_default = true;
			const std::string opacity_parameter = p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_ALPHA, "-", alpha_is_default);
			const bool uses_alpha = !alpha_is_default;

			bool opacity_threshold_is_default = true;
			std::string opacity_threshold = p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_ALPHA_SCISSOR_THRESHOLD, opacity_threshold_is_default);
			const bool uses_opacity_threshold = !opacity_threshold_is_default;

			const RenderModeDescription &render_mode = p_context.material_description->render_mode;
			const bool has_blend_alpha = render_mode.blend != RenderModeDescription::BLEND_MIX;
			const bool no_depth_draw = render_mode.depth_draw == RenderModeDescription::DEPTH_DRAW_NEVER;
			const bool no_depth_test = render_mode.get_flag(RenderModeDescription::FLAG_DEPTH_TEST_DISABLED);

			bool is_material_transparent = uses_alpha || has_blend_alpha || no_depth_draw || no_depth_test;
			if (uses_opacity_threshold) {
				is_material_transparent = false;
			}
			p_context.is_transparent = is_material_transparent;

			std::string alpha_scissor_param = "-";
			if (!is_material_transparent) {
				if (opacity_threshold_is_default) {
					opacity_threshold = kAlwaysPassOpacityThreshold;
				}
				alpha_scissor_param = "VisualShaderNodeOutput_opacityThreshold";
			}
			
			bool emission_is_default = true;
			std::string emission_parameter = p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_EMISSION, "-", emission_is_default);
			if (!emission_is_default) {
				emission_parameter = std::format("vec3f_to_rgb({})", emission_parameter);
			}
			
			bool albedo_is_default = true;
			std::string albedo_parameter = p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_ALBEDO, "-", albedo_is_default);
			if (!albedo_is_default) {
				albedo_parameter = std::format("vec3f_to_rgb({})", albedo_parameter);
			}

			p_context.code_parts.push_back(std::format(R"""(
							let VisualShaderNodeOutput_opacityThreshold = {8};
		
							let VisualShaderNodeOutput_clearcoatNormal = (0.0f, 0.0f, 1.0f);
							let VisualShaderNodeOutput_hasPremultipliedAlpha = {11};
	 
							let surface_shader_pbr = ND_realitykit_pbr_surfaceshader({0},
									{1},
									{2},
									{3},
									{4},
									{5},
									{6},
									{7},
									{12},
									{9},
									{10},
									-,
									{11}
								);

							let surface_shader_unlit = ND_realitykit_unlit_surfaceshader({0}, {7}, {12}, false, {11});
							let surface_shader = {13};
					)""",
				    albedo_parameter,
					emission_parameter,
					surface_normal_expression,
					p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_ROUGHNESS),
					p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_METALLIC),
					p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_AO, "-"),
					p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_SPECULAR, "-"),
					opacity_parameter,
					opacity_threshold,
					p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_CLEAR_COAT, "-"),
					p_node_wrapper.get_input_expression(p_context, FragmentOutput::FO_CLEAR_COAT_ROUGHNESS, "-"),
					false,
					alpha_scissor_param,
					selected_surface_shader
					
			));
		}
	}
END(VisualShaderNodeOutput)
