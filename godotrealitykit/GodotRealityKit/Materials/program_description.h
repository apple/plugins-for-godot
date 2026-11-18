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

#pragma once

#include "material_bridge.h"

#undef check

#include <godot_cpp/classes/base_material3d.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/visual_shader.hpp>
#include <godot_cpp/templates/hashfuncs.hpp>

#include <format>

namespace gdrk {

struct RenderModeDescription {
	enum BlendMode : uint8_t {
		BLEND_MIX = 0,
		BLEND_ADD,
		BLEND_SUB,
		BLEND_MUL,
		BLEND_PREMUL_ALPHA,
		BLEND_MAX,
	};

	enum DepthDrawMode : uint8_t {
		DEPTH_DRAW_OPAQUE = 0,
		DEPTH_DRAW_ALWAYS,
		DEPTH_DRAW_NEVER,
		DEPTH_DRAW_MAX,
	};

	enum DepthTestMode : uint8_t {
		DEPTH_TEST_DEFAULT = 0,
		DEPTH_TEST_INVERTED = 2,
	};

	enum CullMode : uint8_t {
		CULL_BACK = 0,
		CULL_FRONT,
		CULL_DISABLED,
		CULL_MAX,
	};

	enum DiffuseMode : uint8_t {
		DIFFUSE_LAMBERT = 0,
		DIFFUSE_LAMBERT_WRAP,
		DIFFUSE_BURLEY,
		DIFFUSE_TOON,
		DIFFUSE_MAX,
	};

	enum SpecularMode : uint8_t {
		SPECULAR_SCHLICK_GGX = 0,
		SPECULAR_TOON,
		SPECULAR_DISABLED,
		SPECULAR_MAX,
	};

	enum Flag : uint8_t {
		FLAG_DEPTH_PREPASS_ALPHA = 0,
		FLAG_DEPTH_TEST_DISABLED,
		FLAG_SSS_MODE_SKIN,
		FLAG_UNSHADED,
		FLAG_WIREFRAME,
		FLAG_SKIP_VERTEX_TRANSFORM,
		FLAG_WORLD_VERTEX_COORDS,
		FLAG_ENSURE_CORRECT_NORMALS,
		FLAG_SHADOWS_DISABLED,
		FLAG_AMBIENT_LIGHT_DISABLED,
		FLAG_SHADOW_TO_OPACITY,
		FLAG_VERTEX_LIGHTING,
		FLAG_PARTICLE_TRAILS,
		FLAG_ALPHA_TO_COVERAGE,
		FLAG_ALPHA_TO_COVERAGE_AND_ONE,
		FLAG_DEBUG_SHADOW_SPLITS,
		FLAG_FOG_DISABLED,
		FLAG_SPECULAR_OCCLUSION_DISABLED,
		FLAG_MAX,
	};

	enum MultiMode : uint8_t {
		MULTI_BLEND = 0,
		MULTI_DEPTH_DRAW,
		MULTI_DEPTH_TEST,
		MULTI_CULL,
		MULTI_DIFFUSE,
		MULTI_SPECULAR,
		MULTI_MAX,
	};

	uint32_t blend : 3 = BLEND_MIX;
	uint32_t depth_draw : 2 = DEPTH_DRAW_OPAQUE;
	uint32_t depth_test : 2 = DEPTH_TEST_DEFAULT;
	uint32_t cull : 2 = CULL_BACK;
	uint32_t diffuse : 2 = DIFFUSE_LAMBERT;
	uint32_t specular : 2 = SPECULAR_SCHLICK_GGX;
	uint32_t flags = 0;

	inline bool get_flag(Flag p_flag) const { return (flags & (1u << p_flag)) != 0; }
	inline void set_flag(Flag p_flag, bool p_enabled) {
		const uint32_t bit = 1u << p_flag;
		flags = p_enabled ? (flags | bit) : (flags & ~bit);
	}

	static RenderModeDescription from_visual_shader(const godot::Ref<godot::VisualShader> &p_shader);

	std::string to_string() const;
};

enum DepthPassMode {
	DepthPrepass = 0,
	DepthPostpass = 1,

	DepthPassModeCount
};

struct BaseMaterial3DDescription {
	using BM = godot::BaseMaterial3D;
	godot::RID next_pass = godot::RID();
	int32_t render_priority = 0;
	uint32_t shading_mode : godot::Math::get_num_bits(BM::SHADING_MODE_MAX - 1) = BM::SHADING_MODE_PER_PIXEL;
	uint32_t transparency : godot::Math::get_num_bits(BM::TRANSPARENCY_MAX - 1) = BM::TRANSPARENCY_DISABLED;
	uint32_t blend_mode : godot::Math::get_num_bits(BM::BLEND_MODE_PREMULT_ALPHA - 0) = BM::BLEND_MODE_MIX;
	uint32_t cull_mode : godot::Math::get_num_bits(BM::CULL_DISABLED - 0) = BM::CULL_BACK;
	uint32_t depth_draw_mode : godot::Math::get_num_bits(BM::DEPTH_DRAW_DISABLED - 0) = BM::DEPTH_DRAW_OPAQUE_ONLY;
	uint32_t billboard_mode : godot::Math::get_num_bits(BM::BILLBOARD_PARTICLES - 0) = BM::BILLBOARD_DISABLED;
	uint32_t texture_filter : godot::Math::get_num_bits(BM::TEXTURE_FILTER_MAX - 1) = BM::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS;
	uint32_t detail_blend_mode : godot::Math::get_num_bits(BM::BLEND_MODE_PREMULT_ALPHA - 0) = BM::BLEND_MODE_MIX;
	uint32_t detail_uv_layer : godot::Math::get_num_bits(BM::DETAIL_UV_2 - 0) = BM::DETAIL_UV_1;
	uint32_t distance_fade : godot::Math::get_num_bits(BM::DISTANCE_FADE_OBJECT_DITHER - 0) = BM::DISTANCE_FADE_DISABLED;
	uint32_t emission_op : godot::Math::get_num_bits(BM::EMISSION_OP_MULTIPLY - 0) = BM::EMISSION_OP_ADD;
	uint32_t has_emission_texture : 1 = false;
	uint32_t flags = 0;
	uint32_t features = 0;
	DepthPassMode depth_pass_mode = DepthPassMode::DepthPrepass;

	inline bool get_flag(godot::BaseMaterial3D::Flags p_flag) const { return flags & (1 << p_flag); }
	inline bool get_feature(godot::BaseMaterial3D::Feature p_feature) const { return features & (1 << p_feature); }
	inline bool is_transparent() const { return transparency == godot::BaseMaterial3D::TRANSPARENCY_ALPHA; }

	inline uint32_t hash() {
		uint32_t h = base_program_hash();
		h = godot::hash_murmur3_one_32(render_priority, h);
		h = godot::hash_murmur3_one_32(depth_pass_mode, h);
		return godot::hash_fmix32(h);
	}

	inline uint32_t base_program_hash() const {
		uint32_t h = godot::hash_murmur3_one_64(next_pass.is_valid() ? (uint64_t)next_pass.get_id() : 0);
		h = godot::hash_murmur3_one_32(shading_mode, h);
		h = godot::hash_murmur3_one_32(transparency, h);
		h = godot::hash_murmur3_one_32(blend_mode, h);
		h = godot::hash_murmur3_one_32(cull_mode, h);
		h = godot::hash_murmur3_one_32(depth_draw_mode, h);
		h = godot::hash_murmur3_one_32(billboard_mode, h);
		h = godot::hash_murmur3_one_32(texture_filter, h);
		h = godot::hash_murmur3_one_32(detail_blend_mode, h);
		h = godot::hash_murmur3_one_32(detail_uv_layer, h);
		h = godot::hash_murmur3_one_32(distance_fade, h);
		h = godot::hash_murmur3_one_32(emission_op, h);
		h = godot::hash_murmur3_one_32(has_emission_texture, h);
		h = godot::hash_murmur3_one_32(flags, h);
		h = godot::hash_murmur3_one_32(features, h);
		return godot::hash_fmix32(h);
	}

	std::string to_string() const;
};

struct ShaderMaterialDescription {
	using SM = godot::ShaderMaterial;
	godot::Ref<godot::VisualShader> shader;
	godot::LocalVector<gdrk::UniformDescriptor> uniforms;
	godot::LocalVector<uint8_t> texture_idxs;
	godot::LocalVector<uint8_t> const_texture_idxs;
	RenderModeDescription render_mode;
	int32_t render_priority = 0;
	bool transparent = false;
	DepthPassMode depth_pass_mode = DepthPassMode::DepthPrepass;

	ShaderMaterialDescription() = default;
	ShaderMaterialDescription(godot::Ref<godot::VisualShader> p_shader, int32_t p_render_priority = 0) :
			shader(p_shader),
			render_mode(RenderModeDescription::from_visual_shader(p_shader)),
			render_priority(p_render_priority) {}

	inline bool is_transparent() const { return transparent; }
	std::string to_string() const;

	inline uint32_t base_program_hash() const {
		if (shader.is_null()) {
			return 0;
		}

		if (shader->get_path().length()) {
			return godot::HashMapHasherDefault::hash(shader->get_path());
		}
		return godot::HashMapHasherDefault::hash(shader.ptr());
	}

	inline uint32_t hash() {
		if (shader.is_null()) {
			return 0;
		}

		uint32_t h = godot::HashMapHasherDefault::hash(shader->get_rid().get_id());
		h = godot::hash_murmur3_one_32(render_priority, h);
		return depth_pass_mode == DepthPostpass ? godot::hash_murmur3_one_32(1, h) : h;
	}

	template <std::invocable<uint8_t, const UniformDescriptor &> Fn>
	void for_each_texture_constants(Fn &&p_callback) const {
		for (uint8_t idx : const_texture_idxs) {
			const UniformDescriptor &udesc = uniforms[idx];
			p_callback(idx, udesc);
		}
	}

	template <std::invocable<uint8_t, const UniformDescriptor &> Fn>
	void for_each_texture_uniform(Fn &&p_callback) const {
		for (uint8_t idx : texture_idxs) {
			const UniformDescriptor &udesc = uniforms[idx];
			p_callback(idx, udesc);
		}
	}
};

#define PD_COMMON_GETTER(type, name) \
	inline type name() const { return material_type == MATERIAL_TYPE_SHADER_MATERIAL ? asShaderMaterial().name() : asBaseMaterial3D().name(); }

struct ProgramDescription {
	~ProgramDescription() {
	}

	ProgramDescription(BaseMaterial3DDescription &&p_descriptor) :
			material_type(MATERIAL_TYPE_BASE_MATERIAL3D), desc(std::move(p_descriptor)) {
		hash = std::get<BaseMaterial3DDescription>(desc).hash();
		base_program_hash = std::get<BaseMaterial3DDescription>(desc).base_program_hash();
	}

	ProgramDescription(const BaseMaterial3DDescription &p_descriptor) :
			material_type(MATERIAL_TYPE_BASE_MATERIAL3D), desc(p_descriptor) {
		hash = std::get<BaseMaterial3DDescription>(desc).hash();
		base_program_hash = std::get<BaseMaterial3DDescription>(desc).base_program_hash();
	}

	ProgramDescription(ShaderMaterialDescription &&p_descriptor) :
			material_type(MATERIAL_TYPE_SHADER_MATERIAL), desc(std::move(p_descriptor)) {
		hash = std::get<ShaderMaterialDescription>(desc).hash();
		base_program_hash = std::get<ShaderMaterialDescription>(desc).base_program_hash();
	}

	ProgramDescription(const ShaderMaterialDescription &p_descriptor) :
			material_type(MATERIAL_TYPE_SHADER_MATERIAL), desc(p_descriptor) {
		hash = std::get<ShaderMaterialDescription>(desc).hash();
		base_program_hash = std::get<ShaderMaterialDescription>(desc).base_program_hash();
	}

	ProgramDescription(godot::Ref<godot::VisualShader> p_shader) :
			ProgramDescription(ShaderMaterialDescription(p_shader)) {
	}

	ProgramDescription() :
			material_type(MATERIAL_TYPE_UNKNOWN), hash(0) {
	}

	ProgramDescription(const ProgramDescription &p_desc) :
			material_type(p_desc.material_type), desc(p_desc.desc), hash(p_desc.hash), base_program_hash(p_desc.base_program_hash) {
	}

	BaseMaterial3DDescription &asBaseMaterial3D() { return std::get<BaseMaterial3DDescription>(desc); }
	ShaderMaterialDescription &asShaderMaterial() { return std::get<ShaderMaterialDescription>(desc); }

	const BaseMaterial3DDescription &asBaseMaterial3D() const { return std::get<BaseMaterial3DDescription>(desc); }
	const ShaderMaterialDescription &asShaderMaterial() const { return std::get<ShaderMaterialDescription>(desc); }

	PD_COMMON_GETTER(bool, is_transparent);
	PD_COMMON_GETTER(std::string, to_string);

	inline bool is_valid() const {
		return material_type != MATERIAL_TYPE_UNKNOWN;
	}

	MaterialType material_type;
	uint32_t hash = 0;
	uint32_t base_program_hash = 0;
	std::variant<std::monostate, BaseMaterial3DDescription, ShaderMaterialDescription> desc;
};
} //namespace gdrk
