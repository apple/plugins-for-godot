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

#include "environment_lighting_configuration.h"
#include "node_loader.h"

namespace gdrk {

// RealityKitEnvironmentLightingConfiguration is a marker node with no entity of its own. Its
// parent is the root of an EnvironmentLightingEffect, except under a WorldEnvironment: that node
// is global, so the weight goes on the root entity, which is also what receives its IBL.
class RealityKitEnvironmentLightingConfigurationLoader : public NodeLoaderBase<RealityKitEnvironmentLightingConfigurationLoader, RealityKitEnvironmentLightingConfiguration> {
	NODE_LOADER(RealityKitEnvironmentLightingConfigurationLoader, NodeLoaderBase, RealityKitEnvironmentLightingConfiguration)
public:
	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		node_state.resize(p_capacity);
	}

	uint32_t add(RealityKitEnvironmentLightingConfiguration *p_node);
	uint32_t remove(RealityKitEnvironmentLightingConfiguration *p_node);

	void update(const ResourceLoaderSet &p_resource_loaders);

private:
	struct State {
		float applied_weight = 1.0f;
		uint64_t applied_parent_id = 0;
		bool applied_to_root = false;
	};

	void apply(State &p_state, const RealityKitEnvironmentLightingConfiguration *p_node);
	void unapply(State &p_state);

	godot::LocalVector<State> node_state;
};

} // namespace gdrk
