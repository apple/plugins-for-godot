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

//  mesh_encoder.mm
//  GodotRealityKit

#include "mesh_loader.h"
#include "skeleton_loader.h"
#include "utility.h"

using namespace gdrk;

// ---------------------------------------------------------------------------
// Shared helpers

uint8_t gdrk::compute_decompressed_flags(uint8_t orig) {
	return orig & ~GodotRealityKit::VertexBufferFlags::getHasCompressedAttributes().getRawValue();
}

// ---------------------------------------------------------------------------

namespace {

constexpr uint32_t VARIANT_HAS_NORMAL = 1u << 0;
constexpr uint32_t VARIANT_HAS_TANGENT = 1u << 1;
constexpr uint32_t VARIANT_HAS_SKINNING = 1u << 2;
constexpr uint32_t VARIANT_NORMALIZED_BLEND_SHAPES = 1u << 3;
constexpr uint32_t VARIANT_IS_COMPRESSED = 1u << 4;

uint32_t skeletal_deform_variant(bool has_normal, bool has_tangent, bool has_skinning, bool normalized_blend_shapes, bool is_compressed) {
	return (has_normal ? VARIANT_HAS_NORMAL : 0u) |
			(has_tangent ? VARIANT_HAS_TANGENT : 0u) |
			(has_skinning ? VARIANT_HAS_SKINNING : 0u) |
			(normalized_blend_shapes ? VARIANT_NORMALIZED_BLEND_SHAPES : 0u) |
			(is_compressed ? VARIANT_IS_COMPRESSED : 0u);
}

id<MTLBuffer> make_staging_buffer(const godot::PackedByteArray &p_data) {
	if (p_data.is_empty()) {
		return nil;
	}
	return [get_metal_device() newBufferWithBytes:p_data.ptr()
										   length:p_data.size()
										  options:MTLResourceStorageModeShared];
}

_FORCE_INLINE_ uint32_t winding_swap(uint32_t gid) {
	const uint32_t mod = gid % 3;
	if (mod == 0) {
		return gid;
	} else if (mod == 1) {
		return gid + 1;
	} else {
		return gid - 1;
	}
}

template <typename IndexT>
void fill_index_buffer(void *p_dst, const void *p_src, uint32_t p_index_count) {
	IndexT *dst = static_cast<IndexT *>(p_dst);
	if (p_src) {
		const IndexT *src = static_cast<const IndexT *>(p_src);
		for (uint32_t i = 0; i < p_index_count; i++) {
			dst[i] = src[winding_swap(i)];
		}
	} else {
		for (uint32_t i = 0; i < p_index_count; i++) {
			dst[i] = static_cast<IndexT>(winding_swap(i));
		}
	}
}

// Compacted writes always emit uint32 indices (the LowLevelMesh is created
// with isIndex16=false). When the source surface stored 16-bit indices,
// upcast inline. `p_start_index` is added to every index value to translate
// from per-surface vertex space into the shared compacted vertex buffer.
template <typename SrcIndexT>
void fill_index_buffer_compacted(uint32_t *p_dst, const void *p_src, uint32_t p_index_count, uint32_t p_start_index) {
	if (p_src) {
		const SrcIndexT *src = static_cast<const SrcIndexT *>(p_src);
		for (uint32_t i = 0; i < p_index_count; i++) {
			p_dst[i] = uint32_t(src[winding_swap(i)]) + p_start_index;
		}
	} else {
		for (uint32_t i = 0; i < p_index_count; i++) {
			p_dst[i] = winding_swap(i) + p_start_index;
		}
	}
}

void resolve_binds(Mesh &p_mesh, godot::Skeleton3D *p_skeleton, int32_t p_bind_count, int32_t p_bone_count) {
	p_mesh.resolved_binds.resize(p_bind_count);
	for (int32_t i = 0; i < p_bind_count; i++) {
		int32_t bone = p_mesh.skin->get_bind_bone(i);
		if (bone < 0 || bone >= p_bone_count) {
			bone = p_skeleton->find_bone(godot::String(p_mesh.skin->get_bind_name(i)));
		}
		p_mesh.resolved_binds[i] = Mesh::ResolvedBind{ bone, p_mesh.skin->get_bind_pose(i) };
	}
}

void upload_bone_transforms(Mesh &p_mesh, SkeletonLoader *p_skeletons) {
	godot::Object *obj = godot::ObjectDB::get_instance(p_mesh.skeleton_id);
	godot::Skeleton3D *skeleton = godot::Object::cast_to<godot::Skeleton3D>(obj);
	ERR_FAIL_NULL(skeleton);

	const int32_t bone_count = skeleton->get_bone_count();
	if (bone_count <= 0) {
		p_mesh.bone_transforms_mtl = nil;
		return;
	}

	// Use the snapshot if available (populated by SkeletonLoader before Skeleton3D
	// restores pre-modifier state). Fall back to get_bone_global_pose on the first
	// frame before any signal has fired.
	const godot::LocalVector<godot::Transform3D> &snapshot = p_skeletons->get_bone_pose_snapshot(p_mesh.skeleton_idx);
	const bool use_snapshot = int32_t(snapshot.size()) == bone_count;

	const bool has_skin = p_mesh.skin.is_valid() && p_mesh.skin->get_bind_count() > 0;
	const int32_t out_count = has_skin ? p_mesh.skin->get_bind_count() : bone_count;

	if (has_skin) {
		const uint64_t skeleton_version = skeleton->get_version();
		if (int32_t(p_mesh.resolved_binds.size()) != out_count || p_mesh.resolved_skeleton_version != skeleton_version) {
			resolve_binds(p_mesh, skeleton, out_count, bone_count);
			p_mesh.resolved_skeleton_version = skeleton_version;
		}
	}

	const NSUInteger byte_length = uint32_t(out_count) * 12 * sizeof(float);
	if (p_mesh.bone_transforms_mtl == nil || p_mesh.bone_transforms_mtl.length != byte_length) {
		p_mesh.bone_transforms_mtl = [get_metal_device() newBufferWithLength:byte_length options:MTLResourceStorageModeShared];
	}

	float *p = static_cast<float *>(p_mesh.bone_transforms_mtl.contents);
	for (int32_t i = 0; i < out_count; i++) {
		static godot::Transform3D t;
		if (has_skin) {
			const Mesh::ResolvedBind &bind = p_mesh.resolved_binds[i];
			t = bind.bone >= 0
					? (use_snapshot ? snapshot[bind.bone] : skeleton->get_bone_global_pose(bind.bone)) * bind.bind_inverse
					: bind.bind_inverse;
		} else {
			t = use_snapshot ? snapshot[i] : skeleton->get_bone_global_pose(i);
		}
		p[0] = t.basis.rows[0].x;
		p[1] = t.basis.rows[0].y;
		p[2] = t.basis.rows[0].z;
		p[3] = t.origin.x;
		p[4] = t.basis.rows[1].x;
		p[5] = t.basis.rows[1].y;
		p[6] = t.basis.rows[1].z;
		p[7] = t.origin.y;
		p[8] = t.basis.rows[2].x;
		p[9] = t.basis.rows[2].y;
		p[10] = t.basis.rows[2].z;
		p[11] = t.origin.z;
		p += 12;
	}
}

godot::StringName &vertex_data_key() {
	static godot::StringName k("vertex_data");
	return k;
}
godot::StringName &attribute_data_key() {
	static godot::StringName k("attribute_data");
	return k;
}

} //namespace

// Resolves the mesh-wide deform state and uploads bone transforms and blend shape
// weights. Called once per mesh from encode_positions.
static DeformState prepare_deform(Mesh &p_mesh, SkeletonLoader *p_skeletons) {
	DeformState state;
	state.has_skinning = p_mesh.skeleton_id != 0;
	if (state.has_skinning) {
		for (const Mesh::Surface &s : p_mesh.surfaces) {
			if (s.skin_mtl != nil) {
				state.run_deform = true;
				break;
			}
		}
	}
	if (!state.run_deform) {
		for (float w : p_mesh.blend_shape_weights) {
			if (w != 0.0f) {
				state.run_deform = true;
				break;
			}
		}
	}
	if (state.run_deform) {
		if (state.has_skinning) {
			upload_bone_transforms(p_mesh, p_skeletons);
		}
		if (!p_mesh.blend_shape_weights.is_empty()) {
			const NSUInteger byte_length = p_mesh.blend_shape_weights.size() * sizeof(float);
			if (p_mesh.blend_shape_weights_mtl == nil || p_mesh.blend_shape_weights_mtl.length != byte_length) {
				p_mesh.blend_shape_weights_mtl = [get_metal_device() newBufferWithLength:byte_length options:MTLResourceStorageModeShared];
			}
			memcpy(p_mesh.blend_shape_weights_mtl.contents, p_mesh.blend_shape_weights.ptr(), byte_length);
		}
	}
	return state;
}

// ---------------------------------------------------------------------------
// MeshEncoder public API

void MeshEncoder::initialize() {
	NSError *error = nil;
	id<MTLDevice> device = gdrk::get_metal_device();
	NSBundle *bundle = get_gdrk_bundle();
	id<MTLLibrary> library = [device newDefaultLibraryWithBundle:bundle error:&error];

	for (uint32_t variant = 0; variant < SKELETAL_DEFORM_VARIANT_COUNT; variant++) {
		bool has_normal = (variant & VARIANT_HAS_NORMAL) != 0;
		bool has_tangent = (variant & VARIANT_HAS_TANGENT) != 0;
		bool has_skinning = (variant & VARIANT_HAS_SKINNING) != 0;
		bool normalized_blend_shapes = (variant & VARIANT_NORMALIZED_BLEND_SHAPES) != 0;
		bool is_compressed_v = (variant & VARIANT_IS_COMPRESSED) != 0;

		MTLFunctionConstantValues *constants = [[MTLFunctionConstantValues alloc] init];
		[constants setConstantValue:&has_normal type:MTLDataTypeBool atIndex:0];
		[constants setConstantValue:&has_tangent type:MTLDataTypeBool atIndex:1];
		[constants setConstantValue:&has_skinning type:MTLDataTypeBool atIndex:2];
		[constants setConstantValue:&normalized_blend_shapes type:MTLDataTypeBool atIndex:3];
		[constants setConstantValue:&is_compressed_v type:MTLDataTypeBool atIndex:4];

		id<MTLFunction> fn = [library newFunctionWithName:@"skeletalDeform" constantValues:constants error:&error];
		ERR_CONTINUE_MSG(fn == nil, "Failed to create skeletalDeform function");
		_skeletal_deform_psos[variant] = [device newComputePipelineStateWithFunction:fn error:&error];
		ERR_CONTINUE_MSG(_skeletal_deform_psos[variant] == nil, "Failed to create skeletalDeform pipeline state");
	}

	static const uint8_t zeros[16] = {};
	_placeholder_buffer = [device newBufferWithBytes:zeros length:sizeof(zeros) options:MTLResourceStorageModeShared];

	_vertex_decompress_pso = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"decompressVertices"] error:&error];
	ERR_FAIL_COND_MSG(_vertex_decompress_pso == nil, "Failed to create decompressVertices pipeline state");
	_attribute_decompress_pso = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"decompressAttributes"] error:&error];
	ERR_FAIL_COND_MSG(_attribute_decompress_pso == nil, "Failed to create decompressAttributes pipeline state");
}

void MeshEncoder::start(id<MTLCommandBuffer> p_command_buffer, SkeletonLoader *p_skeletons) {
	_command_buffer = p_command_buffer;
	_skeletons = p_skeletons;
	_deform_ops.clear();
	_decompress_ops.clear();
	_blit_ops.clear();
}

void MeshEncoder::prepare(Mesh &p_mesh) {
	static godot::StringName index_data_key_str("index_data");
	static godot::StringName skin_data_key_str("skin_data");
	static godot::StringName blend_shape_data_key_str("blend_shape_data");

	if (p_mesh.compacted_resource.isSome()) {
		auto llm = p_mesh.compacted_resource.lowLevelMesh();
		ERR_FAIL_COND(llm.isNone());

		id<MTLBuffer> dst_index = llm.get().replaceIndices(_command_buffer);
		uint32_t *dst32 = static_cast<uint32_t *>(dst_index.contents);
		uint32_t accumulated_vertex_count = 0;
		uint32_t accumulated_index_count = 0;
		for (uint32_t i = 0; i < p_mesh.surfaces.size(); i++) {
			const Mesh::SurfaceInfo &info = p_mesh.surface_infos[i];
			Mesh::Surface &surface = p_mesh.surfaces[i];
			const bool src_is_index_16 = info.vertex_count <= 65536 && info.vertex_count > 0;
			const void *src = surface.surface_data.has(index_data_key_str)
					? ((const godot::PackedByteArray &)surface.surface_data[index_data_key_str]).ptr()
					: nullptr;
			uint32_t *dst_for_surface = dst32 + accumulated_index_count;
			if (src_is_index_16) {
				fill_index_buffer_compacted<uint16_t>(dst_for_surface, src, info.index_count, accumulated_vertex_count);
			} else {
				fill_index_buffer_compacted<uint32_t>(dst_for_surface, src, info.index_count, accumulated_vertex_count);
			}
			accumulated_vertex_count += info.vertex_count;
			accumulated_index_count += info.index_count;
		}
		// Compaction is only enabled for static meshes — no deform staging buffers needed.
		return;
	}

	for (uint32_t i = 0; i < p_mesh.surfaces.size(); i++) {
		Mesh::Surface &surface = p_mesh.surfaces[i];
		const Mesh::SurfaceInfo &info = p_mesh.surface_infos[i];

		auto llm = surface.resource.lowLevelMesh();
		if (llm.isSome()) {
			const bool is_index_16 = info.vertex_count <= 65536 && info.vertex_count > 0;
			id<MTLBuffer> dst_index = llm.get().replaceIndices(_command_buffer);
			const void *src = surface.surface_data.has(index_data_key_str)
					? ((const godot::PackedByteArray &)surface.surface_data[index_data_key_str]).ptr()
					: nullptr;
			if (is_index_16) {
				fill_index_buffer<uint16_t>(dst_index.contents, src, info.index_count);
			} else {
				fill_index_buffer<uint32_t>(dst_index.contents, src, info.index_count);
			}
		}

		if (surface.encoding_mode & ENCODING_MODE_FLAG_DEFORM) {
			surface.base_vertex_mtl = make_staging_buffer(surface.surface_data[vertex_data_key()]);
			surface.skin_mtl = make_staging_buffer(surface.surface_data.get(skin_data_key_str, godot::PackedByteArray()));
			surface.blend_shape_mtl = make_staging_buffer(surface.surface_data.get(blend_shape_data_key_str, godot::PackedByteArray()));
		}
	}
}

void MeshEncoder::encode_positions(Mesh &p_mesh) {
	if (p_mesh.compacted_resource.isSome()) {
		auto llm = p_mesh.compacted_resource.lowLevelMesh();
		ERR_FAIL_COND(llm.isNone());

		const uint32_t surface_count = p_mesh.surfaces.size();
		const GDRKVertexBufferFormat &fmt = p_mesh.surface_infos[0].vertex_buffer_format;
		const uint32_t vertex_stride = fmt.vertex_stride;
		const uint32_t normal_tangent_stride = fmt.normal_tangent_stride;

		uint32_t total_vertex_count = 0;
		for (uint32_t s = 0; s < surface_count; s++) {
			total_vertex_count += p_mesh.surface_infos[s].vertex_count;
		}
		const uint32_t total_position_size = total_vertex_count * vertex_stride;

		id<MTLBuffer> dst_vertex = llm.get().replace(_command_buffer);

		uint32_t accumulated_vertex_count = 0;
		for (uint32_t i = 0; i < surface_count; i++) {
			const Mesh::SurfaceInfo &info = p_mesh.surface_infos[i];
			Mesh::Surface &surface = p_mesh.surfaces[i];

			const godot::PackedByteArray vertex_data = surface.surface_data.get(vertex_data_key(), {});
			if (!vertex_data.is_empty()) {
				id<MTLBuffer> vsrc = make_staging_buffer(vertex_data);

				const uint32_t position_size = info.vertex_count * vertex_stride;
				const uint32_t dst_position_offset = accumulated_vertex_count * vertex_stride;
				_blit_ops.push_back({ vsrc, dst_vertex, position_size, 0, dst_position_offset });

				if (normal_tangent_stride > 0) {
					const uint32_t src_nt_offset = info.vertex_count * vertex_stride;
					const uint32_t nt_size = info.vertex_count * normal_tangent_stride;
					const uint32_t dst_nt_offset = total_position_size + accumulated_vertex_count * normal_tangent_stride;
					_blit_ops.push_back({ vsrc, dst_vertex, nt_size, src_nt_offset, dst_nt_offset });
				}
			}

			accumulated_vertex_count += info.vertex_count;
		}
		return;
	}

	const DeformState deform = prepare_deform(p_mesh, _skeletons);

	for (uint32_t i = 0; i < p_mesh.surfaces.size(); i++) {
		const uint8_t position_variant = p_mesh.surfaces[i].encoding_mode & (ENCODING_MODE_FLAG_DEFORM | ENCODING_MODE_FLAG_COMPRESSED);
		(this->*position_encode_table[position_variant])(p_mesh, i, deform);
	}
}

void MeshEncoder::encode_attributes(Mesh &p_mesh) {
	if (p_mesh.compacted_resource.isSome()) {
		auto llm = p_mesh.compacted_resource.lowLevelMesh();
		ERR_FAIL_COND(llm.isNone());

		const bool has_attributes = (p_mesh.surface_infos[0].vertex_buffer_flags &
											(GodotRealityKit::VertexBufferFlags::getHasColor().getRawValue() |
													GodotRealityKit::VertexBufferFlags::getHasUV1().getRawValue() |
													GodotRealityKit::VertexBufferFlags::getHasUV2().getRawValue())) != 0;
		if (!has_attributes) {
			return;
		}

		const uint32_t attribute_stride = p_mesh.surface_infos[0].vertex_buffer_format.attribute_stride;
		id<MTLBuffer> dst_attr = llm.get().replaceAttributes(_command_buffer);
		ERR_FAIL_COND(dst_attr == nil);

		uint32_t accumulated_vertex_count = 0;
		for (uint32_t i = 0; i < p_mesh.surfaces.size(); i++) {
			const Mesh::SurfaceInfo &info = p_mesh.surface_infos[i];
			Mesh::Surface &surface = p_mesh.surfaces[i];

			const godot::PackedByteArray attribute_data = surface.surface_data.get(attribute_data_key(), {});
			if (!attribute_data.is_empty()) {
				id<MTLBuffer> asrc = make_staging_buffer(attribute_data);
				const uint32_t attr_size = info.vertex_count * attribute_stride;
				const uint32_t dst_attr_offset = accumulated_vertex_count * attribute_stride;
				_blit_ops.push_back({ asrc, dst_attr, attr_size, 0, dst_attr_offset });
			}

			accumulated_vertex_count += info.vertex_count;
		}
		return;
	}

	for (uint32_t i = 0; i < p_mesh.surfaces.size(); i++) {
		if (p_mesh.surfaces[i].encoding_mode & ENCODING_MODE_FLAG_WITH_UV) {
			_encode_attributes_surface(p_mesh, i);
		}
	}
}

void MeshEncoder::commit() {
	if (!_blit_ops.is_empty()) {
		id<MTLBlitCommandEncoder> blit_encoder = [_command_buffer blitCommandEncoder];
		for (const BlitOp &op : _blit_ops) {
			[blit_encoder copyFromBuffer:op.src sourceOffset:op.src_offset toBuffer:op.dst destinationOffset:op.dst_offset size:op.size];
		}
		[blit_encoder endEncoding];
	}

	if (!_deform_ops.is_empty() || !_decompress_ops.is_empty()) {
		id<MTLComputeCommandEncoder> compute_encoder = [_command_buffer computeCommandEncoder];

		for (const DeformOp &op : _deform_ops) {
			id<MTLComputePipelineState> pso = _skeletal_deform_psos[op.variant];
			[compute_encoder setComputePipelineState:pso];
			[compute_encoder setBuffer:op.base_vertex_mtl offset:0 atIndex:0];
			[compute_encoder setBuffer:op.dst offset:0 atIndex:1];
			[compute_encoder setBuffer:(op.skin_mtl ?: _placeholder_buffer) offset:0 atIndex:2];
			[compute_encoder setBuffer:(op.bone_transforms_mtl ?: _placeholder_buffer) offset:0 atIndex:3];
			[compute_encoder setBytes:&op.params length:sizeof(op.params) atIndex:4];
			[compute_encoder setBuffer:(op.blend_shape_mtl ?: _placeholder_buffer) offset:0 atIndex:5];
			[compute_encoder setBuffer:(op.blend_shape_weights_mtl ?: _placeholder_buffer) offset:0 atIndex:6];
			MTLSize grid = MTLSizeMake(op.params.vertex_count, 1, 1);
			MTLSize tg = MTLSizeMake(pso.maxTotalThreadsPerThreadgroup, 1, 1);
			[compute_encoder dispatchThreads:grid threadsPerThreadgroup:tg];
		}

		for (const DecompressOp &op : _decompress_ops) {
			if (op.kind == DecompressOp::Vertex) {
				struct {
					float aabb_min[3];
					float aabb_size[3];
					uint32_t src_vertex_stride, src_nt_base, src_nt_stride, dst_nt_base, has_tangents;
				} params = {
					.aabb_min = { op.aabb_min[0], op.aabb_min[1], op.aabb_min[2] },
					.aabb_size = { op.aabb_size[0], op.aabb_size[1], op.aabb_size[2] },
					.src_vertex_stride = op.src_vertex_stride,
					.src_nt_base = op.src_nt_base,
					.src_nt_stride = op.src_nt_stride,
					.dst_nt_base = op.dst_nt_base,
					.has_tangents = op.has_tangents,
				};
				[compute_encoder setComputePipelineState:_vertex_decompress_pso];
				[compute_encoder setBuffer:op.src offset:0 atIndex:0];
				[compute_encoder setBuffer:op.dst offset:0 atIndex:1];
				[compute_encoder setBytes:&params length:sizeof(params) atIndex:2];
				MTLSize grid = MTLSizeMake(op.vertex_count, 1, 1);
				[compute_encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(_vertex_decompress_pso.maxTotalThreadsPerThreadgroup, 1, 1)];
			} else {
				struct {
					uint32_t src_attr_stride, src_color_offset, src_uv1_offset, src_uv2_offset, dst_attr_stride, dst_color_offset, dst_uv1_offset, dst_uv2_offset, has_color, has_uv1, has_uv2, pad;
				} params = {
					.src_attr_stride = op.src_attr_stride,
					.src_color_offset = op.src_color_offset,
					.src_uv1_offset = op.src_uv1_offset,
					.src_uv2_offset = op.src_uv2_offset,
					.dst_attr_stride = op.dst_attr_stride,
					.dst_color_offset = op.dst_color_offset,
					.dst_uv1_offset = op.dst_uv1_offset,
					.dst_uv2_offset = op.dst_uv2_offset,
					.has_color = op.has_color,
					.has_uv1 = op.has_uv1,
					.has_uv2 = op.has_uv2,
					.pad = 0,
				};
				[compute_encoder setComputePipelineState:_attribute_decompress_pso];
				[compute_encoder setBuffer:op.src offset:0 atIndex:0];
				[compute_encoder setBuffer:op.dst offset:0 atIndex:1];
				[compute_encoder setBytes:&params length:sizeof(params) atIndex:2];
				MTLSize grid = MTLSizeMake(op.vertex_count, 1, 1);
				[compute_encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(_attribute_decompress_pso.maxTotalThreadsPerThreadgroup, 1, 1)];
			}
		}

		[compute_encoder endEncoding];
	}

	_command_buffer = nil;
}

// ---------------------------------------------------------------------------
// Helpers for building self-contained ops.

namespace {

DeformOp make_deform_op(
		const Mesh &p_mesh,
		const Mesh::Surface &surface,
		const Mesh::SurfaceInfo &info,
		id<MTLBuffer> p_dst,
		id<MTLBuffer> p_bone_transforms,
		id<MTLBuffer> p_blend_weights,
		bool has_skinning,
		bool is_compressed) {
	const bool has_normal = (info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasNormals().getRawValue()) != 0;
	const bool has_tangent = (info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasTangents().getRawValue()) != 0;
	DeformOp op;
	op.base_vertex_mtl = surface.base_vertex_mtl;
	op.skin_mtl = surface.skin_mtl;
	op.blend_shape_mtl = surface.blend_shape_mtl;
	op.bone_transforms_mtl = p_bone_transforms;
	op.blend_shape_weights_mtl = p_blend_weights;
	op.dst = p_dst;
	op.params = SkinningParams{
		.vertex_count = info.vertex_count,
		.vertex_stride = info.vertex_buffer_format.vertex_stride,
		.normal_tangent_offset = info.vertex_buffer_format.normal_offset,
		.normal_tangent_stride = info.vertex_buffer_format.normal_tangent_stride,
		.skin_stride = info.vertex_buffer_format.skin_stride,
		.skin_weight_offset = info.vertex_buffer_format.skin_weight_offset,
		.blend_shape_count = is_compressed ? 0u : p_mesh.blend_shape_count,
		.aabb_min = { info.bounds.position.x, info.bounds.position.y, info.bounds.position.z },
		.aabb_size = { info.bounds.size.x, info.bounds.size.y, info.bounds.size.z },
	};
	op.variant = skeletal_deform_variant(has_normal, has_tangent,
			has_skinning && surface.skin_mtl != nil, p_mesh.normalized_blend_shapes, is_compressed);
	return op;
}

DecompressOp make_vertex_decompress_op(id<MTLBuffer> p_src, id<MTLBuffer> p_dst, const Mesh::SurfaceInfo &info) {
	const GDRKVertexBufferFormat &dec = info.decompressed_vertex_buffer_format;
	DecompressOp op;
	op.kind = DecompressOp::Vertex;
	op.src = p_src;
	op.dst = p_dst;
	op.vertex_count = info.vertex_count;
	op.src_vertex_stride = info.vertex_buffer_format.vertex_stride;
	op.src_nt_base = info.vertex_count * info.vertex_buffer_format.vertex_stride;
	op.src_nt_stride = info.vertex_buffer_format.normal_tangent_stride;
	op.dst_nt_base = dec.normal_offset;
	op.aabb_min[0] = info.bounds.position.x;
	op.aabb_min[1] = info.bounds.position.y;
	op.aabb_min[2] = info.bounds.position.z;
	op.aabb_size[0] = info.bounds.size.x;
	op.aabb_size[1] = info.bounds.size.y;
	op.aabb_size[2] = info.bounds.size.z;
	op.has_tangents = uint32_t(info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasTangents().getRawValue());
	return op;
}

DecompressOp make_attribute_decompress_op(id<MTLBuffer> p_src, id<MTLBuffer> p_dst, const Mesh::SurfaceInfo &info) {
	const GDRKVertexBufferFormat &dec = info.decompressed_vertex_buffer_format;
	DecompressOp op;
	op.kind = DecompressOp::Attribute;
	op.src = p_src;
	op.dst = p_dst;
	op.vertex_count = info.vertex_count;
	op.src_attr_stride = info.vertex_buffer_format.attribute_stride;
	op.src_color_offset = info.vertex_buffer_format.color_offset;
	op.src_uv1_offset = info.vertex_buffer_format.uv1_offset;
	op.src_uv2_offset = info.vertex_buffer_format.uv2_offset;
	op.dst_attr_stride = dec.attribute_stride;
	op.dst_color_offset = dec.color_offset;
	op.dst_uv1_offset = dec.uv1_offset;
	op.dst_uv2_offset = dec.uv2_offset;
	op.has_color = uint32_t(info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasColor().getRawValue());
	op.has_uv1 = uint32_t(info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasUV1().getRawValue());
	op.has_uv2 = uint32_t(info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasUV2().getRawValue());
	op.pad = 0;
	return op;
}

} //namespace

// ---------------------------------------------------------------------------
// Position dispatch table — indexed by (encoding_mode & (DEFORM|COMPRESSED)).
// WITH_UV doesn't affect position encoding, so it's masked off before indexing.

const MeshEncoder::EncodeFn MeshEncoder::position_encode_table[4] = {
	&MeshEncoder::_encode_static_pos, // 0b00
	&MeshEncoder::_encode_deform_pos, // 0b01
	&MeshEncoder::_encode_static_compressed_pos, // 0b10
	&MeshEncoder::_encode_deform_compressed_pos, // 0b11
};

// ---------------------------------------------------------------------------
// Position encoding — one method per (deform x compressed) combination.

void MeshEncoder::_encode_static_pos(Mesh &p_mesh, uint32_t surface_idx, const DeformState &) {
	Mesh::Surface &surface = p_mesh.surfaces[surface_idx];
	auto llm = surface.resource.lowLevelMesh();
	ERR_FAIL_COND(llm.isNone());

	const godot::PackedByteArray vertex_data = surface.surface_data.get(vertex_data_key(), {});
	if (vertex_data.is_empty()) {
		return;
	}
	id<MTLBuffer> staging = make_staging_buffer(vertex_data);
	id<MTLBuffer> dst = llm.get().replace(_command_buffer);
	_blit_ops.push_back({ staging, dst, staging.length });
}

void MeshEncoder::_encode_static_compressed_pos(Mesh &p_mesh, uint32_t surface_idx, const DeformState &) {
	Mesh::Surface &surface = p_mesh.surfaces[surface_idx];
	const Mesh::SurfaceInfo &info = p_mesh.surface_infos[surface_idx];
	auto llm = surface.resource.lowLevelMesh();
	ERR_FAIL_COND(llm.isNone());

	const godot::PackedByteArray vertex_data = surface.surface_data.get(vertex_data_key(), {});
	id<MTLBuffer> src = make_staging_buffer(vertex_data);
	if (src == nil) {
		return;
	}
	id<MTLBuffer> dst = llm.get().replace(_command_buffer);
	_decompress_ops.push_back(make_vertex_decompress_op(src, dst, info));
}

void MeshEncoder::_encode_deform_pos(Mesh &p_mesh, uint32_t surface_idx, const DeformState &p_deform) {
	Mesh::Surface &surface = p_mesh.surfaces[surface_idx];
	const Mesh::SurfaceInfo &info = p_mesh.surface_infos[surface_idx];
	auto llm = surface.resource.lowLevelMesh();
	ERR_FAIL_COND(llm.isNone());

	id<MTLBuffer> dst = llm.get().replace(_command_buffer);
	if (p_deform.run_deform) {
		_deform_ops.push_back(make_deform_op(p_mesh, surface, info, dst, p_mesh.bone_transforms_mtl, p_mesh.blend_shape_weights_mtl, p_deform.has_skinning, false));
	} else {
		_blit_ops.push_back({ surface.base_vertex_mtl, dst, surface.base_vertex_mtl.length });
	}
}

void MeshEncoder::_encode_deform_compressed_pos(Mesh &p_mesh, uint32_t surface_idx, const DeformState &p_deform) {
	Mesh::Surface &surface = p_mesh.surfaces[surface_idx];
	const Mesh::SurfaceInfo &info = p_mesh.surface_infos[surface_idx];
	auto llm = surface.resource.lowLevelMesh();
	ERR_FAIL_COND(llm.isNone());

	id<MTLBuffer> dst = llm.get().replace(_command_buffer);
	if (p_deform.run_deform) {
		_deform_ops.push_back(make_deform_op(p_mesh, surface, info, dst, p_mesh.bone_transforms_mtl, p_mesh.blend_shape_weights_mtl, p_deform.has_skinning, true));
	} else {
		_blit_ops.push_back({ surface.base_vertex_mtl, dst, surface.base_vertex_mtl.length });
	}
}

// ---------------------------------------------------------------------------
// Attribute encoding — only cares about compressed-or-not; deform is
// irrelevant since skinning/blend shapes never touch color/UV data.

void MeshEncoder::_encode_attributes_surface(Mesh &p_mesh, uint32_t surface_idx) {
	Mesh::Surface &surface = p_mesh.surfaces[surface_idx];
	const Mesh::SurfaceInfo &info = p_mesh.surface_infos[surface_idx];
	auto llm = surface.resource.lowLevelMesh();
	ERR_FAIL_COND(llm.isNone());

	const godot::PackedByteArray attribute_data = surface.surface_data.get(attribute_data_key(), {});
	id<MTLBuffer> asrc = make_staging_buffer(attribute_data);
	id<MTLBuffer> dst_attr = llm.get().replaceAttributes(_command_buffer);
	ERR_FAIL_COND(asrc == nil || dst_attr == nil);

	if (surface.encoding_mode & ENCODING_MODE_FLAG_COMPRESSED) {
		_decompress_ops.push_back(make_attribute_decompress_op(asrc, dst_attr, info));
	} else {
		_blit_ops.push_back({ asrc, dst_attr, asrc.length });
	}
}
