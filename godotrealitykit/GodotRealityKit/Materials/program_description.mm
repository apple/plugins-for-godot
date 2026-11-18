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

#include "program_description.h"

#include "utility.h"

#include <format>

using namespace gdrk;
using BM = godot::BaseMaterial3D;
using RMD = gdrk::RenderModeDescription;

namespace {

template <RMD::MultiMode M>
const godot::StringName &multi_mode_property_name();

#define DEFINE_MULTI_MODE_PROPERTY(enum_value, name_literal)               \
	template <>                                                            \
	const godot::StringName &multi_mode_property_name<RMD::enum_value>() { \
		static const godot::StringName name("modes/" name_literal);        \
		return name;                                                       \
	}

DEFINE_MULTI_MODE_PROPERTY(MULTI_BLEND, "blend")
DEFINE_MULTI_MODE_PROPERTY(MULTI_DEPTH_DRAW, "depth_draw")
DEFINE_MULTI_MODE_PROPERTY(MULTI_DEPTH_TEST, "depth_test")
DEFINE_MULTI_MODE_PROPERTY(MULTI_CULL, "cull")
DEFINE_MULTI_MODE_PROPERTY(MULTI_DIFFUSE, "diffuse")
DEFINE_MULTI_MODE_PROPERTY(MULTI_SPECULAR, "specular")

#undef DEFINE_MULTI_MODE_PROPERTY

DEFINE_ENUM_FUNCTION_TABLE(multi_mode_property_names, RMD::MultiMode, MULTI_MAX, multi_mode_property_name)

template <RMD::Flag F>
const godot::StringName &flag_property_name();

#define DEFINE_FLAG_PROPERTY(enum_value, name_literal)               \
	template <>                                                      \
	const godot::StringName &flag_property_name<RMD::enum_value>() { \
		static const godot::StringName name("flags/" name_literal);  \
		return name;                                                 \
	}

DEFINE_FLAG_PROPERTY(FLAG_DEPTH_PREPASS_ALPHA, "depth_prepass_alpha")
DEFINE_FLAG_PROPERTY(FLAG_DEPTH_TEST_DISABLED, "depth_test_disabled")
DEFINE_FLAG_PROPERTY(FLAG_SSS_MODE_SKIN, "sss_mode_skin")
DEFINE_FLAG_PROPERTY(FLAG_UNSHADED, "unshaded")
DEFINE_FLAG_PROPERTY(FLAG_WIREFRAME, "wireframe")
DEFINE_FLAG_PROPERTY(FLAG_SKIP_VERTEX_TRANSFORM, "skip_vertex_transform")
DEFINE_FLAG_PROPERTY(FLAG_WORLD_VERTEX_COORDS, "world_vertex_coords")
DEFINE_FLAG_PROPERTY(FLAG_ENSURE_CORRECT_NORMALS, "ensure_correct_normals")
DEFINE_FLAG_PROPERTY(FLAG_SHADOWS_DISABLED, "shadows_disabled")
DEFINE_FLAG_PROPERTY(FLAG_AMBIENT_LIGHT_DISABLED, "ambient_light_disabled")
DEFINE_FLAG_PROPERTY(FLAG_SHADOW_TO_OPACITY, "shadow_to_opacity")
DEFINE_FLAG_PROPERTY(FLAG_VERTEX_LIGHTING, "vertex_lighting")
DEFINE_FLAG_PROPERTY(FLAG_PARTICLE_TRAILS, "particle_trails")
DEFINE_FLAG_PROPERTY(FLAG_ALPHA_TO_COVERAGE, "alpha_to_coverage")
DEFINE_FLAG_PROPERTY(FLAG_ALPHA_TO_COVERAGE_AND_ONE, "alpha_to_coverage_and_one")
DEFINE_FLAG_PROPERTY(FLAG_DEBUG_SHADOW_SPLITS, "debug_shadow_splits")
DEFINE_FLAG_PROPERTY(FLAG_FOG_DISABLED, "fog_disabled")
DEFINE_FLAG_PROPERTY(FLAG_SPECULAR_OCCLUSION_DISABLED, "specular_occlusion_disabled")

#undef DEFINE_FLAG_PROPERTY

DEFINE_ENUM_FUNCTION_TABLE(flag_property_names, RMD::Flag, FLAG_MAX, flag_property_name)

inline uint8_t read_multi_mode(const godot::Ref<godot::VisualShader> &p_shader, RMD::MultiMode p_mode) {
	godot::Variant v = p_shader->get(multi_mode_property_names[p_mode]());
	return v.get_type() == godot::Variant::INT ? (uint8_t)(int32_t)v : 0;
}

inline bool read_flag(const godot::Ref<godot::VisualShader> &p_shader, RMD::Flag p_flag) {
	godot::Variant v = p_shader->get(flag_property_names[p_flag]());
	return v.get_type() == godot::Variant::BOOL && (bool)v;
}

} //namespace

RenderModeDescription RenderModeDescription::from_visual_shader(const godot::Ref<godot::VisualShader> &p_shader) {
	RenderModeDescription desc;
	if (p_shader.is_null()) {
		return desc;
	}

	desc.blend = read_multi_mode(p_shader, MULTI_BLEND);
	desc.depth_draw = read_multi_mode(p_shader, MULTI_DEPTH_DRAW);
	desc.depth_test = read_multi_mode(p_shader, MULTI_DEPTH_TEST);
	desc.cull = read_multi_mode(p_shader, MULTI_CULL);
	desc.diffuse = read_multi_mode(p_shader, MULTI_DIFFUSE);
	desc.specular = read_multi_mode(p_shader, MULTI_SPECULAR);

	for (uint8_t i = 0; i < FLAG_MAX; i++) {
		desc.set_flag((Flag)i, read_flag(p_shader, (Flag)i));
	}

	return desc;
}

std::string RenderModeDescription::to_string() const {
	auto blend_str = [&]() -> const char * {
		switch (blend) {
			case BLEND_MIX:
				return "mix";
			case BLEND_ADD:
				return "add";
			case BLEND_SUB:
				return "sub";
			case BLEND_MUL:
				return "mul";
			case BLEND_PREMUL_ALPHA:
				return "premul_alpha";
			default:
				return "unknown";
		}
	};
	auto depth_draw_str = [&]() -> const char * {
		switch (depth_draw) {
			case DEPTH_DRAW_OPAQUE:
				return "opaque";
			case DEPTH_DRAW_ALWAYS:
				return "always";
			case DEPTH_DRAW_NEVER:
				return "never";
			default:
				return "unknown";
		}
	};
	auto depth_test_str = [&]() -> const char * {
		switch (depth_test) {
			case DEPTH_TEST_DEFAULT:
				return "default";
			case DEPTH_TEST_INVERTED:
				return "inverted";
			default:
				return "unknown";
		}
	};
	auto cull_str = [&]() -> const char * {
		switch (cull) {
			case CULL_BACK:
				return "back";
			case CULL_FRONT:
				return "front";
			case CULL_DISABLED:
				return "disabled";
			default:
				return "unknown";
		}
	};
	auto diffuse_str = [&]() -> const char * {
		switch (diffuse) {
			case DIFFUSE_LAMBERT:
				return "lambert";
			case DIFFUSE_LAMBERT_WRAP:
				return "lambert_wrap";
			case DIFFUSE_BURLEY:
				return "burley";
			case DIFFUSE_TOON:
				return "toon";
			default:
				return "unknown";
		}
	};
	auto specular_str = [&]() -> const char * {
		switch (specular) {
			case SPECULAR_SCHLICK_GGX:
				return "schlick_ggx";
			case SPECULAR_TOON:
				return "toon";
			case SPECULAR_DISABLED:
				return "disabled";
			default:
				return "unknown";
		}
	};

	std::string flags_str;
	for (uint8_t i = 0; i < FLAG_MAX; i++) {
		if (!get_flag((Flag)i)) {
			continue;
		}
		if (!flags_str.empty()) {
			flags_str += ", ";
		}
		flags_str += godot::String(flag_property_names[i]()).utf8().get_data();
	}
	if (flags_str.empty()) {
		flags_str = "none";
	}

	return std::format(
			"RenderModeDescription {{\n"
			"    blend:      {}\n"
			"    depth_draw: {}\n"
			"    depth_test: {}\n"
			"    cull:       {}\n"
			"    diffuse:    {}\n"
			"    specular:   {}\n"
			"    flags:      {}\n"
			"  }}",
			blend_str(), depth_draw_str(), depth_test_str(),
			cull_str(), diffuse_str(), specular_str(),
			flags_str);
}

std::string ShaderMaterialDescription::to_string() const {
	return std::format(
			"ShaderMaterialDescription {{\n"
			"  shader_rid:       {}\n"
			"  render_priority:  {}\n"
			"  is_transparent:   {}\n"
			"  render_mode:      {}\n"
			"}}",
			shader.is_null() ? 0 : shader->get_rid().get_id(),
			render_priority,
			transparent,
			render_mode.to_string());
}

std::string BaseMaterial3DDescription::to_string() const {
	auto shading_mode_str = [&]() -> const char * {
		switch (shading_mode) {
			case BM::SHADING_MODE_UNSHADED:
				return "UNSHADED";
			case BM::SHADING_MODE_PER_PIXEL:
				return "PER_PIXEL";
			case BM::SHADING_MODE_PER_VERTEX:
				return "PER_VERTEX";
			default:
				return "UNKNOWN";
		}
	};
	auto transparency_str = [&]() -> const char * {
		switch (transparency) {
			case BM::TRANSPARENCY_DISABLED:
				return "DISABLED";
			case BM::TRANSPARENCY_ALPHA:
				return "ALPHA";
			case BM::TRANSPARENCY_ALPHA_SCISSOR:
				return "ALPHA_SCISSOR";
			case BM::TRANSPARENCY_ALPHA_HASH:
				return "ALPHA_HASH";
			case BM::TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				return "ALPHA_DEPTH_PRE_PASS";
			default:
				return "UNKNOWN";
		}
	};
	auto blend_mode_str = [](uint32_t m) -> const char * {
		switch (m) {
			case BM::BLEND_MODE_MIX:
				return "MIX";
			case BM::BLEND_MODE_ADD:
				return "ADD";
			case BM::BLEND_MODE_SUB:
				return "SUB";
			case BM::BLEND_MODE_MUL:
				return "MUL";
			case BM::BLEND_MODE_PREMULT_ALPHA:
				return "PREMULT_ALPHA";
			default:
				return "UNKNOWN";
		}
	};
	auto cull_mode_str = [&]() -> const char * {
		switch (cull_mode) {
			case BM::CULL_BACK:
				return "BACK";
			case BM::CULL_FRONT:
				return "FRONT";
			case BM::CULL_DISABLED:
				return "DISABLED";
			default:
				return "UNKNOWN";
		}
	};
	auto depth_draw_str = [&]() -> const char * {
		switch (depth_draw_mode) {
			case BM::DEPTH_DRAW_OPAQUE_ONLY:
				return "OPAQUE_ONLY";
			case BM::DEPTH_DRAW_ALWAYS:
				return "ALWAYS";
			case BM::DEPTH_DRAW_DISABLED:
				return "DISABLED";
			default:
				return "UNKNOWN";
		}
	};
	auto billboard_str = [&]() -> const char * {
		switch (billboard_mode) {
			case BM::BILLBOARD_DISABLED:
				return "DISABLED";
			case BM::BILLBOARD_ENABLED:
				return "ENABLED";
			case BM::BILLBOARD_FIXED_Y:
				return "FIXED_Y";
			case BM::BILLBOARD_PARTICLES:
				return "PARTICLES";
			default:
				return "UNKNOWN";
		}
	};
	auto texture_filter_str = [&]() -> const char * {
		switch (texture_filter) {
			case BM::TEXTURE_FILTER_NEAREST:
				return "NEAREST";
			case BM::TEXTURE_FILTER_LINEAR:
				return "LINEAR";
			case BM::TEXTURE_FILTER_NEAREST_WITH_MIPMAPS:
				return "NEAREST_WITH_MIPMAPS";
			case BM::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
				return "LINEAR_WITH_MIPMAPS";
			case BM::TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC:
				return "NEAREST_WITH_MIPMAPS_ANISOTROPIC";
			case BM::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC:
				return "LINEAR_WITH_MIPMAPS_ANISOTROPIC";
			default:
				return "UNKNOWN";
		}
	};
	auto distance_fade_str = [&]() -> const char * {
		switch (distance_fade) {
			case BM::DISTANCE_FADE_DISABLED:
				return "DISABLED";
			case BM::DISTANCE_FADE_PIXEL_ALPHA:
				return "PIXEL_ALPHA";
			case BM::DISTANCE_FADE_PIXEL_DITHER:
				return "PIXEL_DITHER";
			case BM::DISTANCE_FADE_OBJECT_DITHER:
				return "OBJECT_DITHER";
			default:
				return "UNKNOWN";
		}
	};

	// Expand flags bitfield
	std::string flags_str;
	const struct {
		BM::Flags flag;
		const char *name;
	} flag_table[] = {
		{ BM::FLAG_DISABLE_DEPTH_TEST, "DISABLE_DEPTH_TEST" },
		{ BM::FLAG_ALBEDO_FROM_VERTEX_COLOR, "ALBEDO_FROM_VERTEX_COLOR" },
		{ BM::FLAG_SRGB_VERTEX_COLOR, "SRGB_VERTEX_COLOR" },
		{ BM::FLAG_USE_POINT_SIZE, "USE_POINT_SIZE" },
		{ BM::FLAG_FIXED_SIZE, "FIXED_SIZE" },
		{ BM::FLAG_BILLBOARD_KEEP_SCALE, "BILLBOARD_KEEP_SCALE" },
		{ BM::FLAG_UV1_USE_TRIPLANAR, "UV1_USE_TRIPLANAR" },
		{ BM::FLAG_UV2_USE_TRIPLANAR, "UV2_USE_TRIPLANAR" },
		{ BM::FLAG_UV1_USE_WORLD_TRIPLANAR, "UV1_USE_WORLD_TRIPLANAR" },
		{ BM::FLAG_UV2_USE_WORLD_TRIPLANAR, "UV2_USE_WORLD_TRIPLANAR" },
		{ BM::FLAG_AO_ON_UV2, "AO_ON_UV2" },
		{ BM::FLAG_EMISSION_ON_UV2, "EMISSION_ON_UV2" },
		{ BM::FLAG_ALBEDO_TEXTURE_FORCE_SRGB, "ALBEDO_TEXTURE_FORCE_SRGB" },
		{ BM::FLAG_DONT_RECEIVE_SHADOWS, "DONT_RECEIVE_SHADOWS" },
		{ BM::FLAG_DISABLE_AMBIENT_LIGHT, "DISABLE_AMBIENT_LIGHT" },
		{ BM::FLAG_USE_SHADOW_TO_OPACITY, "USE_SHADOW_TO_OPACITY" },
		{ BM::FLAG_USE_TEXTURE_REPEAT, "USE_TEXTURE_REPEAT" },
		{ BM::FLAG_INVERT_HEIGHTMAP, "INVERT_HEIGHTMAP" },
		{ BM::FLAG_SUBSURFACE_MODE_SKIN, "SUBSURFACE_MODE_SKIN" },
		{ BM::FLAG_PARTICLE_TRAILS_MODE, "PARTICLE_TRAILS_MODE" },
		{ BM::FLAG_ALBEDO_TEXTURE_MSDF, "ALBEDO_TEXTURE_MSDF" },
		{ BM::FLAG_DISABLE_FOG, "DISABLE_FOG" },
		{ BM::FLAG_DISABLE_SPECULAR_OCCLUSION, "DISABLE_SPECULAR_OCCLUSION" },
		{ BM::FLAG_USE_Z_CLIP_SCALE, "USE_Z_CLIP_SCALE" },
		{ BM::FLAG_USE_FOV_OVERRIDE, "USE_FOV_OVERRIDE" },
	};
	for (const auto &e : flag_table) {
		if (get_flag(e.flag)) {
			if (!flags_str.empty()) {
				flags_str += ", ";
			}
			flags_str += e.name;
		}
	}
	if (flags_str.empty()) {
		flags_str = "none";
	}

	// Expand features bitfield
	std::string features_str;
	const struct {
		BM::Feature feature;
		const char *name;
	} feature_table[] = {
		{ BM::FEATURE_EMISSION, "EMISSION" },
		{ BM::FEATURE_NORMAL_MAPPING, "NORMAL_MAPPING" },
		{ BM::FEATURE_RIM, "RIM" },
		{ BM::FEATURE_CLEARCOAT, "CLEARCOAT" },
		{ BM::FEATURE_ANISOTROPY, "ANISOTROPY" },
		{ BM::FEATURE_AMBIENT_OCCLUSION, "AMBIENT_OCCLUSION" },
		{ BM::FEATURE_HEIGHT_MAPPING, "HEIGHT_MAPPING" },
		{ BM::FEATURE_SUBSURFACE_SCATTERING, "SUBSURFACE_SCATTERING" },
		{ BM::FEATURE_SUBSURFACE_TRANSMITTANCE, "SUBSURFACE_TRANSMITTANCE" },
		{ BM::FEATURE_BACKLIGHT, "BACKLIGHT" },
		{ BM::FEATURE_REFRACTION, "REFRACTION" },
		{ BM::FEATURE_DETAIL, "DETAIL" },
		{ BM::FEATURE_BENT_NORMAL_MAPPING, "BENT_NORMAL_MAPPING" },
	};
	for (const auto &e : feature_table) {
		if (get_feature(e.feature)) {
			if (!features_str.empty()) {
				features_str += ", ";
			}
			features_str += e.name;
		}
	}
	if (features_str.empty()) {
		features_str = "none";
	}

	return std::format(
			"BaseMaterial3DDescription {{\n"
			"  render_priority:   {}\n"
			"  shading_mode:      {}\n"
			"  transparency:      {}\n"
			"  blend_mode:        {}\n"
			"  cull_mode:         {}\n"
			"  depth_draw_mode:   {}\n"
			"  billboard_mode:    {}\n"
			"  texture_filter:    {}\n"
			"  detail_blend_mode: {}\n"
			"  detail_uv_layer:   {}\n"
			"  distance_fade:     {}\n"
			"  emission_op:       {}\n"
			"  flags:             {}\n"
			"  features:          {}\n"
			"}}",
			render_priority,
			shading_mode_str(),
			transparency_str(),
			blend_mode_str(blend_mode),
			cull_mode_str(),
			depth_draw_str(),
			billboard_str(),
			texture_filter_str(),
			blend_mode_str(detail_blend_mode),
			detail_uv_layer == BM::DETAIL_UV_1 ? "UV1" : "UV2",
			distance_fade_str(),
			emission_op == BM::EMISSION_OP_ADD ? "Add" : "Multiply",
			flags_str,
			features_str);
}
