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

#include "directional_light_loader.h"
#include "bridge.h"
#include "camera_loader.h"
#include "directional_light_shadow_3d.h"
#include "light_tunning.h"
#include "signposts.h"

using namespace gdrk;

void DirectionalLightLoader::setFixedShadow(godot::DirectionalLight3D *p_parent,
		RealityKitDirectionalLightShadow3D *p_shadow_node) {
	const auto found = node_id_to_idx.find(p_parent->get_instance_id());
	ERR_FAIL_COND(!found);
	dep_states[found->value].shadow_node = p_shadow_node;
	dep_states[found->value].shadow_hash = 0;
}

void DirectionalLightLoader::update(const ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	Base::update(p_resource_loaders);

	for_each_valid([&](uint32_t idx) {
		godot::DirectionalLight3D *node = nodes[idx];
		ERR_FAIL_NULL(node);
		DependencyState &state = dep_states[idx];

		const bool shadow_enabled = !!node->has_shadow();
		const float bias = node->get_param(godot::Light3D::PARAM_SHADOW_NORMAL_BIAS);

		if (state.shadow_node) {
			RealityKitDirectionalLightShadow3D *sn = state.shadow_node;
			const float extent_scale = world_scale * extra_light_frustum_scale;
			float z_near = sn->get_z_near() * extent_scale;
			float z_far = sn->get_z_far() * extent_scale;
			float orthographic_scale = sn->get_orthographic_scale() * extent_scale;
			float depth_bias = sn->get_depth_bias();

			if (!shadow_enabled) {
				if (state.shadow_hash != 0) {
					node_entities[idx].entity.disableDirectionalLightShadow();
					state.shadow_hash = 0;
				}
			} else {
				uint32_t shadow_hash = godot::hash_murmur3_one_float(z_near, 1);
				shadow_hash = godot::hash_murmur3_one_float(z_far, shadow_hash);
				shadow_hash = godot::hash_murmur3_one_float(orthographic_scale, shadow_hash);
				shadow_hash = godot::hash_murmur3_one_float(depth_bias, shadow_hash);
				shadow_hash = shadow_hash ? shadow_hash : 1;
				if (state.shadow_hash != shadow_hash) {
					node_entities[idx].entity.setDirectionalLightFixedShadow(z_near, z_far, orthographic_scale, depth_bias);
					state.shadow_hash = shadow_hash;
				}
			}
		} else {
			float max_distance = node->get_param(godot::Light3D::PARAM_SHADOW_MAX_DISTANCE) * world_scale;

			if (!shadow_enabled) {
				if (state.shadow_hash != 0) {
					node_entities[idx].entity.disableDirectionalLightShadow();
					state.shadow_hash = 0;
				}
			} else {
				uint32_t shadow_hash = godot::hash_murmur3_one_float(bias, 1);
				shadow_hash = godot::hash_murmur3_one_float(max_distance, shadow_hash);
				shadow_hash = shadow_hash ? shadow_hash : 2;
				if (state.shadow_hash != shadow_hash) {
					node_entities[idx].entity.setDirectionalLightAutomaticShadow(bias, max_distance);
					state.shadow_hash = shadow_hash;
				}
			}
		}

		float intensity = LightTunning::get_light_intensity(*node);
		godot::Color color = node->get_color();
		uint32_t hash = godot::hash_murmur3_one_float(intensity);
		hash = godot::hash_murmur3_one_32(color.to_rgba32(), hash);
		if (state.light_hash != hash) {
			node_entities[idx].entity.setDirectionalLight(gdrk::to_gdrk_color(color), intensity);
			state.light_hash = hash;
		}
	});
}
