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

#include "node_loader.h"

#include <godot_cpp/classes/directional_light3d.hpp>

namespace gdrk {

class CameraLoader;
class RealityKitDirectionalLightShadow3D;

class DirectionalLightLoader : public NodeLoader<DirectionalLightLoader, godot::DirectionalLight3D> {
	NODE_LOADER(DirectionalLightLoader, NodeLoader, godot::DirectionalLight3D)
public:
	void update(const ResourceLoaderSet &p_resource_loaders);

	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		dep_states.resize(p_capacity);
	}

	uint32_t add(godot::DirectionalLight3D *p_node) {
		const uint32_t idx = Base::add(p_node);
		dep_states[idx] = DependencyState();
		return idx;
	}

	void set_world_scale(float value) { world_scale = value; }

	void set_extra_light_frustum_scale(float value) { extra_light_frustum_scale = value; }

	// Called by RealityKitDirectionalLightShadow3DLoader when a shadow node is
	// added or removed under this light. Pass nullptr to reset to automatic shadow.
	void setFixedShadow(godot::DirectionalLight3D *p_parent, RealityKitDirectionalLightShadow3D *p_shadow_node);

private:
	struct DependencyState {
		uint32_t light_hash = 0;
		uint32_t shadow_hash = 0;
		bool shadow_enabled = false;
		RealityKitDirectionalLightShadow3D *shadow_node = nullptr;
	};

	float world_scale = 1.0;
	float extra_light_frustum_scale = 1.0;
	godot::LocalVector<DependencyState> dep_states;
};
} //namespace gdrk
