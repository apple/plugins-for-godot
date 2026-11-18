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

#include "../Util/culling.h"
#include "../resource_loaders.h"

#include "camera_loader.h"
#include "node_loader.h"
#include "portal_mesh_instance_3d.h"

#include <godot_cpp/classes/mesh_instance3d.hpp>

namespace gdrk {

template <typename Derived, std::derived_from<godot::MeshInstance3D> MeshInstance>
class MeshInstanceLoaderBase : public NodeLoader<Derived, MeshInstance> {
	using Self = MeshInstanceLoaderBase<Derived, MeshInstance>;
	using Base = NodeLoader<Derived, MeshInstance>;

public:
	MeshInstanceLoaderBase(NodeLoaders *p_owner) :
			Base(p_owner) {}

	static constexpr bool receives_hover_effects = true;

	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		dep_states.resize(p_capacity);
	}

	void initialize(const CameraLoader *p_camera_loader) {
		camera_loader = p_camera_loader;
	}

	uint32_t add(MeshInstance *p_node) {
		const uint32_t idx = Base::add(p_node);
		dep_states[idx] = DependencyState();
		return idx;
	}

	void update_deps(ResourceLoaderSet &p_resource_loaders);

	void update_dirty_flags(const ResourceLoaderSet &p_resource_loaders);
	void update_deps_usage(ResourceLoaderSet &p_resource_loaders) const;

	void update(const ResourceLoaderSet &p_resource_loaders);

protected:
	const CameraLoader *camera_loader;

protected:
	struct alignas(8) DependencyState {
		uint32_t mesh_hash = 0;
		uint32_t material_hash = 0;
		uint32_t blend_shape_hash = 0;
		uint32_t mesh_index = 0;
	};

	godot::LocalVector<DependencyState> dep_states;

private:
	DependencyList mesh_deps;
	DependencyList material_deps;
};

class MeshInstanceLoader : public MeshInstanceLoaderBase<MeshInstanceLoader, godot::MeshInstance3D> {
	NODE_LOADER(MeshInstanceLoader, MeshInstanceLoaderBase, godot::MeshInstance3D);

public:
	static constexpr bool manages_visibility_state = true;
	static constexpr bool manages_entity_registrations = true;

	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		culling_states.resize(p_capacity);
	}

	uint32_t add(godot::MeshInstance3D *p_node) {
		uint32_t index = Base::add(p_node);
		culling_states[index] = CullingState();
		culling_system.register_entry(index, 0);
		return index;
	}

	uint32_t remove(godot::MeshInstance3D *p_node) {
		uint32_t index = Base::remove(p_node);
		culling_system.unregister_entry(index, 0);
		return index;
	}

	void update_visibility_state(const MeshLoader *p_mesh);
	void on_transform_changed(uint32_t p_idx, const godot::Transform3D &transform);
	void _on_visibility_changed(uint32_t p_idx);

	struct CullingState {
		bool transform_updated = false;
		// Tracks whether the node was treated as portal world content on the previous
		// update, so we re-issue update_entry when it transitions in or out of a portal.
		bool was_in_portal_world = false;

		godot::AABB local_aabb;
	};

	godot::LocalVector<CullingState> culling_states;
	CullingSystem culling_system;
};

class RealityPortalMeshInstanceLoader : public MeshInstanceLoaderBase<RealityPortalMeshInstanceLoader, RealityPortalMeshInstance3D> {
	NODE_LOADER(RealityPortalMeshInstanceLoader, MeshInstanceLoaderBase, RealityPortalMeshInstance3D)
public:
	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		node_portal_states.resize(p_capacity);
		node_portal_rids.resize(p_capacity);
	}

	uint32_t add(RealityPortalMeshInstance3D *p_node);
	uint32_t remove(RealityPortalMeshInstance3D *p_node);

	void update(const ResourceLoaderSet &p_resource_loaders);

private:
	struct alignas(8) PortalState {
		uint64_t target_node_id;
		uint32_t properties_hash;
	};

	godot::LocalVector<PortalState> node_portal_states;
	godot::LocalVector<godot::RID> node_portal_rids;
};

class RealityPortalCrossingLoader : public NodeLoaderBase<RealityPortalCrossingLoader, RealityPortalCrossing3D> {
	NODE_LOADER(RealityPortalCrossingLoader, NodeLoaderBase, RealityPortalCrossing3D)
public:
	uint32_t add(RealityPortalCrossing3D *p_node);
	uint32_t remove(RealityPortalCrossing3D *p_node);
};

} //namespace gdrk
