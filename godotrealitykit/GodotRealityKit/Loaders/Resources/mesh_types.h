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

#include "Materials/material_bridge.h"
#include "mesh_encoder.h"
#include "types.h"
#include "utility.h"

#include <godot_cpp/classes/skin.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector4.hpp>

namespace gdrk {

// ---------------------------------------------------------------------------
// Mesh and its nested types. Shared between MeshLoader and MeshEncoder.

struct Mesh {
	struct Surface {
		GodotRealityKit::MeshResource resource = GodotRealityKit::MeshResource::init();
		MeshEncoder::EncodingMode encoding_mode = MeshEncoder::EncodingMode(0);

		// Raw Godot surface dictionary (ref-counted). Encode functions read vertex,
		// attribute, skin, and blend-shape data from here as needed.
		godot::Dictionary surface_data;

		// Persistent GPU buffers for the skeletalDeform kernel (ENCODING_MODE_DEFORM*).
		id<MTLBuffer> base_vertex_mtl = nil;
		id<MTLBuffer> skin_mtl = nil;
		id<MTLBuffer> blend_shape_mtl = nil;

		_FORCE_INLINE_ bool needs_deform() const {
			return skin_mtl != nil || blend_shape_mtl != nil;
		}
	};

	struct SurfaceInfo {
		uint32_t vertex_count = 0;
		uint32_t index_count = 0;
		uint8_t vertex_buffer_flags = 0;
		GDRKVertexBufferFormat vertex_buffer_format;
		GDRKVertexBufferFormat decompressed_vertex_buffer_format;
		godot::AABB bounds = godot::AABB();
		godot::Vector4 uv_scale = godot::Vector4(0.0f, 0.0f, 0.0f, 0.0f);
		godot::Dictionary data;

		friend bool operator==(const SurfaceInfo &lhs, const SurfaceInfo &rhs) = default;
	};

	// One palette slot. `bone` is -1 when the bind resolved to no skeleton bone, in
	// which case `bind_inverse` is used on its own.
	struct ResolvedBind {
		int32_t bone = -1;
		godot::Transform3D bind_inverse;
	};

	godot::RID mesh_rid;
	uint64_t instance_id = 0;
	uint64_t skeleton_id = 0;
	godot::AABB instance_aabb;
	SmallLocalVector<Surface, 8> surfaces;
	SmallLocalVector<SurfaceInfo, 8> surface_infos;
	SmallLocalVector<float, 8> blend_shape_weights;

	uint32_t blend_shape_count = 0;
	bool normalized_blend_shapes = false;

	// When all surfaces share the same vertex format / uv_scale and have no
	// per-instance deformation (no skeleton, no blend shapes, no compressed
	// attributes), they are packed into a single multi-part LowLevelMesh —
	// this resource — and the per-surface `Surface::resource` entries are
	// left default-initialized. `compacted_resource.isSome()` selects between
	// the two paths.
	GodotRealityKit::MeshResource compacted_resource = GodotRealityKit::MeshResource::init();

	// Cached skeletalDeform GPU inputs. Reallocated only when the required
	// byte length changes; otherwise we memcpy fresh data into .contents
	// each frame the deform runs.
	id<MTLBuffer> bone_transforms_mtl = nil;
	id<MTLBuffer> blend_shape_weights_mtl = nil;

	// Skin from the rep MeshInstance3D. Provides bind→bone mapping and inverse
	// bind poses. nil means "use identity bind poses with bind_idx == bone_idx".
	godot::Ref<godot::Skin> skin;

	// bind→bone mapping and inverse bind poses read out of `skin`. Both are fixed for
	// a given (skin, skeleton bone list), so upload_bone_transforms resolves them once
	// rather than re-reading them across the GDExtension boundary every frame. Rebuilt
	// when the bind count changes, when Skeleton3D::get_version() changes (add_bone /
	// set_bone_name / clear_bones), or when MeshLoader::set_skin swaps the Ref.
	godot::LocalVector<ResolvedBind> resolved_binds;
	uint64_t resolved_skeleton_version = 0;

	// Index into SkeletonLoader — shared across every mesh bound to the same
	// skeleton. UINT32_MAX means "no skeleton". SkeletonLoader owns the bone-pose
	// snapshot captured before Skeleton3D restores pre-modifier state;
	// upload_bone_transforms reads it via SkeletonLoader::get_bone_pose_snapshot
	// instead of calling get_bone_global_pose() directly, to pick up modifier-applied poses.
	uint32_t skeleton_idx = UINT32_MAX;
};

} // namespace gdrk
