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

#include "skeleton_loader.h"

using namespace gdrk;

uint32_t SkeletonLoader::find_or_add(uint64_t p_skeleton_id, godot::Skeleton3D *p_skeleton) {
	const auto found = skeleton_id_to_idx.find(p_skeleton_id);
	if (found) {
		return found->value;
	}

	const uint32_t idx = alloc_idx();
	skeletons[idx] = Skeleton{ .skeleton_id = p_skeleton_id };
	skeleton_id_to_idx.insert(p_skeleton_id, idx);

	godot::Callable pose_updated_callable =
			callable_mp(this, &SkeletonLoader::_update_snapshot).bind(idx);
	if (p_skeleton && !p_skeleton->is_connected("skeleton_updated", pose_updated_callable)) {
		p_skeleton->connect("skeleton_updated", pose_updated_callable);
	}

	return idx;
}

void SkeletonLoader::remove(uint32_t p_idx) {
	skeleton_id_to_idx.erase(skeletons[p_idx].skeleton_id);

	skeletons[p_idx] = Skeleton();
	free_idx(p_idx);
}

void SkeletonLoader::_update_snapshot(uint32_t p_idx) {
	mark_dirty(p_idx);

	godot::Object *obj = godot::ObjectDB::get_instance(skeletons[p_idx].skeleton_id);
	godot::Skeleton3D *skeleton = godot::Object::cast_to<godot::Skeleton3D>(obj);
	if (!skeleton) {
		return;
	}

	// Snapshot bone poses now — before Skeleton3D restores pre-modifier state.
	const int32_t bone_count = skeleton->get_bone_count();
	godot::LocalVector<godot::Transform3D> &snapshot = skeletons[p_idx].bone_pose_snapshot;
	snapshot.resize(bone_count);
	for (int32_t i = 0; i < bone_count; i++) {
		snapshot[i] = skeleton->get_bone_global_pose(i);
	}
}
