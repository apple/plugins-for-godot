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
#include "Metal/skeletal-deform.h"
#include "types.h"

#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/aabb.hpp>

namespace gdrk {

// Forward declaration — defined in mesh_types.h (included after this header).
struct Mesh;
class SkeletonLoader;

// ---------------------------------------------------------------------------
// Helpers shared between mesh_loader.mm and mesh_encoder.mm.

_FORCE_INLINE_ bool surface_has_compressed_attributes(uint8_t flags) {
	return flags & GodotRealityKit::VertexBufferFlags::getHasCompressedAttributes().getRawValue();
}

uint8_t compute_decompressed_flags(uint8_t orig);

// ---------------------------------------------------------------------------
// Blit op.

struct BlitOp {
	id<MTLBuffer> src;
	id<MTLBuffer> dst;
	NSUInteger size;
	NSUInteger src_offset = 0;
	NSUInteger dst_offset = 0;
};

// ---------------------------------------------------------------------------
// Mesh-wide deform state. Resolved once per mesh, then shared by every surface.

struct DeformState {
	bool run_deform = false;
	bool has_skinning = false;
};

// ---------------------------------------------------------------------------
// Self-contained deform op.

struct DeformOp {
	id<MTLBuffer> base_vertex_mtl;
	id<MTLBuffer> skin_mtl;
	id<MTLBuffer> blend_shape_mtl;
	id<MTLBuffer> bone_transforms_mtl;
	id<MTLBuffer> blend_shape_weights_mtl;
	id<MTLBuffer> dst;
	SkinningParams params;
	uint32_t variant;
};

// ---------------------------------------------------------------------------
// Self-contained decompress op.

struct DecompressOp {
	enum Kind : uint8_t { Vertex,
		Attribute } kind;
	id<MTLBuffer> src;
	id<MTLBuffer> dst;

	// Vertex decompress params
	uint32_t vertex_count;
	uint32_t src_vertex_stride;
	uint32_t src_nt_base;
	uint32_t src_nt_stride;
	uint32_t dst_nt_base;
	float aabb_min[3];
	float aabb_size[3];
	uint32_t has_tangents;

	// Attribute decompress params
	uint32_t src_attr_stride;
	uint32_t src_color_offset;
	uint32_t src_uv1_offset;
	uint32_t src_uv2_offset;
	uint32_t dst_attr_stride;
	uint32_t dst_color_offset;
	uint32_t dst_uv1_offset;
	uint32_t dst_uv2_offset;
	uint32_t has_color;
	uint32_t has_uv1;
	uint32_t has_uv2;
	uint32_t pad;
};

// ---------------------------------------------------------------------------
// MeshEncoder

class MeshEncoder {
public:
	// Three independent bits fully describe a surface's encoding requirements.
	// All 8 combinations (0-7) are valid.
	enum EncodingMode : uint8_t {
		ENCODING_MODE_FLAG_DEFORM = 1 << 0, // surface uses skeletalDeform kernel
		ENCODING_MODE_FLAG_COMPRESSED = 1 << 1, // vertex data is in compressed format
		ENCODING_MODE_FLAG_WITH_UV = 1 << 2, // surface has attribute data (color and/or UVs)
	};

	void initialize();

	void start(id<MTLCommandBuffer> p_command_buffer, SkeletonLoader *p_skeletons);

	void prepare(Mesh &p_mesh);

	// Recomputes vertex positions/normals/tangents — cheap enough to run every
	// frame a mesh deforms (skinning, blend shapes).
	void encode_positions(Mesh &p_mesh);

	// Re-uploads color/UV attribute data — only needed when the underlying mesh
	// itself changed, since deformation never touches attributes.
	void encode_attributes(Mesh &p_mesh);

	void commit();

private:
	id<MTLCommandBuffer> _command_buffer = nil;
	SkeletonLoader *_skeletons = nullptr;

	godot::LocalVector<DeformOp> _deform_ops;
	godot::LocalVector<DecompressOp> _decompress_ops;
	godot::LocalVector<BlitOp> _blit_ops;

	static constexpr uint32_t SKELETAL_DEFORM_VARIANT_COUNT = 32; // 5 bits: normal, tangent, skinning, norm_bs, compressed
	id<MTLComputePipelineState> _skeletal_deform_psos[SKELETAL_DEFORM_VARIANT_COUNT] = {};
	id<MTLBuffer> _placeholder_buffer = nil;
	id<MTLComputePipelineState> _vertex_decompress_pso = nil;
	id<MTLComputePipelineState> _attribute_decompress_pso = nil;

	// Position encoding only depends on DEFORM/COMPRESSED — WITH_UV is irrelevant,
	// so the table is indexed by encoding_mode with that bit masked off.
	using EncodeFn = void (MeshEncoder::*)(Mesh &, uint32_t, const DeformState &);
	static const EncodeFn position_encode_table[4];

	void _encode_static_pos(Mesh &p_mesh, uint32_t surface_idx, const DeformState &);
	void _encode_deform_pos(Mesh &p_mesh, uint32_t surface_idx, const DeformState &p_deform);
	void _encode_static_compressed_pos(Mesh &p_mesh, uint32_t surface_idx, const DeformState &);
	void _encode_deform_compressed_pos(Mesh &p_mesh, uint32_t surface_idx, const DeformState &p_deform);

	void _encode_attributes_surface(Mesh &p_mesh, uint32_t surface_idx);
};

} // namespace gdrk
