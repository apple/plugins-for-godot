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

#include "sprite_loader.h"
#include "mesh_common.h"
#include "signposts.h"

using namespace gdrk;

namespace {

auto get_sprite_mesh_prop_hasher() {
	return make_object_property_hasher(make_object_property(&godot::Sprite3D::get_axis),
			make_object_property(&godot::Sprite3D::is_centered),
			make_object_property(&godot::Sprite3D::is_flipped_h),
			make_object_property(&godot::Sprite3D::is_flipped_v),
			make_object_property(&godot::Sprite3D::get_offset),
			make_object_property(&godot::Sprite3D::get_pixel_size),
			make_object_property(&godot::Sprite3D::get_modulate));
}

auto get_sprite_material_prop_hasher() {
	return make_object_property_hasher(make_object_property(&godot::Sprite3D::get_alpha_cut_mode),
			make_object_property(&godot::Sprite3D::get_alpha_scissor_threshold),
			make_object_property(&godot::Sprite3D::get_billboard_mode),
			make_object_property(&godot::Sprite3D::get_draw_flag,
					godot::Sprite3D::FLAG_DOUBLE_SIDED),
			make_object_property(&godot::Sprite3D::get_draw_flag,
					godot::Sprite3D::FLAG_FIXED_SIZE),
			make_object_property(&godot::Sprite3D::get_draw_flag,
					godot::Sprite3D::FLAG_DISABLE_DEPTH_TEST),
			make_object_property(&godot::Sprite3D::get_render_priority),
			make_object_property(&godot::Sprite3D::get_draw_flag, godot::Sprite3D::FLAG_SHADED),
			make_object_property(&godot::Sprite3D::get_texture_filter),
			make_object_property(&godot::Sprite3D::get_draw_flag,
					godot::Sprite3D::FLAG_TRANSPARENT));
}

ProgramDescription get_sprite_base_material_description(godot::SpriteBase3D *p_node) {
	using SB = godot::SpriteBase3D;
	using BM = godot::BaseMaterial3D;
	BM::Transparency transparency = BM::TRANSPARENCY_DISABLED;
	if (p_node->get_draw_flag(SB::FLAG_TRANSPARENT)) {
		if (p_node->get_alpha_cut_mode() == SB::ALPHA_CUT_DISCARD) {
			transparency = BM::TRANSPARENCY_ALPHA_SCISSOR;
		} else if (p_node->get_alpha_cut_mode() == SB::ALPHA_CUT_OPAQUE_PREPASS) {
			transparency = BM::TRANSPARENCY_ALPHA_DEPTH_PRE_PASS;
		} else if (p_node->get_alpha_cut_mode() == SB::ALPHA_CUT_HASH) {
			transparency = BM::TRANSPARENCY_ALPHA_HASH;
		} else {
			transparency = BM::TRANSPARENCY_ALPHA;
		}
	}

	uint32_t flags = (1 << BM::FLAG_SRGB_VERTEX_COLOR) | (1 << BM::FLAG_ALBEDO_FROM_VERTEX_COLOR);
	if (p_node->get_draw_flag(SB::FLAG_DISABLE_DEPTH_TEST)) {
		flags |= (1 << BM::FLAG_DISABLE_DEPTH_TEST);
	}
	if (p_node->get_draw_flag(SB::FLAG_FIXED_SIZE)) {
		flags |= (1 << BM::FLAG_FIXED_SIZE);
	}
	if (p_node->get_billboard_mode() != BM::BILLBOARD_DISABLED) {
		flags |= (1 << BM::FLAG_BILLBOARD_KEEP_SCALE);
	}

	return BaseMaterial3DDescription{
		.render_priority = p_node->get_render_priority(),
		.shading_mode = p_node->get_draw_flag(SB::FLAG_SHADED) ? BM::SHADING_MODE_PER_PIXEL : BM::SHADING_MODE_UNSHADED,
		.transparency = transparency,
		.cull_mode = p_node->get_draw_flag(SB::FLAG_DOUBLE_SIDED) ? BM::CULL_DISABLED : BM::CULL_BACK,
		.texture_filter = p_node->get_texture_filter(),
		.billboard_mode = p_node->get_billboard_mode(),
		.flags = flags,
		.depth_pass_mode = DepthPostpass,
	};
}

} //namespace

void SpriteLoader::update_deps(
		ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);
	TextureLoader *textures = std::get<TextureLoader *>(p_resource_loaders);

	Base::update_deps(p_resource_loaders);

	static auto mesh_prop_hasher = get_sprite_mesh_prop_hasher();
	static auto material_prop_hasher = get_sprite_material_prop_hasher();

	ChangedDependencyListSet changed_mesh_deps = ChangedDependencyListSet(get_capacity());
	ChangedDependencyListSet changed_material_deps = ChangedDependencyListSet(get_capacity());
	for_each_removed([&](uint32_t idx) {
		changed_mesh_deps.mark_changed(idx);
		changed_material_deps.mark_changed(idx);
	});
	for_each_valid([&](uint32_t idx) {
		godot::Sprite3D *node = nodes[idx];

		// Note that we register these resources with their loaders without specifying a corresponding resource object, so we must handle dirty tracking manually.
		// Specifically, the material hash is not calculated from the RID but from all of the node properties that affect the resource.
		// If any of these change the material is marked as dirty so it can be updated.
		const uint32_t mesh_hash = mesh_prop_hasher.hash(node);
		if (dep_states[idx].mesh_hash != mesh_hash) {
			add_mesh_deps(changed_mesh_deps, meshes, idx, node);
			for (uint32_t mesh_idx : add_mesh_deps(changed_mesh_deps, meshes, idx, node)) {
				meshes->mark_dirty(mesh_idx);
			}

			dep_states[idx].mesh_hash = mesh_hash;
		}

		// In the material case, since we don't specify a material resource object we also need to provide and update the MaterialDescription manually.
		const uint32_t material_hash = material_prop_hasher.hash(node);
		if (dep_states[idx].material_hash != material_hash) {
			ProgramDescription material_description = get_sprite_base_material_description(node);
			for (uint32_t material_idx : add_material_deps(changed_material_deps, materials, idx, node)) {
				ProgramDescription desc = material_description;
				materials->set_description(material_idx, std::move(material_description));
				materials->mark_dirty(material_idx);
			}

			// Register the texture with the texture loader ahead of when the material registers it since we also have the resource object here.
			godot::Ref<godot::Texture2D> texture = node->get_texture();
			textures->find_or_add(texture->get_rid(), texture.ptr());

			dep_states[idx].material_hash = material_hash;
		}

		const int32_t frame = node->get_frame();
		if (sprite_frames[idx] != frame) {
			const godot::RID mesh_rid = node->get_base();
			const uint32_t mesh_idx = meshes->find_or_add(mesh_rid, 0);
			meshes->force_update(mesh_idx);
			sprite_frames[idx] = frame;
		}
	});

	mesh_deps.replace_changed(changed_mesh_deps, meshes);
	material_deps.replace_changed(changed_material_deps, materials);
}

void SpriteLoader::update_dirty_flags(const ResourceLoaderSet &p_resource_loaders) {
	const MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	const MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);

	dirty_idxs.merge(mesh_deps.changed());
	if (meshes->has_dirty()) {
		for (Dependency dep : mesh_deps.get()) {
			if (meshes->is_dirty(dep.src)) {
				dirty_idxs.insert(dep.dst);
			}
		}
	}

	dirty_idxs.merge(material_deps.changed());
	if (materials->has_dirty()) {
		for (Dependency dep : material_deps.get()) {
			if (materials->is_dirty(dep.src)) {
				dirty_idxs.insert(dep.dst);
			}
		}
	}
}

void SpriteLoader::update_deps_usage(ResourceLoaderSet &p_resource_loaders) const {
	MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);

	for (Dependency dep : mesh_deps.get()) {
		if (is_valid(dep.dst)) {
			meshes->mark_used_in_frame(dep.src);
		}
	}
	for (Dependency dep : material_deps.get()) {
		if (is_valid(dep.dst)) {
			materials->mark_used_in_frame(dep.src);
		}
	}
}

void SpriteLoader::update(const ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);
	MultiMeshLoader *multimeshes = std::get<MultiMeshLoader *>(p_resource_loaders);

	Base::update(p_resource_loaders);

	for_each_dirty([&](uint32_t idx) {
		godot::Sprite3D *node = nodes[idx];
		ERR_FAIL_NULL(node);

		node_entities[idx].entity.clearChildren();
		for (GodotRealityKit::Entity child : node_to_entities(node, meshes, materials, multimeshes)) {
			node_entities[idx].entity.addChild(child);
		}
	});
}
