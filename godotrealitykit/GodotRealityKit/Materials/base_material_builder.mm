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

#import "base_material_builder.h"
#include "snippets.h"
#include "types.h"
#include "utility.h"

#include "material_bridge.h"

#include <TargetConditionals.h>
#include <godot_cpp/classes/project_settings.hpp>

using namespace gdrk;

// In debug, compile the graph after each snippet so we can better localize where errors occur during development
#if DEBUG
#define _SG_VALIDATE                                                             \
	ERR_FAIL_COND_V_MSG(compiler.get().compile(p_program_parts).isNone(), false, \
			"Unable to generate base material ShaderGraph: error validating snippet");
#else
#define _SG_VALIDATE
#endif

#define SG(snippet)                                                                                      \
	{                                                                                                    \
		swift::String snippet_string = #snippet;                                                         \
		swift::Optional<GodotRealityKit::ProgramPart> part = compiler.get().parse(snippet_string, true); \
		if (!part.isNone()) {                                                                            \
			p_program_parts.append(part.get());                                                          \
			_SG_VALIDATE                                                                                 \
		} else {                                                                                         \
			return false;                                                                                \
		}                                                                                                \
	}

#define SG_DECLARATIONS(val)                                                                             \
	{                                                                                                    \
		swift::String snippet_string = sgl::builtin::val();                                              \
		swift::Optional<GodotRealityKit::ProgramPart> part = compiler.get().parse(snippet_string, true); \
		if (!part.isNone()) {                                                                            \
			p_program_parts.append(part.get());                                                          \
			_SG_VALIDATE                                                                                 \
		} else {                                                                                         \
			return false;                                                                                \
		}                                                                                                \
	}

BaseMaterialBuilder::BaseMaterialBuilder(swift::Optional<GodotRealityKit::Compiler> p_compiler,
		const BaseMaterial3DDescription &p_program_description) :
		compiler(p_compiler), program_description(p_program_description) {
}

bool BaseMaterialBuilder::build(swift::Array<GodotRealityKit::ProgramPart> &p_program_parts) {
	using BM = godot::BaseMaterial3D;
	const BaseMaterial3DDescription &d = program_description;

	SG_DECLARATIONS(utility_functions);
	SG_DECLARATIONS(swizzle);
	SG_DECLARATIONS(constants);
	SG_DECLARATIONS(vertex::attributes);

	const bool use_nearest_mipmap_filter =
			godot::ProjectSettings::get_singleton()->get_setting("rendering/textures/default_filters/use_nearest_mipmap_filter");
	if (d.texture_filter == BM::TEXTURE_FILTER_NEAREST) {
		if (d.get_flag(BM::FLAG_USE_TEXTURE_REPEAT)) {
			SG(
					let sample_tex2d_c4 = { (tex, uv, def)in
									ND_RealityKitTexture2D_color4(tex, "repeat", "repeat", "transparent_black", "nearest", "nearest", "none", 1, -, -, def, uv) };
					let sample_tex2d_v4 = { (tex, uv, def)in
									ND_RealityKitTexture2D_vector4(tex, "repeat", "repeat", "transparent_black", "nearest", "nearest", "none", 1, -, -, def, uv) };)
		} else {
			SG(
					let sample_tex2d_c4 = { (tex, uv, def)in
									ND_RealityKitTexture2D_color4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "nearest", "nearest", "none", 1, -, -, def, uv) };
					let sample_tex2d_c4 = { (tex, uv, def)in
									ND_RealityKitTexture2D_vector4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "nearest", "nearest", "none", 1, -, -, def, uv) };)
		}
	} else if (d.texture_filter == BM::TEXTURE_FILTER_LINEAR) {
		if (d.get_flag(BM::FLAG_USE_TEXTURE_REPEAT)) {
			SG(
					let sample_tex2d_c4 = { (tex, uv, def)in
									ND_RealityKitTexture2D_color4(tex, "repeat", "repeat", "transparent_black", "linear", "linear", "none", 1, -, -, def, uv) };
					let sample_tex2d_v4 = { (tex, uv, def)in
									ND_RealityKitTexture2D_vector4(tex, "repeat", "repeat", "transparent_black", "linear", "linear", "none", 1, -, -, def, uv) };)
		} else {
			SG(
					let sample_tex2d_c4 = { (tex, uv, def)in
									ND_RealityKitTexture2D_color4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "linear", "linear", "none", 1, -, -, def, uv) };
					let sample_tex2d_v4 = { (tex, uv, def)in
									ND_RealityKitTexture2D_vector4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "linear", "linear", "none", 1, -, -, def, uv) };)
		}
	} else if (d.texture_filter == BM::TEXTURE_FILTER_NEAREST_WITH_MIPMAPS ||
			d.texture_filter == BM::TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC) {
		if (d.get_flag(BM::FLAG_USE_TEXTURE_REPEAT)) {
			if (use_nearest_mipmap_filter) {
				SG(
						let sample_tex2d_c4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_color4(tex, "repeat", "repeat", "transparent_black", "nearest", "nearest", "nearest", 1, -, -, def, uv) };
						let sample_tex2d_v4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_vector4(tex, "repeat", "repeat", "transparent_black", "nearest", "nearest", "nearest", 1, -, -, def, uv) };)
			} else {
				SG(
						let sample_tex2d_c4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_color4(tex, "repeat", "repeat", "transparent_black", "nearest", "nearest", "linear", 1, -, -, def, uv) };
						let sample_tex2d_v4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_vector4(tex, "repeat", "repeat", "transparent_black", "nearest", "nearest", "linear", 1, -, -, def, uv) };)
			}
		} else {
			if (use_nearest_mipmap_filter) {
				SG(
						let sample_tex2d_c4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_color4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "nearest", "nearest", "nearest", 1, -, -, def, uv) };
						let sample_tex2d_v4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_vector4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "nearest", "nearest", "nearest", 1, -, -, def, uv) };)
			} else {
				SG(
						let sample_tex2d_c4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_color4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "nearest", "nearest", "linear", 1, -, -, def, uv) };
						let sample_tex2d_v4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_vector4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "nearest", "nearest", "linear", 1, -, -, def, uv) };)
			}
		}
	} else if (d.texture_filter == BM::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS ||
			d.texture_filter == BM::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC) {
		if (d.get_flag(BM::FLAG_USE_TEXTURE_REPEAT)) {
			if (use_nearest_mipmap_filter) {
				SG(
						let sample_tex2d_c4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_color4(tex, "repeat", "repeat", "transparent_black", "linear", "linear", "nearest", 1, -, -, def, uv) };
						let sample_tex2d_v4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_vector4(tex, "repeat", "repeat", "transparent_black", "linear", "linear", "nearest", 1, -, -, def, uv) };)
			} else {
				SG(
						let sample_tex2d_c4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_color4(tex, "repeat", "repeat", "transparent_black", "linear", "linear", "linear", 1, -, -, def, uv) };
						let sample_tex2d_v4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_vector4(tex, "repeat", "repeat", "transparent_black", "linear", "linear", "linear", 1, -, -, def, uv) };)
			}
		} else {
			if (use_nearest_mipmap_filter) {
				SG(
						let sample_tex2d_c4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_color4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "linear", "linear", "nearest", 1, -, -, def, uv) };
						let sample_tex2d_v4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_vector4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "linear", "linear", "nearest", 1, -, -, def, uv) };)
			} else {
				SG(
						let sample_tex2d_c4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_color4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "linear", "linear", "linear", 1, -, -, def, uv) };
						let sample_tex2d_v4 = { (tex, uv, def)in
										ND_RealityKitTexture2D_vector4(tex, "clamp_to_edge", "clamp_to_edge", "transparent_black", "linear", "linear", "linear", 1, -, -, def, uv) };)
			}
		}
	}

	SG(
			let sample_tex2d_triplanar_c4 = { (tex, ws, tp_pos, def) in
				let samp = (0.0h, 0.0h, 0.0h, 0.0h)c;
				let samp = ND_add_color4(samp, ND_multiply_color4(sample_tex2d_c4(tex, v3_xy(tp_pos), def), ND_swizzle_vector3_color4(ws, "zzzz")));
				let samp = ND_add_color4(samp, ND_multiply_color4(sample_tex2d_c4(tex, v3_xz(tp_pos), def), ND_swizzle_vector3_color4(ws, "yyyy")));
				let samp = ND_add_color4(samp, ND_multiply_color4(sample_tex2d_c4(tex, ND_multiply_vector2(v3_zy(tp_pos), (-1.0f, 1.0f)), def), ND_swizzle_vector3_color4(ws, "xxxx")));
				samp };
			let sample_tex2d_triplanar_v4 = { (tex, ws, tp_pos, def) in
				let samp = (0.0f, 0.0f, 0.0f, 0.0f);
				let samp = ND_add_vector4(samp, ND_multiply_vector4(sample_tex2d_v4(tex, v3_xy(tp_pos), def), ND_swizzle_vector3_vector4(ws, "zzzz")));
				let samp = ND_add_vector4(samp, ND_multiply_vector4(sample_tex2d_v4(tex, v3_xz(tp_pos), def), ND_swizzle_vector3_vector4(ws, "yyyy")));
				let samp = ND_add_vector4(samp, ND_multiply_vector4(sample_tex2d_v4(tex, ND_multiply_vector2(v3_zy(tp_pos), (-1.0f, 1.0f)), def), ND_swizzle_vector3_vector4(ws, "xxxx")));
				samp };)

	if (d.get_flag(BM::FLAG_UV1_USE_TRIPLANAR)) {
		SG(
				let sample_tex2d_uv1_c4 = { (tex, def)in
								sample_tex2d_triplanar_c4(tex, ND_texcoord_vector3(3), ND_texcoord_vector3(2), def) };
				let sample_tex2d_uv1_v4 = { (tex, def)in
								sample_tex2d_triplanar_v4(tex, ND_texcoord_vector3(3), ND_texcoord_vector3(2), def) };)
	} else {
		SG(
				let sample_tex2d_uv1_c4 = { (tex, def)in sample_tex2d_c4(tex, ND_texcoord_vector2(0), def) };
				let sample_tex2d_uv1_v4 = { (tex, def)in sample_tex2d_v4(tex, ND_texcoord_vector2(0), def) };)
	}

	if (d.get_flag(BM::FLAG_UV2_USE_TRIPLANAR)) {
		SG(
				let sample_tex2d_uv2_c4 = { (tex, def)in
								sample_tex2d_triplanar_c4(tex, ND_texcoord_vector3(5), ND_texcoord_vector3(4), def) };
				let sample_tex2d_uv2_v4 = { (tex, def)in
								sample_tex2d_triplanar_v4(tex, ND_texcoord_vector3(5), ND_texcoord_vector3(4), def) };)
	} else {
		SG(
				let sample_tex2d_uv2_c4 = { (tex, def)in sample_tex2d_c4(tex, ND_texcoord_vector2(1), def) };
				let sample_tex2d_uv2_v4 = { (tex, def)in sample_tex2d_v4(tex, ND_texcoord_vector2(1), def) };)
	}

	// Uniforms that are present in the equivalent godot base material shader don't start with underscores,
	// and uniforms that were created for the purposes of this shader graph implementation do.
	SG(
			uniform _world_scale : float3 = (1.0f, 1.0f, 1.0f);)

	if (d.transparency == godot::BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR) {
		SG(uniform alpha_scissor_threshold : float = 0.0000000000000000000000000000000000000117549435082228750f;)
	}

	SG(
			uniform albedo : float4 = (1.0f, 1.0f, 1.0f, 1.0f);
			let albedo_color = ND_swizzle_vector4_color4(albedo, "xyzw");
			uniform texture_albedo : asset = @;)

	if (d.get_flag(BM::FLAG_ALBEDO_FROM_VERTEX_COLOR)) {
		SG(uniform _vertex_color_use_as_albedo : bool = true;)
	}

	if (d.get_feature(BM::FEATURE_DETAIL)) {
		SG(
				uniform texture_detail_albedo : asset = @;
				uniform texture_detail_mask : asset = @;
				uniform texture_detail_normal : asset = @;)
	}

	if (d.distance_fade != BM::DISTANCE_FADE_DISABLED) {
		SG(
				uniform distance_fade_min : float = 0.0f uniform distance_fade_max : float = 10.0f)
	}

	SG(
			uniform metallic : float = 0.0f;
			uniform specular : float = 0.0f;
			uniform texture_metallic : asset = @;

			uniform roughness : float = 1.0f;
			uniform texture_roughness : asset = @;)

	if (d.get_feature(BM::FEATURE_EMISSION)) {
		SG(
				uniform emission : float4 = (0.0f, 0.0f, 0.0f, 1.0f);
				let emission_color = ND_swizzle_vector4_color4(emission, "xyzw");
				uniform texture_emission : asset = @;
				uniform emission_energy : float = 1.0f;)
	}

	if (d.get_feature(BM::FEATURE_NORMAL_MAPPING)) {
		SG(
				uniform texture_normal : asset = @;)
	}

	if (d.get_feature(BM::FEATURE_CLEARCOAT)) {
		SG(
				uniform clearcoat : float = 1.0f;
				uniform texture_clearcoat : asset = @;
				uniform clearcoat_roughness : float = 0.5f;)
	}

	if (d.get_feature(BM::FEATURE_ANISOTROPY)) {
		SG(
				uniform anisotropy_ratio : float = 0.0f;)
	}

	if (d.get_feature(BM::FEATURE_AMBIENT_OCCLUSION)) {
		SG(
				uniform texture_ambient_occlusion : asset = @;
				uniform ao_texture_channel : int = 0;)
	}

	SG(
			uniform uv1_offset : float3 = (0.0f, 0.0f, 0.0f);
			uniform uv1_scale : float3 = (1.0f, 1.0f, 1.0f);
			uniform uv2_offset : float3 = (0.0f, 0.0f, 0.0f);
			uniform uv2_scale : float3 = (1.0f, 1.0f, 1.0f);)

	if (d.get_flag(BM::FLAG_UV1_USE_TRIPLANAR)) {
		SG(
				uniform uv1_blend_sharpness : float = 1.0f;)
	}

	if (d.get_flag(BM::FLAG_UV2_USE_TRIPLANAR)) {
		SG(
				uniform uv2_blend_sharpness : float = 1.0f;)
	}

	// MARK: Geometry Modifier

	SG(

			let position = position_attribute;
			let normal = normal_attribute;
			let bitangent = bitangent_attribute;);

	WARN_COMPAT_COND(d.billboard_mode != BM::BillboardMode::BILLBOARD_ENABLED &&
			d.billboard_mode != BM::BillboardMode::BILLBOARD_DISABLED &&
			d.billboard_mode != BM::BillboardMode::BILLBOARD_PARTICLES);

	if (d.billboard_mode != BM::BillboardMode::BILLBOARD_DISABLED) {
		SG(
				let godot_to_rk_scale =
						ND_realitykit_combine4_matrix44(ND_combine4_vector4(v3_x(_world_scale), 0.0f, 0.0f, 0.0f),
								ND_combine4_vector4(0.0f, v3_y(_world_scale), 0.0f, 0.0f),
								ND_combine4_vector4(0.0f, 0.0f, v3_z(_world_scale), 0.0f),
								ND_combine4_vector4(0.0f, 0.0f, 0.0f, 1.0f));

				let position_f4 = ND_combine4_vector4(v3_x(position), v3_y(position), v3_z(position), 0.0f);)

		if (d.get_flag(BM::FLAG_BILLBOARD_KEEP_SCALE)) {
			SG(
					let model_to_world = ND_realitykit_geometry_modifier_model_to_world();
					let model_to_world_c0 = ND_multiply_matrix44_vector4(model_to_world, (1.0f, 0.0f, 0.0f, 0.0f));
					let model_to_world_c1 = ND_multiply_matrix44_vector4(model_to_world, (0.0f, 1.0f, 0.0f, 0.0f));
					let model_to_world_c2 = ND_multiply_matrix44_vector4(model_to_world, (0.0f, 0.0f, 1.0f, 0.0f));
					let x_scale = ND_magnitude_vector3(v4_xyz(model_to_world_c0));
					let y_scale = ND_magnitude_vector3(v4_xyz(model_to_world_c1));
					let z_scale = ND_magnitude_vector3(v4_xyz(model_to_world_c2));
					let model_to_world_scale =
							ND_realitykit_combine4_matrix44(
									ND_combine4_vector4(x_scale, 0.0f, 0.0f, 0.0f),
									ND_combine4_vector4(0.0f, y_scale, 0.0f, 0.0f),
									ND_combine4_vector4(0.0f, 0.0f, z_scale, 0.0f),
									ND_combine4_vector4(0.0f, 0.0f, 0.0f, 1.0f));

					let position_f4 = ND_multiply_matrix44_vector4(model_to_world_scale, position_f4);)
		} else {
			SG(
					let godot_to_rk_scale =
							ND_realitykit_combine4_matrix44(ND_combine4_vector4(v3_x(_world_scale), 0.0f, 0.0f, 0.0f),
									ND_combine4_vector4(0.0f, v3_y(_world_scale), 0.0f, 0.0f),
									ND_combine4_vector4(0.0f, 0.0f, v3_z(_world_scale), 0.0f),
									ND_combine4_vector4(0.0f, 0.0f, 0.0f, 1.0f));

					let position_f4 = ND_multiply_matrix44_vector4(godot_to_rk_scale, position_f4);)
		}

		SG(
				let model_to_view = ND_realitykit_geometry_modifier_model_to_view();
				let view_to_model = ND_invertmatrix_matrix44(model_to_view);

				let position_f4 = ND_multiply_matrix44_vector4(view_to_model, position_f4);
				let offset = ND_subtract_vector3(v4_xyz(position_f4), position);
				let position = ND_add_vector3(position, offset);

				let bitangent_f4 = ND_combine4_vector4(v3_x(bitangent), v3_y(bitangent), v3_z(bitangent), 0.0f);
				let bitangent_f4 = ND_multiply_matrix44_vector4(view_to_model, bitangent_f4);
				let bitangent = ND_normalize_vector3(v4_xyz(bitangent_f4));

				let normal_f4 = ND_combine4_vector4(v3_x(normal), v3_y(normal), v3_z(normal), 0.0f);
				let normal_f4 = ND_multiply_matrix44_vector4(ND_transpose_matrix44(model_to_view), normal_f4);
				let normal = ND_normalize_vector3(v4_xyz(normal_f4));)
	}

	if (d.get_flag(BM::FLAG_UV1_USE_TRIPLANAR)) {
		if (d.get_flag(BM::FLAG_UV1_USE_WORLD_TRIPLANAR)) {
			SG(
					let uv1_position = v4_xyz(
							ND_multiply_matrix44_vector4(
									ND_realitykit_geometry_modifier_model_to_world(),
									ND_combine4_vector4(v3_x(position), v3_y(position), v3_z(position), 1.0f)));
					let uv1_normal = ND_transformmatrix_vector3(
							normal,
							ND_realitykit_geometry_modifier_normal_to_world());)
		} else {
			SG(
					let uv1_position = position;
					let uv1_normal = normal;)
		}

		SG(
				let uv1_blend_sharpness_f3 = ND_combine3_vector3(uv1_blend_sharpness, uv1_blend_sharpness, uv1_blend_sharpness);
				let uv1_power_normal = ND_power_vector3(ND_absval_vector3(uv1_normal), uv1_blend_sharpness_f3);
				let uv1_power_normal_mag = ND_dotproduct_vector3(uv1_power_normal, (1.0f, 1.0f, 1.0f));
				let uv1_power_normal = ND_divide_vector3(uv1_power_normal, ND_combine3_vector3(uv1_power_normal_mag, uv1_power_normal_mag, uv1_power_normal_mag));
				let uv1_triplanar_pos = ND_add_vector3(ND_multiply_vector3(uv1_position, uv1_scale), uv1_offset);
				let uv1_triplanar_pos = ND_multiply_vector3(uv1_triplanar_pos, (1.0f, -1.0f, 1.0f));
				let uv1_power_normal_f4 = ND_combine4_vector4(v3_x(uv1_power_normal), v3_y(uv1_power_normal), v3_z(uv1_power_normal), 0.0f);
				let uv1_triplanar_pos_f4 = ND_combine4_vector4(v3_x(uv1_triplanar_pos), v3_y(uv1_triplanar_pos), v3_z(uv1_triplanar_pos), 0.0f);)
	} else {
		SG(
				let uv1_power_normal_f4 = (0.0f, 0.0f, 0.0f, 0.0f);
				let uv1_triplanar_pos_f4 = (0.0f, 0.0f, 0.0f, 0.0f);)
	}

	if (d.get_flag(BM::FLAG_UV2_USE_TRIPLANAR)) {
		if (d.get_flag(BM::FLAG_UV2_USE_WORLD_TRIPLANAR)) {
			SG(
					let uv2_position = v4_xyz(
							ND_multiply_matrix44_vector4(
									ND_realitykit_geometry_modifier_model_to_world(),
									ND_combine4_vector4(v3_x(position), v3_y(position), v3_z(position), 1.0f)));
					let uv2_normal = ND_transformmatrix_vector3(
							normal,
							ND_realitykit_geometry_modifier_normal_to_world());)
		} else {
			SG(
					let uv2_position = position;
					let uv2_normal = normal;)
		}

		SG(
				let uv2_blend_sharpness_f3 = ND_combine3_vector3(uv2_blend_sharpness, uv2_blend_sharpness, uv2_blend_sharpness);
				let uv2_power_normal = ND_power_vector3(ND_absval_vector3(uv2_normal), uv2_blend_sharpness_f3);
				let uv2_power_normal_mag = ND_dotproduct_vector3(uv2_power_normal, (1.0f, 1.0f, 1.0f));
				let uv2_power_normal = ND_divide_vector3(uv2_power_normal, ND_combine3_vector3(uv2_power_normal_mag, uv2_power_normal_mag, uv2_power_normal_mag));
				let uv2_triplanar_pos = ND_add_vector3(ND_multiply_vector3(uv2_position, uv2_scale), uv2_offset);
				let uv2_triplanar_pos = ND_multiply_vector3(uv2_triplanar_pos, (1.0f, -1.0f, 1.0f));
				let uv2_power_normal_f4 = ND_combine4_vector4(v3_x(uv2_power_normal), v3_y(uv2_power_normal), v3_z(uv2_power_normal), 0.0f);
				let uv2_triplanar_pos_f4 = ND_combine4_vector4(v3_x(uv2_triplanar_pos), v3_y(uv2_triplanar_pos), v3_z(uv2_triplanar_pos), 0.0f);)
	} else {
		SG(
				let uv2_power_normal_f4 = (0.0f, 0.0f, 0.0f, 0.0f);
				let uv2_triplanar_pos_f4 = (0.0f, 0.0f, 0.0f, 0.0f);)
	}

	SG(
			let color = color_attribute;
			let uv1 = ND_add_vector2(ND_multiply_vector2(uv1_attribute, ND_swizzle_vector3_vector2(uv1_scale, "xy")),
					ND_swizzle_vector3_vector2(uv1_offset, "xy"));

			let uv2 = ND_add_vector2(ND_multiply_vector2(uv2_attribute, ND_swizzle_vector3_vector2(uv2_scale, "xy")),
					ND_swizzle_vector3_vector2(uv2_offset, "xy"));

			let ua4 = (0.0f, 0.0f, 0.0f, 0.0f);
			let ua5 = (0.0f, 0.0f, 0.0f, 0.0f);
			let position_offset = compute_position_offset(position);
			let geometry_modifier = ND_realitykit_geometrymodifier_2_0_vertexshader(position_offset, color, normal, bitangent, uv1, uv2, uv1_triplanar_pos_f4, uv1_power_normal_f4, uv2_triplanar_pos_f4, uv2_power_normal_f4, ua4, ua5);)

	// MARK: Surface Shader

#if TARGET_OS_SIMULATOR
	// Simulator exposes the LA8 atlas as raw RG; RRR/G restores RGB/alpha.
	// Keep each branch in one SG call so Debug validates the graph only once.
	if (d.albedo_texture_is_la8_font_atlas) {
		SG(
				let albedo_tex = sample_tex2d_uv1_c4(texture_albedo, (1.0h, 1.0h, 1.0h, 1.0h)c);
				let font_albedo_tex = ND_swizzle_color4_color4(albedo_tex, "rrrg");
				let albedo_color = ND_multiply_color4(albedo_color, font_albedo_tex);)
	} else {
		SG(
				let albedo_tex = sample_tex2d_uv1_c4(texture_albedo, (1.0h, 1.0h, 1.0h, 1.0h)c);
				let albedo_color = ND_multiply_color4(albedo_color, albedo_tex);)
	}
#else
	SG(
			let albedo_tex = sample_tex2d_uv1_c4(texture_albedo, (1.0h, 1.0h, 1.0h, 1.0h)c);
			let albedo_color = ND_multiply_color4(albedo_color, albedo_tex);)
#endif

	if (d.get_flag(BM::FLAG_ALBEDO_FROM_VERTEX_COLOR)) {
		SG(
				let albedo_color = ND_ifequal_color4B(_vertex_color_use_as_albedo,
						true,
						ND_multiply_color4(albedo_color, ND_geomcolor_color4(0)),
						albedo_color);)
	}

	if (d.get_feature(BM::FEATURE_DETAIL)) {
		if (d.detail_uv_layer == BM::DETAIL_UV_1) {
			SG(
					let detail_tex = sample_tex2d_uv1_c4(texture_detail_albedo, (0.0h, 0.0h, 0.0h, 0.0h)c);)
		} else {
			SG(
					let detail_tex = sample_tex2d_uv2_c4(texture_detail_albedo, (0.0h, 0.0h, 0.0h, 0.0h)c);)
		}

		if (d.detail_uv_layer == BM::DETAIL_UV_1) {
			SG(
					let detail_mask_tex = sample_tex2d_uv1_v4(texture_detail_mask, (0.0f, 0.0f, 0.0f, 0.0f));)
		} else {
			SG(
					let detail_mask_tex = sample_tex2d_uv2_v4(texture_detail_mask, (0.0f, 0.0f, 0.0f, 0.0f));)
		}

		if (d.detail_uv_layer == BM::DETAIL_UV_1) {
			SG(
					let detail_normal_tex = sample_tex2d_uv1_v4(texture_detail_normal, (0.0f, 0.0f, 0.0f, 0.0f));)
		} else {
			SG(
					let detail_normal_tex = sample_tex2d_uv2_v4(texture_detail_normal, (0.0f, 0.0f, 0.0f, 0.0f));)
		}

		if (d.detail_blend_mode == BM::BLEND_MODE_MIX) {
			SG(let detail = ND_mix_color3(c4_rgb(detail_tex), c4_rgb(albedo_color), c4_a(detail_tex));)
		} else if (d.detail_blend_mode == BM::BLEND_MODE_ADD) {
			SG(let detail = ND_mix_color3(ND_add_color3(c4_rgb(albedo_color), c4_rgb(detail_tex)), c4_rgb(albedo_color), c4_a(detail_tex));)
		} else if (d.detail_blend_mode == BM::BLEND_MODE_SUB) {
			SG(let detail = ND_mix_color3(ND_subtract_color3(c4_rgb(albedo_color), c4_rgb(detail_tex)), c4_rgb(albedo_color), c4_a(detail_tex));)
		} else if (d.detail_blend_mode == BM::BLEND_MODE_MUL) {
			SG(let detail = ND_mix_color3(ND_multiply_color3(c4_rgb(albedo_color), c4_rgb(detail_tex)), c4_rgb(albedo_color), c4_a(detail_tex));)
		}

		SG(let normal = ND_normal_vector3("tangent");)
		SG(let detail_normal = ND_mix_vector3(v4_xyz(detail_normal_tex), normal, c4_a(detail_tex));)

		SG(
				let normal = ND_mix_vector3(detail_normal, normal, v4_x(detail_mask_tex));
				let albedo_color_f3 = ND_mix_color3(detail, c4_rgb(albedo_color), v4_x(detail_mask_tex));
				let albedo_color = ND_combine4_color4(c3_r(albedo_color_f3), c3_g(albedo_color_f3), c3_b(albedo_color_f3), c4_a(albedo_color));)
	}

	SG(
			let specular = specular;
			let metallic_tex = v4_x(sample_tex2d_uv1_v4(texture_metallic, (1.0f, 1.0f, 1.0f, 1.0f)));
			let metallic = ND_multiply_float(metallic, metallic_tex);
			let roughness_tex = v4_x(sample_tex2d_uv1_v4(texture_roughness, (1.0f, 1.0f, 1.0f, 1.0f)));
			let roughness = ND_multiply_float(roughness, roughness_tex);)

	SG(
			let baseColor = c4_rgb(albedo_color);
			let opacity = ND_swizzle_color4_float(albedo_color, "a");)

	WARN_COMPAT_COND(d.distance_fade != BM::DISTANCE_FADE_DISABLED &&
			d.distance_fade != BM::DISTANCE_FADE_PIXEL_ALPHA);
	if (d.distance_fade != BM::DISTANCE_FADE_DISABLED) {
		SG(
				let camera_pos_diff = ND_subtract_vector3(ND_realitykit_cameraposition_vector3("world"),
						ND_position_vector3("world"));
				let camera_pos_diff = ND_divide_vector3(camera_pos_diff, _world_scale);
				let distance = ND_magnitude_vector3(camera_pos_diff);
				let distance_opacity = ND_remap_float(distance, distance_fade_min, distance_fade_max, 0.0f, 1.0f);
				let distance_opacity = ND_clamp_float(distance_opacity, 0.0f, 1.0f);
				let opacity = ND_multiply_float(opacity, distance_opacity);)
	}

	if (d.get_feature(BM::FEATURE_EMISSION)) {
		SG(
				let emission_tex = c4_rgb(sample_tex2d_uv1_c4(texture_emission, (1.0h, 1.0h, 1.0h, 1.0h)c));
				let emission_energy_c3 = ND_combine3_color3(emission_energy,
						emission_energy,
						emission_energy);
				let emission_color = ND_multiply_color3(ND_multiply_color3(c4_rgb(emission_color), emission_tex), emission_energy_c3);)
	} else {
		SG(let emission_color = (0.0h, 0.0h, 0.0h)c;)
	}

	if (d.get_feature(BM::FEATURE_NORMAL_MAPPING)) {
		SG(
				uniform texture_normal : asset = @;
				let normal_map = ND_swizzle_vector4_vector2(sample_tex2d_uv1_v4(texture_normal, (0.5f, 0.5f, 0.0f, 0.0f)), "xy");
				let normal = ND_normal_map_decode(ND_combine3_vector3(v2_x(normal_map), v2_y(normal_map), 1.0f));)
	} else {
		SG(let normal = (0.0f, 0.0f, 1.0f);)
	}

	if (d.get_feature(BM::FEATURE_CLEARCOAT)) {
		SG(
				let clearcoat_tex = v4_x(sample_tex2d_uv1_v4(texture_clearcoat, (1.0f, 1.0f, 1.0f, 1.0f)));
				let clearcoat = ND_multiply_float(clearcoat, clearcoat_tex);
				let clearcoat_roughness = clearcoat_roughness;)
	} else {
		SG(
				let clearcoat = 0.0f;
				let clearcoat_roughness = 0.5f;)
	}

	// TODO: ND_realitykit_pbr_surfaceshader doesn't support anisotropy
	if (d.get_feature(BM::FEATURE_ANISOTROPY)) {
		SG(
				let anisotropy = anisotropy_ratio;)
	} else {
		SG(
				let anisotropy = 0.0f;)
	}

	if (d.get_feature(BM::FEATURE_AMBIENT_OCCLUSION)) {
		if (d.get_flag(BM::FLAG_AO_ON_UV2)) {
			SG(let ao_tex = sample_tex2d_uv2_v4(texture_ambient_occlusion, (1.0f, 1.0f, 1.0f, 1.0f));)
		} else {
			SG(let ao_tex = sample_tex2d_uv1_v4(texture_ambient_occlusion, (1.0f, 1.0f, 1.0f, 1.0f));)
		}

		SG(
				let ao_tex_avg = ND_multiply_float(ND_add_float(ND_add_float(v4_x(ao_tex), v4_y(ao_tex)), v4_z(ao_tex)),
						ND_divide_float(1.0f, 3.0f));
				let ambient_occlusion = ND_switch_floatI(v4_x(ao_tex), v4_y(ao_tex), v4_z(ao_tex), ao_tex_avg,
						0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, ao_texture_channel);)
	} else {
		SG(let ambient_occlusion = 1.0f;)
	}

	SG(
			let clearcoat_normal = (0.0f, 0.0f, 1.0f);
			let has_premultiplied_alpha = false;);

	if (d.shading_mode == godot::BaseMaterial3D::SHADING_MODE_UNSHADED) {
		if (d.transparency == godot::BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR) {
			SG(let surface_shader = ND_realitykit_unlit_surfaceshader(baseColor, opacity, alpha_scissor_threshold, false, false);)
		} else if (d.transparency == godot::BaseMaterial3D::TRANSPARENCY_ALPHA) {
			SG(let surface_shader = ND_realitykit_unlit_surfaceshader(baseColor, opacity, -, false, false);)
		} else {
			SG(let surface_shader = ND_realitykit_unlit_surfaceshader(baseColor, -, -, false, false);)
		}
	} else {
		if (d.transparency == godot::BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR) {
			SG(let surface_shader = ND_realitykit_pbr_surfaceshader(baseColor, emission_color, normal, roughness, metallic, ambient_occlusion, specular, opacity, alpha_scissor_threshold, clearcoat, clearcoat_roughness, clearcoat_normal, has_premultiplied_alpha);)
		} else if (d.transparency == godot::BaseMaterial3D::TRANSPARENCY_ALPHA) {
			SG(let surface_shader = ND_realitykit_pbr_surfaceshader(baseColor, emission_color, normal, roughness, metallic, ambient_occlusion, specular, opacity, -, clearcoat, clearcoat_roughness, clearcoat_normal, has_premultiplied_alpha);)
		} else {
			SG(let surface_shader = ND_realitykit_pbr_surfaceshader(baseColor, emission_color, normal, roughness, metallic, ambient_occlusion, specular, -, -, clearcoat, clearcoat_roughness, clearcoat_normal, has_premultiplied_alpha);)
		}
	}

	SG(
			(geometry_modifier, surface_shader);)

	return true;
}

const char *BaseMaterialBuilder::get_parameter_name(BaseMaterialParameter p_param) {
	static const char *parameter_names[BaseMaterialParameter::BM_PARAM_COUNT] = { 0 };
	if (!parameter_names[0]) {
		parameter_names[ALBEDO] = "albedo";
		parameter_names[SPECULAR] = "specular";
		parameter_names[METALLIC] = "metallic";
		parameter_names[ROUGHNESS] = "roughness";
		parameter_names[EMISSION] = "emission";
		parameter_names[EMISSION_ENERGY] = "emission_energy";
		parameter_names[NORMAL_SCALE] = "normal_scale";
		parameter_names[RIM] = "rim";
		parameter_names[RIM_TINT] = "rim_tint";
		parameter_names[CLEARCOAT] = "clearcoat";
		parameter_names[CLEARCOAT_ROUGHNESS] = "clearcoat_roughness";
		parameter_names[ANISOTROPY] = "anisotropy_ratio";
		parameter_names[HEIGHTMAP_SCALE] = "heightmap_scale";
		parameter_names[SUBSURFACE_SCATTERING_STRENGTH] = "subsurface_scattering_strength";
		parameter_names[TRANSMITTANCE_COLOR] = "transmittance_color";
		parameter_names[TRANSMITTANCE_DEPTH] = "transmittance_depth";
		parameter_names[TRANSMITTANCE_BOOST] = "transmittance_boost";
		parameter_names[BACKLIGHT] = "backlight";
		parameter_names[REFRACTION] = "refraction";
		parameter_names[POINT_SIZE] = "point_size";
		parameter_names[UV1_SCALE] = "uv1_scale";
		parameter_names[UV1_OFFSET] = "uv1_offset";
		parameter_names[UV2_SCALE] = "uv2_scale";
		parameter_names[UV2_OFFSET] = "uv2_offset";
		parameter_names[PARTICLES_ANIM_H_FRAMES] = "particles_anim_h_frames";
		parameter_names[PARTICLES_ANIM_V_FRAMES] = "particles_anim_v_frames";
		parameter_names[PARTICLES_ANIM_LOOP] = "particles_anim_loop";
		parameter_names[HEIGHTMAP_MIN_LAYERS] = "heightmap_min_layers";
		parameter_names[HEIGHTMAP_MAX_LAYERS] = "heightmap_max_layers";
		parameter_names[HEIGHTMAP_FLIP] = "heightmap_flip";
		parameter_names[UV1_BLEND_SHARPNESS] = "uv1_blend_sharpness";
		parameter_names[UV2_BLEND_SHARPNESS] = "uv2_blend_sharpness";
		parameter_names[GROW] = "grow";
		parameter_names[PROXIMITY_FADE_DISTANCE] = "proximity_fade_distance";
		parameter_names[MSDF_PIXEL_RANGE] = "msdf_pixel_range";
		parameter_names[MSDF_OUTLINE_SIZE] = "msdf_outline_size";
		parameter_names[DISTANCE_FADE_MIN] = "distance_fade_min";
		parameter_names[DISTANCE_FADE_MAX] = "distance_fade_max";
		parameter_names[AO_LIGHT_AFFECT] = "ao_light_affect";
		parameter_names[METALLIC_TEXTURE_CHANNEL] = "metallic_texture_channel";
		parameter_names[AO_TEXTURE_CHANNEL] = "ao_texture_channel";
		parameter_names[CLEARCOAT_TEXTURE_CHANNEL] = "clearcoat_texture_channel";
		parameter_names[RIM_TEXTURE_CHANNEL] = "rim_texture_channel";
		parameter_names[HEIGHTMAP_TEXTURE_CHANNEL] = "heightmap_texture_channel";
		parameter_names[REFRACTION_TEXTURE_CHANNEL] = "refraction_texture_channel";
		parameter_names[TEXTURE_ALBEDO] = "texture_albedo";
		parameter_names[TEXTURE_METALLIC] = "texture_metallic";
		parameter_names[TEXTURE_ROUGHNESS] = "texture_roughness";
		parameter_names[TEXTURE_EMISSION] = "texture_emission";
		parameter_names[TEXTURE_NORMAL] = "texture_normal";
		parameter_names[TEXTURE_BENT_NORMAL] = "texture_bent_normal";
		parameter_names[TEXTURE_RIM] = "texture_rim";
		parameter_names[TEXTURE_CLEARCOAT] = "texture_clearcoat";
		parameter_names[TEXTURE_FLOWMAP] = "texture_flowmap";
		parameter_names[TEXTURE_AMBIENT_OCCLUSION] = "texture_ambient_occlusion";
		parameter_names[TEXTURE_HEIGHTMAP] = "texture_heightmap";
		parameter_names[TEXTURE_SUBSURFACE_SCATTERING] = "texture_subsurface_scattering";
		parameter_names[TEXTURE_SUBSURFACE_TRANSMITTANCE] = "texture_subsurface_transmittance";
		parameter_names[TEXTURE_BACKLIGHT] = "texture_backlight";
		parameter_names[TEXTURE_REFRACTION] = "texture_refraction";
		parameter_names[TEXTURE_DETAIL_MASK] = "texture_detail_mask";
		parameter_names[TEXTURE_DETAIL_ALBEDO] = "texture_detail_albedo";
		parameter_names[TEXTURE_DETAIL_NORMAL] = "texture_detail_normal";
		parameter_names[TEXTURE_ORM] = "texture_orm";
		parameter_names[ALPHA_SCISSOR_THRESHOLD] = "alpha_scissor_threshold";
		parameter_names[ALPHA_HASH_SCALE] = "alpha_hash_scale";
		parameter_names[ALPHA_ANTIALIASING_EDGE] = "alpha_antialiasing_edge";
		parameter_names[ALBEDO_TEXTURE_SIZE] = "albedo_texture_size";
		parameter_names[Z_CLIP_SCALE] = "z_clip_scale";
		parameter_names[FOV_OVERRIDE] = "fov_override";

		parameter_names[WORLD_SCALE] = "_world_scale";
	}

	return parameter_names[p_param];
}

const godot::StringName *BaseMaterialBuilder::get_godot_parameter_name_table() {
	static godot::StringName godot_parameter_names[BaseMaterialParameter::BM_PARAM_COUNT];
	static bool initialized = false;

	if (!initialized) {
		initialized = true;
		for (int i = 0; i < BaseMaterialParameter::BM_PARAM_COUNT; i++) {
			godot_parameter_names[i] = get_parameter_name((BaseMaterialParameter)i);
		}
	}

	return godot_parameter_names;
}

const godot::StringName &BaseMaterialBuilder::get_godot_parameter_name(BaseMaterialParameter p_param) {
	return BaseMaterialBuilder::get_godot_parameter_name_table()[p_param];
}

const godot::StringName &BaseMaterialBuilder::get_texture_parameter_name(uint32_t index) {
	return get_godot_parameter_name((BaseMaterialParameter)(BaseMaterialParameter::TEXTURE_ALBEDO + index));
}

void BaseMaterialBuilder::finalize(const BaseMaterial3DDescription &p_description, GodotRealityKit::SGLProgram &p_program) {
	// This could probably be done only once and just make a copy everytime on the
	// swift side. But this should be fine for now
	for (int i = 0; i < BaseMaterialParameter::BM_PARAM_COUNT; i++) {
		p_program.bindNullParameter(get_parameter_name((BaseMaterialParameter)i));
	}

	using BM = godot::BaseMaterial3D;
	WARN_COMPAT_COND(p_description.next_pass.is_valid());
	WARN_COMPAT_COND(p_description.blend_mode != BM::BlendMode::BLEND_MODE_MIX);

	const bool no_depth_test = p_description.get_flag(BM::FLAG_DISABLE_DEPTH_TEST);
	const bool is_transparent = p_description.is_transparent();
	const int sort_order = -p_description.render_priority;
	const bool is_billboard = p_description.billboard_mode != BM::BILLBOARD_DISABLED;
	const float bounds_multiplier = is_billboard && !p_description.get_flag(BM::FLAG_BILLBOARD_KEEP_SCALE) ? 100.0f : 1.0f;
	p_program.setTransparent(is_transparent);
	p_program.setSortOrder(sort_order);
	p_program.setBillboard(is_billboard);
	p_program.setBoundsMultiplier(bounds_multiplier);

	if (no_depth_test) {
		p_program.setReadsDepth(false);
		p_program.setWritesDepth(false);
	} else {
		p_program.setReadsDepth(true);
		switch (p_description.depth_draw_mode) {
			case BM::DepthDrawMode::DEPTH_DRAW_OPAQUE_ONLY: {
				if (!is_transparent) {
					p_program.setWritesDepth(true);
				}
			} break;
			case BM::DepthDrawMode::DEPTH_DRAW_ALWAYS: {
				p_program.setWritesDepth(true);
			} break;
			case BM::DepthDrawMode::DEPTH_DRAW_DISABLED: {
				p_program.setWritesDepth(false);
			} break;
			default:
				WARN_COMPAT_MSG("Unhandled depth draw mode");
		}
	}

	p_program.setCullMode(p_description.cull_mode);
}
