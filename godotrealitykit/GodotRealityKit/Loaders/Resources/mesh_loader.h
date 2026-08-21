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

#import <Metal/Metal.h>

#include "mesh_types.h"
#include "resource_loader.h"
#include "signposts.h"

#include <godot_cpp/classes/skeleton_modifier3d.hpp>
#include <godot_cpp/classes/skin.hpp>

namespace gdrk {

class ChangedMeshDependencyListSet : public ChangedDependencyListSet {
public:
	explicit ChangedMeshDependencyListSet(uint32_t p_set_size) :
			ChangedDependencyListSet(p_set_size) {}

	_FORCE_INLINE_ void add_changed_dep_instance(godot::RID p_instance_rid) {
		changed_dep_instance_rids.push_back(p_instance_rid);
	}

private:
	friend class MeshDependencyList;

	godot::LocalVector<godot::RID> changed_dep_instance_rids;
};

class MeshDependencyList : protected DependencyList {
public:
	void replace_changed(const ChangedMeshDependencyListSet &p_dirty_deps, class MeshLoader *p_loader);

	_FORCE_INLINE_ Span<const Dependency> get() const {
		return DependencyList::get();
	}

	_FORCE_INLINE_ const LocalBitVector &changed() const {
		return DependencyList::changed();
	}

private:
	godot::LocalVector<godot::RID> dep_instance_rids;
};

// Manages mesh surface resources and drives MeshEncoder each frame.
class MeshLoader : public ResourceLoader<MeshLoader> {
	GDCLASS(MeshLoader, Object);

protected:
	static void _bind_methods() {}

public:
	void initialize();

	void _reserve(uint32_t p_capacity) {
		ResourceLoader<MeshLoader>::_reserve(p_capacity);
		meshes.resize(p_capacity);
		mesh_rid_idxs.resize(p_capacity);
		mesh_dirty_position_idxs.resize(p_capacity);
	}

	uint32_t find_or_add(godot::RID p_mesh_rid,
			uint64_t p_instance_id,
			godot::Mesh *p_mesh = nullptr,
			godot::Skeleton3D *p_skeleton = nullptr);

	void remove(uint32_t p_idx);

	void add_instance(uint32_t p_idx, godot::RID p_instance_rid);
	void remove_instance(uint32_t p_idx, godot::RID p_instance_rid);

	void add_skeleton_modifier(godot::SkeletonModifier3D *p_skeleton_modifier);

	void set_blend_shape_weights(uint32_t p_idx, Span<const float> p_weights);
	void set_skin(uint32_t p_idx, const godot::Ref<godot::Skin> &p_skin);

	bool update(id<MTLCommandBuffer> p_command_buffer);

	godot::AABB get_bounds(godot::RID p_mesh_rid, uint64_t p_instance_id, uint32_t p_surface_idx) const {
		const Mesh *mesh = find_mesh(p_mesh_rid, p_instance_id, p_surface_idx);
		if (!mesh) {
			return godot::AABB();
		}
		return mesh->surface_infos[p_surface_idx].bounds;
	}

	swift::Optional<GodotRealityKit::MeshResource> find_resource(godot::RID p_mesh_rid, uint64_t p_instance_id, uint32_t p_surface_idx) const;

	void mark_positions_dirty(uint32_t p_idx) {
		mesh_dirty_position_idxs.insert(p_idx);
	}

	void reset_dirty() {
		ResourceLoader<MeshLoader>::reset_dirty();
	}

private:
	void mesh_changed(uint32_t p_mesh_rid_idx) {
		dirty_mesh_rid_idxs.insert(p_mesh_rid_idx);
	}

	void skeleton_pose_updated(uint64_t p_skeleton_id);

	inline const Mesh *find_mesh(godot::RID p_mesh_rid,
			uint64_t p_instance_id,
			uint32_t p_surface_idx) const {
		if (!p_mesh_rid.is_valid()) {
			return nullptr;
		}

		const MeshKey key = MeshKey{
			.mesh_rid = p_mesh_rid,
			.instance_id = p_instance_id,
		};

		ERR_FAIL_COND_V(!mesh_to_idx.has(key), nullptr);
		const uint32_t idx = mesh_to_idx.get(key);
		const Mesh &mesh = meshes[idx];
		// Guard transient surface-count mismatches to avoid out-of-bounds crashes.
		if (p_surface_idx >= mesh.surfaces.size() ||
				p_surface_idx >= mesh.surface_infos.size()) {
			return nullptr;
		}
		return &mesh;
	}

	Mesh::SurfaceInfo get_surface_info(const godot::Dictionary &p_surface, godot::RID p_mesh_rid) const;
	bool surface_needs_new_resource(const Mesh::SurfaceInfo &p_cur, const Mesh::SurfaceInfo &p_new) const;
	bool bounds_changed(const godot::AABB &p_cur, const godot::AABB &p_new, float p_percent) const;

	struct alignas(16) MeshKey {
		godot::RID mesh_rid;
		uint64_t instance_id = 0;

		friend bool operator==(MeshKey, MeshKey) = default;
	};

	struct Hasher {
		static uint32_t hash(const MeshKey &v) {
			uint32_t res = HASH_MURMUR3_SEED;
			res = godot::hash_murmur3_one_64(v.mesh_rid.get_id(), res);
			res = godot::hash_murmur3_one_64(v.instance_id, res);
			return godot::hash_fmix32(res);
		}
	};

	MeshEncoder mesh_encoder;

	RID_Associated<uint32_t> instance_rid_to_idx;
	godot::HashMap<MeshKey, uint32_t, Hasher> mesh_to_idx;
	godot::LocalVector<Mesh> meshes;
	godot::LocalVector<uint32_t> mesh_rid_idxs;
	LocalBitVector mesh_dirty_position_idxs;
	godot::HashSet<uint64_t> dirty_skeleton_ids;
	LocalBitVector dirty_mesh_rid_idxs;
};

inline void MeshDependencyList::replace_changed(const ChangedMeshDependencyListSet &p_dirty_deps, MeshLoader *p_loader) {
	godot::LocalVector<godot::RID> new_dep_instance_rids;
	new_dep_instance_rids.reserve(uint32_t(deps.size()));
	for (uint32_t dep_idx = 0; dep_idx < deps.size(); dep_idx++) {
		if (!p_dirty_deps.changed_dst_idxs.has(deps[dep_idx].dst)) {
			new_dep_instance_rids.push_back(dep_instance_rids[dep_idx]);
		} else {
			p_loader->remove_instance(deps[dep_idx].src, dep_instance_rids[dep_idx]);
		}
	}

	for (uint32_t new_dep_idx = 0; new_dep_idx < p_dirty_deps.changed_dep_instance_rids.size(); new_dep_idx++) {
		const godot::RID instance_rid = p_dirty_deps.changed_dep_instance_rids[new_dep_idx];
		p_loader->add_instance(p_dirty_deps.changed_deps[new_dep_idx].src, instance_rid);
		new_dep_instance_rids.push_back(instance_rid);
	}

	dep_instance_rids = std::move(new_dep_instance_rids);
	DependencyList::replace_changed(p_dirty_deps, p_loader);
}

} //namespace gdrk
