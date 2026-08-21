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

#include <format>

namespace gdrk {
struct BaseMaterial3DDescription {
	using BM = godot::BaseMaterial3D;
	godot::RID next_pass = godot::RID();
	int32_t render_priority = 0;
	uint32_t shading_mode : godot::get_num_bits(BM::SHADING_MODE_MAX - 1) = BM::SHADING_MODE_PER_PIXEL;
	uint32_t transparency : godot::get_num_bits(BM::TRANSPARENCY_MAX - 1) = BM::TRANSPARENCY_DISABLED;
	uint32_t blend_mode : godot::get_num_bits(BM::BLEND_MODE_PREMULT_ALPHA - 0) = BM::BLEND_MODE_MIX;
	uint32_t cull_mode : godot::get_num_bits(BM::CULL_DISABLED - 0) = BM::CULL_BACK;
	uint32_t depth_draw_mode : godot::get_num_bits(BM::DEPTH_DRAW_DISABLED - 0) = BM::DEPTH_DRAW_OPAQUE_ONLY;
	uint32_t billboard_mode : godot::get_num_bits(BM::BILLBOARD_PARTICLES - 0) = BM::BILLBOARD_DISABLED;
	uint32_t texture_filter : godot::get_num_bits(BM::TEXTURE_FILTER_MAX - 1) = BM::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS;
	uint32_t detail_blend_mode : godot::get_num_bits(BM::BLEND_MODE_PREMULT_ALPHA - 0) = BM::BLEND_MODE_MIX;
	uint32_t detail_uv_layer : godot::get_num_bits(BM::DETAIL_UV_2 - 0) = BM::DETAIL_UV_1;
	uint32_t distance_fade : godot::get_num_bits(BM::DISTANCE_FADE_OBJECT_DITHER - 0) = BM::DISTANCE_FADE_DISABLED;
	uint32_t flags = 0;
	uint32_t features = 0;

	inline bool get_flag(godot::BaseMaterial3D::Flags p_flag) const { return flags & (1 << p_flag); }
	inline bool get_feature(godot::BaseMaterial3D::Feature p_feature) const { return features & (1 << p_feature); }
	inline bool is_transparent() const { return transparency == godot::BaseMaterial3D::TRANSPARENCY_ALPHA; }

	inline uint32_t hash() const {
		// Stable field hashes avoid unnecessary shader-compilation stalls.
		uint32_t state = godot::hash_murmur3_one_64(next_pass.get_id(), HASH_MURMUR3_SEED);
		state = godot::hash_murmur3_one_32(uint32_t(render_priority), state);
		state = godot::hash_murmur3_one_32(shading_mode, state);
		state = godot::hash_murmur3_one_32(transparency, state);
		state = godot::hash_murmur3_one_32(blend_mode, state);
		state = godot::hash_murmur3_one_32(cull_mode, state);
		state = godot::hash_murmur3_one_32(depth_draw_mode, state);
		state = godot::hash_murmur3_one_32(billboard_mode, state);
		state = godot::hash_murmur3_one_32(texture_filter, state);
		state = godot::hash_murmur3_one_32(detail_blend_mode, state);
		state = godot::hash_murmur3_one_32(detail_uv_layer, state);
		state = godot::hash_murmur3_one_32(distance_fade, state);
		state = godot::hash_murmur3_one_32(flags, state);
		state = godot::hash_murmur3_one_32(features, state);
		return godot::hash_fmix32(state);
	}

	std::string to_string() const;
};

struct ShaderMaterialDescription {
	using SM = godot::ShaderMaterial;
	godot::Ref<godot::VisualShader> shader;
	godot::LocalVector<gdrk::UniformDescriptor> uniforms;
	godot::LocalVector<uint8_t> texture_idxs;
	godot::LocalVector<uint8_t> const_texture_idxs;
	bool transparent;

	inline bool is_transparent() const { return transparent; }
	inline std::string to_string() const { return std::format("ShaderMaterialDescription: shader_rid: {}", shader.is_null() ? 0 : shader->get_rid().get_id()); }

	inline uint32_t hash() {
		if (shader.is_null()) {
			return 0;
		}

		return godot::HashMapHasherDefault::hash(shader->get_rid().get_id());
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
	}

	ProgramDescription(const BaseMaterial3DDescription &p_descriptor) :
			material_type(MATERIAL_TYPE_BASE_MATERIAL3D), desc(p_descriptor) {
		hash = std::get<BaseMaterial3DDescription>(desc).hash();
	}

	ProgramDescription(ShaderMaterialDescription &&p_descriptor) :
			material_type(MATERIAL_TYPE_SHADER_MATERIAL), desc(std::move(p_descriptor)) {
		hash = std::get<ShaderMaterialDescription>(desc).hash();
	}

	ProgramDescription(const ShaderMaterialDescription &p_descriptor) :
			material_type(MATERIAL_TYPE_SHADER_MATERIAL), desc(p_descriptor) {
		hash = std::get<ShaderMaterialDescription>(desc).hash();
	}

	ProgramDescription(godot::Ref<godot::VisualShader> p_shader) :
			ProgramDescription(ShaderMaterialDescription{
					.shader = p_shader }) {
	}

	ProgramDescription() :
			material_type(MATERIAL_TYPE_UNKNOWN), hash(0) {
	}

	ProgramDescription(const ProgramDescription &p_desc) :
			material_type(p_desc.material_type), desc(p_desc.desc), hash(p_desc.hash) {
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
	std::variant<std::monostate, BaseMaterial3DDescription, ShaderMaterialDescription> desc;
};
} //namespace gdrk
