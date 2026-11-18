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

#include "mesh_loader.h"
#include "bridge.h"
#include "signposts.h"
#include "skeleton_loader.h"
#include "utility.h"

#include <godot_cpp/templates/sort_array.hpp>

using namespace gdrk;

namespace {

// Each RS getter (get_format_vertex_stride, get_format_offset, etc.) independently calls
// mesh_surface_make_offsets_from_format, which loops over all ARRAY_MAX (13) slots to compute
// strides and offsets in one pass, then discards all but the one value the caller asked for.
// A single-pass equivalent isn't exposed through the GDExtension boundary, so filling a full
// GDRKVertexBufferFormat costs 10 redundant passes through that loop (9 get_format_offset calls
// + the stride calls). This is called twice per surface change (once for compressed, once for
// decompressed format) — acceptable since it only runs on the cold mesh-change path, never
// per-frame.
static GDRKVertexBufferFormat format_to_gdrk(godot::RenderingServer *rs, uint64_t format, uint32_t vertex_count) {
	const bool has_deform = (format & godot::RenderingServer::ARRAY_FORMAT_BONES) != 0 &&
			(format & godot::RenderingServer::ARRAY_FORMAT_WEIGHTS) != 0;
	const uint32_t skin_stride = has_deform
			? rs->mesh_surface_get_format_skin_stride(format, vertex_count) / uint32_t(sizeof(uint32_t))
			: 0u;
	return GDRKVertexBufferFormat{
		.vertex_stride = rs->mesh_surface_get_format_vertex_stride(format, vertex_count),
		.normal_tangent_stride = rs->mesh_surface_get_format_normal_tangent_stride(format, vertex_count),
		.attribute_stride = rs->mesh_surface_get_format_attribute_stride(format, vertex_count),
		.vertex_offset = rs->mesh_surface_get_format_offset(format, vertex_count, godot::RenderingServer::ARRAY_VERTEX),
		.normal_offset = rs->mesh_surface_get_format_offset(format, vertex_count, godot::RenderingServer::ARRAY_NORMAL),
		.tangent_offset = rs->mesh_surface_get_format_offset(format, vertex_count, godot::RenderingServer::ARRAY_TANGENT),
		.color_offset = rs->mesh_surface_get_format_offset(format, vertex_count, godot::RenderingServer::ARRAY_COLOR),
		.uv1_offset = rs->mesh_surface_get_format_offset(format, vertex_count, godot::RenderingServer::ARRAY_TEX_UV),
		.uv2_offset = rs->mesh_surface_get_format_offset(format, vertex_count, godot::RenderingServer::ARRAY_TEX_UV2),
		.skin_stride = skin_stride,
		.skin_weight_offset = skin_stride / 2,
	};
}

} //namespace

static uint8_t get_vertex_buffer_flags(uint64_t format, bool compressed_uvs) {
	using RS = godot::RenderingServer;

	WARN_COMPAT_COND((format & (uint64_t(RS::ARRAY_FLAG_FORMAT_VERSION_MASK) << RS::ARRAY_FLAG_FORMAT_VERSION_SHIFT)) !=
			RS::ARRAY_FLAG_FORMAT_CURRENT_VERSION);

	uint8_t flags = 0;
	if (format & godot::RenderingServer::ARRAY_FORMAT_NORMAL) {
		flags |= GodotRealityKit::VertexBufferFlags::getHasNormals().getRawValue();
	}

	if (format & godot::RenderingServer::ARRAY_FORMAT_TANGENT) {
		flags |= GodotRealityKit::VertexBufferFlags::getHasTangents().getRawValue();
	}

	if (format & godot::RenderingServer::ARRAY_FORMAT_COLOR) {
		flags |= GodotRealityKit::VertexBufferFlags::getHasColor().getRawValue();
	}

	if (format & godot::RenderingServer::ARRAY_FORMAT_TEX_UV) {
		flags |= GodotRealityKit::VertexBufferFlags::getHasUV1().getRawValue();
	}

	if (format & godot::RenderingServer::ARRAY_FORMAT_TEX_UV2) {
		flags |= GodotRealityKit::VertexBufferFlags::getHasUV2().getRawValue();
	}

	if (format & godot::RenderingServer::ARRAY_FLAG_COMPRESS_ATTRIBUTES) {
		flags |= GodotRealityKit::VertexBufferFlags::getHasCompressedAttributes().getRawValue();
	}

	if (compressed_uvs) {
		flags |= GodotRealityKit::VertexBufferFlags::getHasCompressedUVs().getRawValue();
	}

	return flags;
}

void MeshLoader::initialize(SkeletonLoader *p_skeletons) {
	mesh_encoder.initialize();
	skeletons = p_skeletons;
}

uint32_t MeshLoader::find_or_add(godot::RID p_mesh_rid,
		uint64_t p_instance_id,
		godot::Mesh *p_mesh,
		godot::Skeleton3D *p_skeleton) {
	const MeshKey key = MeshKey{
		.mesh_rid = p_mesh_rid,
		.instance_id = p_instance_id,
	};

	const auto found = mesh_to_idx.find(key);
	if (found) {
		return found->value;
	}

	const uint32_t idx = alloc_idx();

	const uint32_t mesh_rid_idx = p_mesh_rid.get_id() & 0xFFFFFFFF;
	if (mesh_rid_idx >= dirty_mesh_rid_idxs.size()) {
		dirty_mesh_rid_idxs.resize(mesh_rid_idx + 1);
	}

	if (p_mesh) {
		godot::Callable mesh_changed_callable =
				callable_mp(this, &MeshLoader::mesh_changed).bind(mesh_rid_idx);
		if (!p_mesh->is_connected("changed", mesh_changed_callable)) {
			p_mesh->connect("changed", mesh_changed_callable);
		}
	}

	uint64_t skeleton_id = 0;
	uint32_t skeleton_idx = UINT32_MAX;
	if (p_skeleton) {
		skeleton_id = p_skeleton->get_instance_id();
		skeleton_idx = skeletons->find_or_add(skeleton_id, p_skeleton);
		skeletons->reference(skeleton_idx);
	}

	meshes[idx] = Mesh{
		.mesh_rid = p_mesh_rid,
		.instance_id = p_instance_id,
	};

	mesh_rid_idxs[idx] = mesh_rid_idx;
	meshes[idx].skeleton_id = skeleton_id;
	meshes[idx].skeleton_idx = skeleton_idx;
	mesh_to_idx.insert(key, idx);
	surface_info_dirty_idxs.insert(idx);

	return idx;
}

uint32_t MeshLoader::get_mesh_index(godot::RID p_mesh_rid, uint64_t p_instance_id) const {
	const MeshKey key = MeshKey{
		.mesh_rid = p_mesh_rid,
		.instance_id = p_instance_id,
	};

	ERR_FAIL_COND_V(!mesh_to_idx.has(key), UINT32_MAX);
	const uint32_t idx = mesh_to_idx.get(key);
	return idx;
}

void MeshLoader::remove(uint32_t p_idx) {
	mesh_to_idx.erase(MeshKey{
			.mesh_rid = meshes[p_idx].mesh_rid,
			.instance_id = meshes[p_idx].instance_id,
	});

	const uint32_t skeleton_idx = meshes[p_idx].skeleton_idx;
	if (skeleton_idx != UINT32_MAX) {
		skeletons->unreference(skeleton_idx);
	}

	meshes[p_idx] = Mesh();
	mesh_rid_idxs[p_idx] = UINT32_MAX;
	meshes[p_idx].skeleton_id = 0;
	surface_info_dirty_idxs.remove(p_idx);
	free_idx(p_idx);
}

void MeshLoader::set_blend_shape_weights(uint32_t p_idx, Span<const float> p_weights) {
	Mesh &mesh = meshes[p_idx];
	mesh.blend_shape_weights = SmallLocalVector<float, 8>(p_weights);
	mesh_needs_reencoding.insert(p_idx);
}

void MeshLoader::set_skin(uint32_t p_idx, const godot::Ref<godot::Skin> &p_skin) {
	Mesh &mesh = meshes[p_idx];
	if (mesh.skin == p_skin) {
		return;
	}
	mesh.skin = p_skin;
	mesh.resolved_binds.clear();
	mesh_needs_reencoding.insert(p_idx);
}

void MeshLoader::prepare_frame_changes() {
	
	for_each_valid([&](uint32_t idx) {
		if (is_dirty(idx)) {
			surface_info_dirty_idxs.insert(idx);
			return;
		}

		const uint32_t mesh_rid_idx = mesh_rid_idxs[idx];
		if (dirty_mesh_rid_idxs.has(mesh_rid_idx)) {
			surface_info_dirty_idxs.insert(idx);
		}
	});

	godot::RenderingServer *rs = rendering_server();
	surface_info_dirty_idxs.for_each([&](uint32_t idx) {
		dirty_idxs.insert(idx);
		mark_changed_in_frame(idx);
		Mesh &mesh = meshes[idx];

		// Force reload of surfaces
		mesh.surfaces.reset();

		const uint32_t surface_count = mesh.mesh_rid.is_valid() ? rs->mesh_get_surface_count(mesh.mesh_rid) : 0;
		mesh.surface_infos.reserve(surface_count);
		mesh.surface_infos.reset();
		for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
			godot::Dictionary surface_data = rs->mesh_get_surface(mesh.mesh_rid, surface_idx);
			Mesh::SurfaceInfo surface_info = get_surface_info(surface_data, mesh.mesh_rid);
			mesh.surface_infos.push_back(surface_info);
		}
		godot::AABB new_bounds = compute_local_aabb(VECTOR_SPAN(mesh.surface_infos));
		const bool bounds_dirty = bounds_changed(new_bounds, mesh.instance_aabb, 0.1);
		if (bounds_dirty) {
			mesh.instance_aabb = new_bounds;
			mesh_needs_bounds_update.insert(idx);
		}
	});

	surface_info_dirty_idxs.clear();
}

bool MeshLoader::update(id<MTLCommandBuffer> p_command_buffer) {
	PROFILE_FUNC_SCOPE;

	mesh_encoder.start(p_command_buffer, skeletons);

	bool finished = for_each_dirty_throttled([&](uint32_t idx) {
		if (!is_used_in_frame(idx)) {
			return LocalBitVector::IterationResult::SKIPPED;
		}
		const godot::RID mesh_rid = meshes[idx].mesh_rid;

		godot::RenderingServer *rs = rendering_server();
		const SmallLocalVector<Mesh::SurfaceInfo, 8> &surface_infos = meshes[idx].surface_infos;
		const uint32_t surface_count = surface_infos.size();

		meshes[idx].blend_shape_count = mesh_rid.is_valid() ? uint32_t(rs->mesh_get_blend_shape_count(mesh_rid)) : 0u;
		meshes[idx].normalized_blend_shapes =
				rs->mesh_get_blend_shape_mode(mesh_rid) == godot::RenderingServer::BLEND_SHAPE_MODE_NORMALIZED;

		bool surfaces_need_new_resources = false;
		if (meshes[idx].surfaces.size() == surface_infos.size()) {
			for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
				if (surface_needs_new_resource(surface_infos[surface_idx], meshes[idx].surface_infos[surface_idx])) {
					surfaces_need_new_resources = true;
					break;
				}
			}
		} else {
			surfaces_need_new_resources = true;
		}

		// Compaction: pack compatible static surfaces into a single multi-part
		// LowLevelMesh. Requires identical vertex format / uv_scale across surfaces,
		// no compressed attributes (decompress kernel writes per-surface buffers),
		// and no per-instance deformation (skeleton or blend shapes — those go
		// through MeshEncoder's deform path which assumes one-buffer-per-surface).
		auto can_compact = [&]() -> bool {
			if (surface_count <= 1) {
				return false;
			}
			if (no_compact_idxs.has(idx)) {
				return false;
			}
			if (meshes[idx].skeleton_id != 0 || rs->mesh_get_blend_shape_count(mesh_rid) > 0) {
				return false;
			}
			const uint8_t compressed_attrs_flag = GodotRealityKit::VertexBufferFlags::getHasCompressedAttributes().getRawValue();
			if (surface_infos[0].vertex_buffer_flags & compressed_attrs_flag) {
				return false;
			}
			const uint8_t ref_flags = surface_infos[0].vertex_buffer_flags;
			const GDRKVertexBufferFormat &ref_fmt = surface_infos[0].vertex_buffer_format;
			const godot::Vector4 ref_uv_scale = surface_infos[0].uv_scale;
			for (uint32_t s = 1; s < surface_count; s++) {
				if (surface_infos[s].vertex_buffer_flags != ref_flags ||
						surface_infos[s].vertex_buffer_format.vertex_stride != ref_fmt.vertex_stride ||
						surface_infos[s].vertex_buffer_format.normal_tangent_stride != ref_fmt.normal_tangent_stride ||
						surface_infos[s].vertex_buffer_format.attribute_stride != ref_fmt.attribute_stride ||
						surface_infos[s].uv_scale != ref_uv_scale) {
					return false;
				}
			}
			return true;
		}();

		if (surfaces_need_new_resources) {
			meshes[idx].surfaces.reset();
			emplace_replace(&meshes[idx].compacted_resource, GodotRealityKit::MeshResource::init());

			if (can_compact) {
				uint32_t total_vertex_count = 0;
				uint32_t total_index_count = 0;
				godot::AABB merged_bounds;
				for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
					total_vertex_count += surface_infos[surface_idx].vertex_count;
					total_index_count += surface_infos[surface_idx].index_count;
					if (merged_bounds.has_volume()) {
						merged_bounds.merge_with(surface_infos[surface_idx].bounds);
					} else {
						merged_bounds = surface_infos[surface_idx].bounds;
					}
				}

				const uint32_t vertex_stride = surface_infos[0].vertex_buffer_format.vertex_stride;

				// In a non-compacted single-surface mesh, normals/tangents start at
				// `normal_offset` within each surface's buffer. In a compacted mesh,
				// all surfaces' positions come first (each surface's positions packed
				// at vertex_stride), then all surfaces' normal/tangent data — so the
				// shared normal_offset moves to total_vertex_count * vertex_stride.
				GDRKVertexBufferFormat compacted_format = surface_infos[0].vertex_buffer_format;
				const uint32_t relative_tangent_offset = compacted_format.tangent_offset - compacted_format.normal_offset;
				compacted_format.normal_offset = total_vertex_count * vertex_stride;
				compacted_format.tangent_offset = compacted_format.normal_offset + relative_tangent_offset;

				swift::Optional<GodotRealityKit::LowLevelMesh> low_level_mesh =
						GodotRealityKit::LowLevelMesh::init(total_vertex_count,
								total_index_count,
								GodotRealityKit::VertexBufferFlags::init(surface_infos[0].vertex_buffer_flags),
								compacted_format,
								false,
								surface_count);

				ERR_FAIL_COND_V_MSG(low_level_mesh.isNone(), LocalBitVector::IterationResult::SKIPPED, "Failed to create compacted low level mesh");

				swift::Array<swift::Int> index_counts = swift::Array<swift::Int>::init();
				for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
					index_counts.append(surface_infos[surface_idx].index_count);
				}
				low_level_mesh.get().setIndexCounts(index_counts, false);

				swift::Optional<GodotRealityKit::MeshResource> compacted_opt =
						GodotRealityKit::MeshResource::init(low_level_mesh.get(),
								to_vector3(merged_bounds.position),
								to_vector3(merged_bounds.position + merged_bounds.size),
								to_vector4(surface_infos[0].uv_scale));
				ERR_FAIL_COND_V(compacted_opt.isNone(), LocalBitVector::IterationResult::SKIPPED);
				emplace_replace(&meshes[idx].compacted_resource, compacted_opt.get());

				// Per-surface Surface entries are still needed so the encoder can
				// stash surface_data + encoding_mode per surface. Their `resource`
				// field is left default-initialized — the compacted path only ever
				// writes through `compacted_resource`.
				meshes[idx].surfaces.reserve(surface_count);
				for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
					meshes[idx].surfaces.push_back(Mesh::Surface{});
				}
			} else {
				meshes[idx].surfaces.reserve(surface_count);

				for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
					const Mesh::SurfaceInfo &info = surface_infos[surface_idx];
					const bool is_index_16 = info.vertex_count <= 65536 && info.vertex_count > 0;
					const bool is_compressed = surface_has_compressed_attributes(info.vertex_buffer_flags);
					const GDRKVertexBufferFormat llm_format = is_compressed
							? info.decompressed_vertex_buffer_format
							: info.vertex_buffer_format;
					const uint8_t llm_flags = is_compressed
							? compute_decompressed_flags(info.vertex_buffer_flags)
							: info.vertex_buffer_flags;
					swift::Optional<GodotRealityKit::LowLevelMesh> low_level_mesh =
							GodotRealityKit::LowLevelMesh::init(info.vertex_count,
									info.index_count,
									GodotRealityKit::VertexBufferFlags::init(llm_flags),
									llm_format,
									is_index_16,
									1);

					ERR_FAIL_COND_V_MSG(low_level_mesh.isNone(), LocalBitVector::IterationResult::SKIPPED, "Failed to create low level mesh");

					low_level_mesh.get().setIndexCount(info.index_count);

					swift::Optional<GodotRealityKit::MeshResource> mesh_resource =
							GodotRealityKit::MeshResource::init(low_level_mesh.get(), to_vector3(info.bounds.position),
									to_vector3(info.bounds.position + info.bounds.size), to_vector4(info.uv_scale));
					ERR_FAIL_COND_V(mesh_resource.isNone(), LocalBitVector::IterationResult::SKIPPED);

					meshes[idx].surfaces.push_back(Mesh::Surface{ .resource = mesh_resource.get() });
				}
			}
			mesh_needs_bounds_update.insert(idx);
		} else {
			mesh_needs_reencoding.remove(idx);
		}

		// Store raw surface data and set encoding mode — encoder handles the rest.
		for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
			const Mesh::SurfaceInfo &info = surface_infos[surface_idx];
			Mesh::Surface &surface = meshes[idx].surfaces[surface_idx];
			const bool is_compressed = surface_has_compressed_attributes(info.vertex_buffer_flags);

			surface.surface_data = info.data;
			surface.base_vertex_mtl = nil;
			surface.skin_mtl = nil;
			surface.blend_shape_mtl = nil;

			if (!meshes[idx].compacted_resource.isSome()) {
				surface.resource.setBounds(to_vector3(info.bounds.position), to_vector3(info.bounds.position + info.bounds.size));
				surface.resource.setUVScale(to_vector4(info.uv_scale));

				swift::Optional<GodotRealityKit::LowLevelMesh> low_level_mesh = surface.resource.lowLevelMesh();
				ERR_CONTINUE(low_level_mesh.isNone());
				low_level_mesh.get().setIndexCount(info.index_count);
			}

			static godot::StringName skin_data_str("skin_data");
			static godot::StringName blend_shape_data_str("blend_shape_data");
			const bool has_deform_data = surface.surface_data.has(skin_data_str) ||
					surface.surface_data.has(blend_shape_data_str);
			const bool has_attributes =
					(info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasColor().getRawValue()) ||
					(info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasUV1().getRawValue()) ||
					(info.vertex_buffer_flags & GodotRealityKit::VertexBufferFlags::getHasUV2().getRawValue());
			surface.encoding_mode = MeshEncoder::EncodingMode(
					(has_deform_data ? MeshEncoder::ENCODING_MODE_FLAG_DEFORM : 0) |
					(is_compressed ? MeshEncoder::ENCODING_MODE_FLAG_COMPRESSED : 0) |
					(has_attributes ? MeshEncoder::ENCODING_MODE_FLAG_WITH_UV : 0));
		}

		mesh_encoder.prepare(meshes[idx]);
		mesh_encoder.encode_attributes(meshes[idx]);
		mesh_needs_reencoding.insert(idx);
		return LocalBitVector::IterationResult::PROCESSED;
	});

	for_each_valid([&](uint32_t idx) {
		if (idx >= next_dirty_idx) {
			return;
		}

		if (!is_used_in_frame(idx)) {
			return;
		}
		const Mesh &mesh = meshes[idx];
		if (mesh.skeleton_idx == UINT32_MAX) {
			return;
		}
		if (skeletons->is_dirty(mesh.skeleton_idx)) {
			mesh_needs_reencoding.insert(idx);
		}
		skeletons->mark_used_in_frame(mesh.skeleton_idx);
	});

	mesh_needs_reencoding.for_each([&](uint32_t idx) {
		if (idx >= next_dirty_idx) {
			return;
		}

		if (!is_used_in_frame(idx)) {
			return;
		}

		mesh_needs_reencoding.remove(idx);
		mesh_encoder.encode_positions(meshes[idx]);
	});
	mesh_encoder.commit();

	mesh_needs_bounds_update.for_each([&](uint32_t idx) {
		if (idx >= next_dirty_idx) {
			return;
		}
		if (!is_used_in_frame(idx)) {
			return;
		}

		mesh_needs_bounds_update.remove(idx);
		Mesh &mesh = meshes[idx];
		const godot::AABB &instance_aabb = mesh.instance_aabb;
		if (mesh.compacted_resource.isSome()) {
			swift::Optional<GodotRealityKit::LowLevelMesh> llm = mesh.compacted_resource.lowLevelMesh();
			if (llm.isSome()) {
				llm.get().setBounds(to_vector3(instance_aabb.position), to_vector3(instance_aabb.position + instance_aabb.size));
			}
			mesh.compacted_resource.setBounds(to_vector3(instance_aabb.position), to_vector3(instance_aabb.position + instance_aabb.size));
		} else {
			for (Mesh::Surface &surface : mesh.surfaces) {
				swift::Optional<GodotRealityKit::LowLevelMesh> llm = surface.resource.lowLevelMesh();
				if (llm.isSome()) {
					llm.get().setBounds(to_vector3(instance_aabb.position), to_vector3(instance_aabb.position + instance_aabb.size));
				}
			}
		}
	});

	dirty_mesh_rid_idxs.clear();

	return finished;
}

godot::AABB MeshLoader::get_aabb(godot::RID p_mesh_rid, uint64_t p_instance_id) const {
	const Mesh *mesh = find_mesh(p_mesh_rid, p_instance_id);
	if (!mesh) {
		return godot::AABB();
	}
	return mesh->instance_aabb;
}

GodotRealityKit::MeshResource MeshLoader::find_resource(godot::RID p_mesh_rid,
		uint64_t p_instance_id,
		uint32_t p_surface_idx) const {
	const Mesh *mesh = find_mesh(p_mesh_rid, p_instance_id);
	if (!mesh) {
		return GodotRealityKit::MeshResource::init();
	}
	if (p_surface_idx >= mesh->surfaces.size()) {
		return GodotRealityKit::MeshResource::init();
	}

	return mesh->surfaces[p_surface_idx].resource;
}

godot::AABB MeshLoader::compute_local_aabb(Span<const Mesh::SurfaceInfo> p_surface_infos) const {
	godot::AABB aabb;
	for (uint32_t surface_idx = 0; surface_idx < p_surface_infos.size(); surface_idx++) {
		if (surface_idx == 0) {
			aabb = p_surface_infos[surface_idx].bounds;
		} else {
			aabb.merge_with(p_surface_infos[surface_idx].bounds);
		}
	}
	return aabb;
}

GodotRealityKit::MeshResource MeshLoader::find_compacted_resource(godot::RID p_mesh_rid,
		uint64_t p_instance_id) const {
	const Mesh *mesh = find_mesh(p_mesh_rid, p_instance_id);
	if (!mesh) {
		return GodotRealityKit::MeshResource::init();
	}

	return mesh->compacted_resource;
}

Mesh::SurfaceInfo MeshLoader::get_surface_info(const godot::Dictionary &surface, godot::RID p_mesh_rid) const {
	godot::RenderingServer *rs = godot::RenderingServer::get_singleton();
	const godot::RenderingServer::PrimitiveType primitive = godot::RenderingServer::PrimitiveType(int(surface["primitive"]));

	static godot::StringName uv_scale_str("uv_scale");
	static godot::StringName vertex_count_str("vertex_count");
	static godot::StringName index_count_str("index_count");
	static godot::StringName format_str("format");
	static godot::StringName aabb_str("aabb");

	const godot::Vector4 uv_scale = surface[uv_scale_str];
	const int32_t vertex_count = surface[vertex_count_str];
	const int32_t index_count = surface.get(index_count_str, vertex_count);
	const uint64_t format = surface[format_str];
	const godot::AABB aabb = surface[aabb_str];

	if (primitive != godot::RenderingServer::PRIMITIVE_TRIANGLES) {
		WARN_PRINT("Unhandled primitive type! Mesh may not show properly");
	}

	const uint64_t decompressed_format = format & ~(uint64_t)godot::RenderingServer::ARRAY_FLAG_COMPRESS_ATTRIBUTES;

	const GDRKVertexBufferFormat decompressed = format_to_gdrk(rs, decompressed_format, vertex_count);
	return Mesh::SurfaceInfo{
		.vertex_count = uint32_t(vertex_count),
		.index_count = uint32_t(index_count != 0 ? index_count : vertex_count),
		.vertex_buffer_flags = get_vertex_buffer_flags(format, uv_scale != godot::Vector4(0, 0, 0, 0)),
		.vertex_buffer_format = (format == decompressed_format) ? decompressed : format_to_gdrk(rs, format, vertex_count),
		.decompressed_vertex_buffer_format = decompressed,
		.bounds = aabb,
		.uv_scale = uv_scale,
		.data = surface,
	};
}

bool MeshLoader::surface_needs_new_resource(const Mesh::SurfaceInfo &p_cur, const Mesh::SurfaceInfo &p_new) const {
	return p_cur.vertex_count > p_new.vertex_count || p_cur.index_count > p_new.index_count ||
			p_cur.vertex_buffer_flags != p_new.vertex_buffer_flags;
}

bool MeshLoader::bounds_changed(const godot::AABB &p_cur, const godot::AABB &p_new, float p_percent) const {
	if (!p_cur.has_volume()) {
		return true;
	}

	const godot::Vector3 threshold = p_percent * p_cur.size;
	const godot::Vector3 pos_diff = (p_cur.position - p_new.position).abs();
	const godot::Vector3 size_diff = (p_cur.size - p_new.size).abs();

	return pos_diff.x > threshold.x || pos_diff.y > threshold.y || pos_diff.z > threshold.z ||
			size_diff.x > threshold.x || size_diff.y > threshold.y || size_diff.z > threshold.z;
}
