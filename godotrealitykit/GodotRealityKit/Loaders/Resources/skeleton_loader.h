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

#include "resource_loader.h"

#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/skeleton_modifier3d.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace gdrk {

class SkeletonLoader : public ResourceLoader<SkeletonLoader> {
	GDCLASS(SkeletonLoader, Object);

protected:
	static void _bind_methods() {}

public:
	void _reserve(uint32_t p_capacity) {
		ResourceLoader<SkeletonLoader>::_reserve(p_capacity);
		skeletons.resize(p_capacity);
	}

	uint32_t find_or_add(uint64_t p_skeleton_id, godot::Skeleton3D *p_skeleton);
	void remove(uint32_t p_idx);

	const godot::LocalVector<godot::Transform3D> &get_bone_pose_snapshot(uint32_t p_idx) const {
		return skeletons[p_idx].bone_pose_snapshot;
	}

private:
	void _update_snapshot(uint32_t p_idx);

	struct Skeleton {
		uint64_t skeleton_id = 0;
		godot::LocalVector<godot::Transform3D> bone_pose_snapshot;
	};

	godot::HashMap<uint64_t, uint32_t> skeleton_id_to_idx;
	godot::LocalVector<Skeleton> skeletons;
};

} //namespace gdrk
