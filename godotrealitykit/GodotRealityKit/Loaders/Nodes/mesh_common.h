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

#include "bridge.h"
#include "portal_mesh_instance_3d.h"

#include <godot_cpp/classes/cpu_particles3d.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/sprite3d.hpp>

namespace godot {
class MeshInstance3D;
}

namespace gdrk {

template <typename GeometryInstanceNode>
inline constexpr DepthPassMode node_depth_pass_mode = DepthPassMode::DepthPrepass;

#define SET_DEPTH_POST_PASS(class) \
	template <>                    \
	inline constexpr DepthPassMode node_depth_pass_mode<godot::class> = DepthPassMode::DepthPostpass;

SET_DEPTH_POST_PASS(MultiMeshInstance3D)
SET_DEPTH_POST_PASS(CPUParticles3D)
SET_DEPTH_POST_PASS(Label3D)
SET_DEPTH_POST_PASS(Sprite3D)

struct MultiMeshDependencyState {
	uint32_t mesh_hash = 0;
	uint32_t multimesh_hash = 0;
	uint32_t material_hash = 0;
};

class MaterialLoader;
class TextureLoader;

struct MeshAndRID {
	godot::RID rid;
	godot::Ref<godot::Mesh> mesh;
};

template <bool RIDOnly = false, std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
static inline MeshAndRID get_mesh(const GeometryInstanceNode *p_vi) {
	if constexpr (std::is_same_v<GeometryInstanceNode, godot::MultiMeshInstance3D>) {
		godot::Ref<godot::MultiMesh> multimesh = p_vi->get_multimesh();
		godot::Ref<godot::Mesh> mesh = multimesh.is_valid() ? multimesh->get_mesh() : nullptr;
		if (mesh.is_valid()) {
			return { .rid = mesh->get_rid(), .mesh = mesh };
		} else {
			return { .rid = godot::RID(), .mesh = nullptr };
		}
	} else if constexpr (std::is_same_v<GeometryInstanceNode, godot::CPUParticles3D>) {
		godot::Ref<godot::Mesh> mesh = p_vi->get_mesh();
		if (mesh.is_valid()) {
			return { .rid = mesh->get_rid(), .mesh = mesh };
		} else {
			return { .rid = godot::RID(), .mesh = nullptr };
		}
	} else if constexpr (!RIDOnly && std::is_base_of_v<GeometryInstanceNode, godot::MeshInstance3D>) {
		godot::Ref<godot::Mesh> mesh = p_vi->get_mesh();
		if (mesh.is_valid()) {
			return { .rid = mesh->get_rid(), .mesh = mesh };
		} else {
			return { .rid = godot::RID(), .mesh = nullptr };
		}
	} else {
		return { .rid = p_vi->get_base(), .mesh = nullptr };
	}
}

static inline godot::RID get_skeleton(const godot::MeshInstance3D *p_mesh_instance) {
	godot::Ref<godot::SkinReference> skin_ref = p_mesh_instance->get_skin_reference();
	return skin_ref.is_valid() ? skin_ref->get_skeleton() : godot::RID();
}

struct MaterialAndRID {
	godot::RID rid;
	godot::Ref<godot::Material> material;
};

static inline MaterialAndRID get_surface_material(
		godot::RID p_mesh_rid,
		const godot::Mesh *p_mesh,
		uint32_t p_surface_idx) {
	if (p_mesh) {
		godot::Ref<godot::Material> material = p_mesh->surface_get_material(p_surface_idx);
		if (material.is_valid()) {
			return { .rid = material->get_rid(), .material = material };
		} else {
			return { .rid = godot::RID(), .material = nullptr };
		}
	} else {
		const godot::RID res_rid = rendering_server()->mesh_surface_get_material(p_mesh_rid, p_surface_idx);
		return { .rid = res_rid, .material = nullptr };
	}
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
static inline MaterialAndRID get_surface_material(
		const GeometryInstanceNode *p_vi,
		uint32_t p_surface_idx) {
	if constexpr (std::is_base_of_v<GeometryInstanceNode, godot::MeshInstance3D>) {
		godot::Ref<godot::Material> material = p_vi->get_active_material(p_surface_idx);
		if (material.is_valid()) {
			return { .rid = material->get_rid(), .material = material };
		} else {
			return { .rid = godot::RID(), .material = nullptr };
		}
	}

	godot::Ref<godot::Material> material_override = p_vi->get_material_override();
	if (material_override.is_valid()) {
		return { .rid = material_override->get_rid(), .material = material_override };
	}

	const auto [mesh_rid, mesh] = get_mesh(p_vi);
	return get_surface_material(mesh_rid, mesh.ptr(), p_surface_idx);
}

static inline uint64_t get_surface_material_hash_state(
		const godot::RID &p_mesh_rid,
		uint32_t p_surface_idx) {
	const godot::RID res_rid = rendering_server()->mesh_surface_get_material(p_mesh_rid, p_surface_idx);
	return res_rid.get_id();
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
static inline uint64_t get_surface_material_hash_state(
		const GeometryInstanceNode *p_vi,
		uint32_t p_surface_idx) {
	if constexpr (std::is_base_of_v<GeometryInstanceNode, godot::MeshInstance3D>) {
		godot::Ref<godot::Material> mi_material = p_vi->get_active_material(p_surface_idx);
		return (uint64_t)mi_material.ptr();
	}

	godot::Ref<godot::Material> material_override = p_vi->get_material_override();
	if (material_override.is_valid()) {
		return (uint64_t)material_override.ptr();
	}

	const auto [mesh_rid, mesh] = get_mesh<true>(p_vi);
	return get_surface_material_hash_state(mesh_rid, p_surface_idx);
}

static inline uint32_t mesh_get_surface_count(godot::RID p_mesh_rid) {
	if (!p_mesh_rid.is_valid()) {
		return 0;
	}
	godot::RenderingServer *rs = rendering_server();
	return rs->mesh_get_surface_count(p_mesh_rid);
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
static inline uint32_t mesh_get_surface_count(GeometryInstanceNode *p_vi) {
	const auto [mesh_rid, mesh] = get_mesh<true>(p_vi);
	return mesh_get_surface_count(mesh_rid);
}

inline static void accum_mesh_hash(const godot::RID &p_mesh_rid,
		uint64_t p_skeleton_rid_id,
		uint32_t &p_mesh_hash_state,
		uint32_t &p_material_hash_state) {
	const uint64_t mesh_rid_id = *std::launder(reinterpret_cast<const uint64_t *>(&p_mesh_rid));
	p_mesh_hash_state = godot::hash_murmur3_one_64(mesh_rid_id, p_mesh_hash_state);
	if (p_skeleton_rid_id) {
		p_mesh_hash_state = godot::hash_murmur3_one_64(p_skeleton_rid_id, p_mesh_hash_state);
	}

	const uint32_t surface_count = mesh_get_surface_count(p_mesh_rid);
	for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
		const uint64_t material_hash = get_surface_material_hash_state(p_mesh_rid, surface_idx);
		p_material_hash_state = godot::hash_murmur3_one_64(material_hash, p_material_hash_state);
	}
}

template <bool HasSkeleton = false, std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
inline static void accum_mesh_hash(
		const GeometryInstanceNode *p_vi,
		uint32_t &p_mesh_hash_state,
		uint32_t &p_material_hash_state) {
	uint64_t skeleton_rid_id = 0;
	const auto [mesh_rid, mesh] = get_mesh<true>(p_vi);
	if constexpr (HasSkeleton && std::is_base_of_v<GeometryInstanceNode, godot::MeshInstance3D>) {
		skeleton_rid_id = get_skeleton(p_vi).get_id();
	}

	const uint64_t mesh_rid_id = *std::launder(reinterpret_cast<const uint64_t *>(&mesh_rid));
	p_mesh_hash_state = godot::hash_murmur3_one_64(mesh_rid_id, p_mesh_hash_state);
	if (skeleton_rid_id) {
		p_mesh_hash_state = godot::hash_murmur3_one_64(skeleton_rid_id, p_mesh_hash_state);
	}

	const uint32_t surface_count = mesh_get_surface_count(mesh_rid);
	for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
		const uint64_t material_hash = get_surface_material_hash_state(p_vi, surface_idx);
		p_material_hash_state = godot::hash_murmur3_one_64(material_hash, p_material_hash_state);
	}
}

inline static GodotRealityKit::Entity mesh_surface_to_entity(
		godot::RID p_mesh_rid,
		uint64_t p_instance_id,
		uint32_t p_surface_idx,
		godot::RID p_material_rid,
		const MeshLoader *p_meshes,
		const MaterialLoader *p_materials,
		DepthPassMode p_depth_pass_mode = DepthPassMode::DepthPrepass) {
	if (!p_mesh_rid.is_valid()) {
		return GodotRealityKit::Entity::initAndMaterialize();
	}

	const GodotRealityKit::Entity entity = GodotRealityKit::Entity::initAndMaterialize();
	GodotRealityKit::MeshResource mesh_resource =
			p_meshes->find_resource(p_mesh_rid, p_instance_id, p_surface_idx);
	ERR_FAIL_COND_V(!mesh_resource.isSome(), GodotRealityKit::Entity::initAndMaterialize());

	if (p_material_rid.is_valid() && p_materials->is_loading(p_material_rid, p_depth_pass_mode)) {
		return GodotRealityKit::Entity::initAndMaterialize();
	}

	swift::Array<GodotRealityKit::SGLMaterial> material_resources =
			swift::Array<GodotRealityKit::SGLMaterial>::init(p_materials->find_resource(p_material_rid, p_depth_pass_mode), 1);

	entity.setModel(mesh_resource, material_resources);
	return entity;
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
inline static GodotRealityKit::Entity mesh_compacted_to_entity(
		const GeometryInstanceNode *p_vi,
		const MeshLoader *p_meshes,
		const MaterialLoader *p_materials,
		const MultiMeshLoader *p_multimeshes) {
	const auto [mesh_rid, mesh] = get_mesh<true>(p_vi);

	uint64_t instance_id = 0;
	if constexpr (std::is_base_of_v<GeometryInstanceNode, godot::MeshInstance3D>) {
		const bool has_skeleton = godot::Object::cast_to<godot::Skeleton3D>(p_vi->get_parent()) != nullptr;
		if (has_skeleton || p_vi->get_blend_shape_count() > 0) {
			instance_id = p_vi->get_instance_id();
		}
	}

	if (!mesh_rid.is_valid()) {
		return GodotRealityKit::Entity::initAndMaterialize();
	}

	constexpr DepthPassMode depth_pass_mode = node_depth_pass_mode<GeometryInstanceNode>;

	const GodotRealityKit::Entity entity = GodotRealityKit::Entity::initAndMaterialize();
	GodotRealityKit::MeshResource mesh_resource = p_meshes->find_compacted_resource(mesh_rid, instance_id);
	ERR_FAIL_COND_V(!mesh_resource.isSome(), GodotRealityKit::Entity::initAndMaterialize());

	if constexpr (std::is_same_v<GeometryInstanceNode, RealityPortalMeshInstance3D>) {
		entity.setPortalModel(mesh_resource);
		return entity;
	}

	const uint32_t surface_count = mesh_get_surface_count(mesh_rid);
	swift::Array<GodotRealityKit::SGLMaterial> material_resources =
			swift::Array<GodotRealityKit::SGLMaterial>::init();
	for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
		const auto [material_rid, material] = get_surface_material(p_vi, surface_idx);
		if (material_rid.is_valid() && p_materials->is_loading(material_rid, depth_pass_mode)) {
			return GodotRealityKit::Entity::initAndMaterialize();
		}
		material_resources.append(p_materials->find_resource(material_rid, depth_pass_mode));
	}

	entity.setModel(mesh_resource, material_resources);

	if constexpr (std::is_same_v<GeometryInstanceNode, godot::MultiMeshInstance3D> ||
			std::is_same_v<GeometryInstanceNode, godot::CPUParticles3D>) {
		const godot::RID multimesh_rid = p_vi->get_base();
		entity.setInstanceData(p_multimeshes->find_resource(multimesh_rid));
	}

	return entity;
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
inline static GodotRealityKit::Entity mesh_surface_to_entity(
		const GeometryInstanceNode *p_vi,
		uint32_t p_surface_idx,
		const MeshLoader *p_meshes,
		const MaterialLoader *p_materials,
		const MultiMeshLoader *p_multimeshes) {
	const auto [mesh_rid, mesh] = get_mesh<true>(p_vi);

	uint64_t instance_id = 0;
	if constexpr (std::is_base_of_v<GeometryInstanceNode, godot::MeshInstance3D>) {
		const bool has_skeleton = godot::Object::cast_to<godot::Skeleton3D>(p_vi->get_parent()) != nullptr;
		if (has_skeleton || p_vi->get_blend_shape_count() > 0) {
			instance_id = p_vi->get_instance_id();
		}
	}

	if constexpr (std::is_same_v<GeometryInstanceNode, RealityPortalMeshInstance3D>) {
		GodotRealityKit::Entity entity = GodotRealityKit::Entity::initAndMaterialize();
		GodotRealityKit::MeshResource mesh_resource =
				p_meshes->find_resource(mesh_rid, instance_id, p_surface_idx);
		entity.setPortalModel(mesh_resource);
		return entity;
	}

	const auto [material_rid, material] = get_surface_material(p_vi, p_surface_idx);
	const GodotRealityKit::Entity entity = mesh_surface_to_entity(
			mesh_rid, instance_id, p_surface_idx, material_rid, p_meshes, p_materials, node_depth_pass_mode<GeometryInstanceNode>);

	if constexpr (std::is_same_v<GeometryInstanceNode, godot::MultiMeshInstance3D> ||
			std::is_same_v<GeometryInstanceNode, godot::CPUParticles3D>) {
		const godot::RID multimesh_rid = p_vi->get_base();
		entity.setInstanceData(p_multimeshes->find_resource(multimesh_rid));
	}

	return entity;
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
inline static SmallLocalVector<GodotRealityKit::Entity, 8> node_to_entities(
		const GeometryInstanceNode *p_vi,
		const MeshLoader *p_meshes,
		const MaterialLoader *p_materials,
		const MultiMeshLoader *p_multimeshes) {
	const auto [mesh_rid, mesh] = get_mesh<true>(p_vi);

	uint64_t instance_id = 0;
	if constexpr (std::is_base_of_v<GeometryInstanceNode, godot::MeshInstance3D>) {
		const bool has_skeleton = godot::Object::cast_to<godot::Skeleton3D>(p_vi->get_parent()) != nullptr;
		if (has_skeleton || p_vi->get_blend_shape_count() > 0) {
			instance_id = p_vi->get_instance_id();
		}
	}

	SmallLocalVector<GodotRealityKit::Entity, 8> res;
	if (!mesh_rid.is_valid()) {
		return res;
	}

	if (p_meshes->is_compacted(mesh_rid, instance_id)) {
		res.push_back(mesh_compacted_to_entity(p_vi, p_meshes, p_materials, p_multimeshes));
	} else {
		const uint32_t surface_count = mesh_get_surface_count(mesh_rid);
		res.reserve(surface_count);
		for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
			res.push_back(mesh_surface_to_entity(p_vi, surface_idx, p_meshes, p_materials, p_multimeshes));
		}
	}

	return res;
}

inline static GodotRealityKit::Entity mesh_compacted_to_entity(
		godot::RID p_mesh_rid,
		const MeshLoader *p_meshes,
		const MaterialLoader *p_materials) {
	if (!p_mesh_rid.is_valid()) {
		return GodotRealityKit::Entity::initAndMaterialize();
	}

	const GodotRealityKit::Entity entity = GodotRealityKit::Entity::initAndMaterialize();
	GodotRealityKit::MeshResource mesh_resource = p_meshes->find_compacted_resource(p_mesh_rid, 0);
	ERR_FAIL_COND_V(!mesh_resource.isSome(), GodotRealityKit::Entity::initAndMaterialize());

	const uint32_t surface_count = mesh_get_surface_count(p_mesh_rid);
	swift::Array<GodotRealityKit::SGLMaterial> material_resources =
			swift::Array<GodotRealityKit::SGLMaterial>::init();
	for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
		const auto [material_rid, material] = get_surface_material(p_mesh_rid, nullptr, surface_idx);
		if (material_rid.is_valid() && p_materials->is_loading(material_rid)) {
			return GodotRealityKit::Entity::initAndMaterialize();
		}
		material_resources.append(p_materials->find_resource(material_rid));
	}

	entity.setModel(mesh_resource, material_resources);
	return entity;
}

inline static SmallLocalVector<GodotRealityKit::Entity, 8> node_to_entities(
		godot::RID p_mesh_rid,
		const MeshLoader *p_meshes,
		const MaterialLoader *p_materials) {
	SmallLocalVector<GodotRealityKit::Entity, 8> res;
	if (!p_mesh_rid.is_valid()) {
		return res;
	}

	if (p_meshes->is_compacted(p_mesh_rid, 0)) {
		res.push_back(mesh_compacted_to_entity(p_mesh_rid, p_meshes, p_materials));
	} else {
		const uint32_t surface_count = mesh_get_surface_count(p_mesh_rid);
		res.reserve(surface_count);
		for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
			const auto [material_rid, material] = get_surface_material(p_mesh_rid, nullptr, surface_idx);
			res.push_back(mesh_surface_to_entity(p_mesh_rid, 0, surface_idx, material_rid, p_meshes, p_materials));
		}
	}
	return res;
}

inline static SmallLocalVector<uint32_t, 8> add_mesh_deps(
		ChangedDependencyListSet &p_changed_mesh_deps,
		MeshLoader *p_meshes,
		uint32_t p_node_idx,
		godot::RID p_mesh_rid,
		uint64_t p_instance_id = 0,
		godot::Mesh *p_mesh = nullptr,
		godot::Skeleton3D *p_skeleton = nullptr) {
	p_changed_mesh_deps.mark_changed(p_node_idx);

	SmallLocalVector<uint32_t, 8> res;
	if (p_mesh_rid.is_valid()) {
		const uint32_t mesh_idx = p_meshes->find_or_add(p_mesh_rid, p_instance_id, p_mesh, p_skeleton);
		p_changed_mesh_deps.add_changed_dep(mesh_idx, p_node_idx);
		res.push_back(mesh_idx);
	}

	return res;
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
inline static SmallLocalVector<uint32_t, 8> add_mesh_deps(
		ChangedDependencyListSet &p_changed_mesh_deps,
		MeshLoader *p_meshes,
		uint32_t p_node_idx,
		const GeometryInstanceNode *p_vi) {
	const auto [mesh_rid, mesh] = get_mesh(p_vi);

	uint64_t instance_id = 0;
	godot::Skeleton3D *skeleton = nullptr;
	if constexpr (std::is_base_of_v<GeometryInstanceNode, godot::MeshInstance3D>) {
		skeleton = godot::Object::cast_to<godot::Skeleton3D>(p_vi->get_parent());
		// Per-instance mesh entry only when the instance has its own deformed
		// state (skeleton or blend shapes). Static meshes share by mesh_rid.
		if (skeleton != nullptr || p_vi->get_blend_shape_count() > 0) {
			instance_id = p_vi->get_instance_id();
		}
	}

	return add_mesh_deps(p_changed_mesh_deps, p_meshes, p_node_idx, mesh_rid, instance_id, mesh.ptr(), skeleton);
}

inline static SmallLocalVector<uint32_t, 8> add_material_deps(
		ChangedDependencyListSet &p_changed_material_deps,
		MaterialLoader *p_materials,
		uint32_t p_node_idx,
		godot::RID p_mesh_rid,
		godot::Mesh *p_mesh) {
	p_changed_material_deps.mark_changed(p_node_idx);

	SmallLocalVector<uint32_t, 8> res;
	for (uint32_t surface_idx = 0; surface_idx < mesh_get_surface_count(p_mesh_rid); surface_idx++) {
		const auto [material_rid, material] = get_surface_material(p_mesh_rid, p_mesh, surface_idx);
		const uint32_t material_idx = p_materials->find_or_add(material_rid, material);
		p_changed_material_deps.add_changed_dep(material_idx, p_node_idx);
		res.push_back(material_idx);
	};

	return res;
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
inline static SmallLocalVector<uint32_t, 8> add_material_deps(
		ChangedDependencyListSet &p_changed_material_deps,
		MaterialLoader *p_materials,
		uint32_t p_node_idx,
		const GeometryInstanceNode *p_vi) {
	p_changed_material_deps.mark_changed(p_node_idx);

	constexpr DepthPassMode depth_pass_mode = node_depth_pass_mode<GeometryInstanceNode>;

	SmallLocalVector<uint32_t, 8> res;
	for (uint32_t surface_idx = 0; surface_idx < mesh_get_surface_count(p_vi); surface_idx++) {
		const auto [material_rid, material] = get_surface_material(p_vi, surface_idx);
		const uint32_t material_idx = p_materials->find_or_add(material_rid, material, depth_pass_mode);
		p_changed_material_deps.add_changed_dep(material_idx, p_node_idx);
		res.push_back(material_idx);
	}

	return res;
}

template <std::derived_from<godot::GeometryInstance3D> GeometryInstanceNode>
inline static void add_dirty_multimesh_deps(ChangedDependencyListSet &p_changed_mesh_deps,
		ChangedDependencyListSet &p_changed_multimesh_deps,
		ChangedDependencyListSet &p_changed_material_deps,
		godot::LocalVector<MultiMeshDependencyState> &dep_states,
		MeshLoader *p_meshes,
		MultiMeshLoader *p_multimeshes,
		MaterialLoader *p_materials,
		const GeometryInstanceNode *p_vi,
		godot::Mesh *p_mesh,
		uint32_t p_idx) {
	static_assert(std::is_same_v<GeometryInstanceNode, godot::MultiMeshInstance3D> ||
			std::is_same_v<GeometryInstanceNode, godot::CPUParticles3D>);

	const godot::RID instance_rid = p_vi->get_instance();
	const godot::RID multimesh_rid = p_vi->get_base();

	uint32_t mesh_hash_state = HASH_MURMUR3_SEED;
	uint32_t material_hash_state = HASH_MURMUR3_SEED;
	accum_mesh_hash(p_vi, mesh_hash_state, material_hash_state);
	const uint32_t multimesh_hash_state = godot::hash_murmur3_one_64(multimesh_rid.get_id());

	const uint32_t mesh_hash = godot::hash_fmix32(mesh_hash_state);
	const uint32_t multimesh_hash = godot::hash_fmix32(multimesh_hash_state);
	const uint32_t material_hash = godot::hash_fmix32(material_hash_state);
	if (mesh_hash != dep_states[p_idx].mesh_hash) {
		for (uint32_t mesh_idx : add_mesh_deps(p_changed_mesh_deps, p_meshes, p_idx, p_vi)) {
			p_meshes->set_no_compact(mesh_idx);
		}
		dep_states[p_idx].mesh_hash = mesh_hash;
	}

	if (material_hash != dep_states[p_idx].material_hash) {
		add_material_deps(p_changed_material_deps, p_materials, p_idx, p_vi);
		dep_states[p_idx].material_hash = material_hash;
	}

	if (multimesh_hash != dep_states[p_idx].multimesh_hash) {
		p_changed_multimesh_deps.mark_changed(p_idx);

		if (multimesh_rid.is_valid()) {
			const uint32_t multimesh_idx = p_multimeshes->find_or_add(multimesh_rid);
			p_changed_multimesh_deps.add_changed_dep(multimesh_idx, p_idx);
		}

		dep_states[p_idx].multimesh_hash = multimesh_hash;
	}
}

} //namespace gdrk
