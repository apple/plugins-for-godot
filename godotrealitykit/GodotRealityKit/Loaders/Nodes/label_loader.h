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

#include "../resource_loaders.h"
#include "node_loader.h"

#include <godot_cpp/classes/label3d.hpp>

namespace gdrk {

class LabelLoader : public NodeLoader<LabelLoader, godot::Label3D> {
	NODE_LOADER(LabelLoader, NodeLoader, godot::Label3D)
public:
	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		dep_states.resize(p_capacity);
	}

	uint32_t add(godot::Label3D *p_node) {
		const uint32_t idx = Base::add(p_node);
		dep_states[idx] = DependencyState();
		return idx;
	}

	void update_deps(ResourceLoaderSet &p_resource_loaders);

	void update(const ResourceLoaderSet &p_resource_loaders);

private:
	struct DependencyState {
		uint32_t text_hash = 0;
		uint32_t material_hash = 0;
		uint32_t font_atlas_hash = 0;
	};

	MeshDependencyList mesh_deps;
	DependencyList material_deps;

	godot::LocalVector<DependencyState> dep_states;
};

} //namespace gdrk
