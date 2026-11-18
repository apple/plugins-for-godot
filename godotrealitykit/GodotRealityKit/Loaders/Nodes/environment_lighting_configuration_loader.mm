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

#include "environment_lighting_configuration_loader.h"

#include "node_loaders.h"

#include <godot_cpp/classes/world_environment.hpp>

using namespace gdrk;

void RealityKitEnvironmentLightingConfigurationLoader::apply(State &p_state, const RealityKitEnvironmentLightingConfiguration *p_node) {
	godot::Node *parent = p_node->get_parent();
	p_state.applied_weight = p_node->get_environment_lighting_weight();
	p_state.applied_parent_id = parent ? parent->get_instance_id() : 0;
	p_state.applied_to_root = godot::Object::cast_to<godot::WorldEnvironment>(parent) != nullptr;

	if (p_state.applied_to_root) {
		owner->get_root_entity().setEnvironmentLightingWeight(p_state.applied_weight);
	} else if (p_state.applied_parent_id) {
		owner->environment_lighting_create(p_state.applied_parent_id, p_state.applied_weight);
	}
}

void RealityKitEnvironmentLightingConfigurationLoader::unapply(State &p_state) {
	if (p_state.applied_to_root) {
		owner->get_root_entity().unsetEnvironmentLightingWeight();
	} else if (p_state.applied_parent_id) {
		owner->environment_lighting_free(p_state.applied_parent_id);
	}
	p_state = State();
}

uint32_t RealityKitEnvironmentLightingConfigurationLoader::add(RealityKitEnvironmentLightingConfiguration *p_node) {
	const uint32_t idx = Base::add(p_node);
	node_state[idx] = State();
	apply(node_state[idx], p_node);
	return idx;
}

uint32_t RealityKitEnvironmentLightingConfigurationLoader::remove(RealityKitEnvironmentLightingConfiguration *p_node) {
	const uint32_t idx = Base::remove(p_node);
	unapply(node_state[idx]);
	return idx;
}

void RealityKitEnvironmentLightingConfigurationLoader::update(const ResourceLoaderSet &p_resource_loaders) {
	Base::update(p_resource_loaders);

	for_each_valid([&](uint32_t p_idx) {
		RealityKitEnvironmentLightingConfiguration *node = nodes[p_idx];
		State &state = node_state[p_idx];

		godot::Node *parent = node->get_parent();
		const uint64_t parent_id = parent ? parent->get_instance_id() : 0;

		if (parent_id != state.applied_parent_id) {
			unapply(state);
			apply(state, node);
			return;
		}

		const float weight = node->get_environment_lighting_weight();
		if (weight == state.applied_weight) {
			return;
		}

		state.applied_weight = weight;
		if (state.applied_to_root) {
			owner->get_root_entity().setEnvironmentLightingWeight(weight);
		} else if (parent_id) {
			owner->environment_lighting_update(parent_id, weight);
		}
	});
}
