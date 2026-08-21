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

#include "label_loader.h"
#include "mesh_common.h"
#include "signposts.h"

#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/text_server_manager.hpp>
#include <godot_cpp/classes/theme_db.hpp>
#include <godot_cpp/templates/hash_set.hpp>

using namespace gdrk;

auto get_label_text_prop_hasher() {
	using L = godot::Label3D;
	return make_object_property_hasher(make_object_property(&L::get_autowrap_mode),
			make_object_property(&L::get_font),
			make_object_property(&L::get_font_size),
			make_object_property(&L::get_justification_flags),
			make_object_property(&L::get_language),
			make_object_property(&L::get_line_spacing),
			make_object_property(&L::get_offset),
			make_object_property(&L::get_outline_size),
			make_object_property(&L::get_pixel_size),
			make_object_property(&L::get_structured_text_bidi_override),
			make_object_property(&L::get_structured_text_bidi_override_options),
			make_object_property(&L::get_text),
			make_object_property(&L::get_text_direction),
			make_object_property(&L::is_uppercase),
			make_object_property(&L::get_vertical_alignment),
			make_object_property(&L::get_width));
}

auto get_label_material_prop_hasher() {
	using L = godot::Label3D;
	return make_object_property_hasher(make_object_property(&L::get_alpha_antialiasing_edge),
			make_object_property(&L::get_alpha_antialiasing),
			make_object_property(&L::get_alpha_cut_mode),
			make_object_property(&L::get_alpha_hash_scale),
			make_object_property(&L::get_alpha_scissor_threshold),
			make_object_property(&L::get_billboard_mode),
			make_object_property<L>(&L::get_cast_shadows_setting),
			make_object_property(&L::get_draw_flag, L::FLAG_DOUBLE_SIDED),
			make_object_property(&L::get_draw_flag, L::FLAG_FIXED_SIZE),
			make_object_property(&L::get_modulate),
			make_object_property(&L::get_draw_flag,
					L::FLAG_DISABLE_DEPTH_TEST),
			make_object_property(&L::get_draw_flag, L::FLAG_FIXED_SIZE),
			make_object_property(&L::get_modulate),
			make_object_property(&L::get_draw_flag, L::FLAG_DISABLE_DEPTH_TEST),
			make_object_property(&L::get_outline_modulate),
			make_object_property(&L::get_outline_render_priority),
			make_object_property(&L::get_render_priority),
			make_object_property(&L::get_draw_flag, L::FLAG_SHADED),
			make_object_property(&L::get_texture_filter));
}

// Match Label3D's fallback behavior when no font is assigned.
static godot::Ref<godot::Font> get_label_font(godot::Label3D *p_node) {
	godot::Ref<godot::Font> font = p_node->get_font();
	if (font.is_null()) {
		font = godot::ThemeDB::get_singleton()->get_fallback_font();
	}
	return font;
}

// Glyph membership can change while Godot keeps the same atlas RID.
static uint32_t get_font_atlas_hash(const godot::Ref<godot::Font> &p_font, godot::HashSet<godot::RID> &r_atlas_rids) {
	const godot::Ref<godot::TextServer> text_server = godot::TextServerManager::get_singleton()->get_primary_interface();
	if (p_font.is_null() || text_server.is_null()) {
		return 0;
	}

	uint32_t hash = HASH_MURMUR3_SEED;
	const godot::TypedArray<godot::RID> font_rids = p_font->get_rids();
	for (int font_idx = 0; font_idx < font_rids.size(); font_idx++) {
		const godot::RID font_rid = font_rids[font_idx];
		hash = godot::hash_murmur3_one_64(font_rid.get_id(), hash);
		const godot::TypedArray<godot::Vector2i> sizes = text_server->font_get_size_cache_list(font_rid);
		for (int size_idx = 0; size_idx < sizes.size(); size_idx++) {
			const godot::Vector2i size = sizes[size_idx];
			hash = godot::hash_murmur3_one_32(size.x, hash);
			hash = godot::hash_murmur3_one_32(size.y, hash);
			const godot::PackedInt32Array glyphs = text_server->font_get_glyph_list(font_rid, size);
			for (int glyph_idx = 0; glyph_idx < glyphs.size(); glyph_idx++) {
				const int32_t glyph = glyphs[glyph_idx];
				hash = godot::hash_murmur3_one_32(glyph, hash);
				const godot::RID atlas_rid = text_server->font_get_glyph_texture_rid(font_rid, size, glyph);
				if (atlas_rid.is_valid()) {
					r_atlas_rids.insert(atlas_rid);
					hash = godot::hash_murmur3_one_64(atlas_rid.get_id(), hash);
				}
			}
		}
	}
	return godot::hash_fmix32(hash);
}

ProgramDescription get_label_material_description(godot::Label3D *p_node, bool p_outline, bool p_is_msdf) {
	using L = godot::Label3D;
	using BM = godot::BaseMaterial3D;
	BM::Transparency transparency = BM::TRANSPARENCY_ALPHA;
	if (p_node->get_alpha_cut_mode() == L::ALPHA_CUT_DISCARD) {
		transparency = BM::TRANSPARENCY_ALPHA_SCISSOR;
	} else if (p_node->get_alpha_cut_mode() == L::ALPHA_CUT_OPAQUE_PREPASS) {
		transparency = BM::TRANSPARENCY_ALPHA_DEPTH_PRE_PASS;
	} else if (p_node->get_alpha_cut_mode() == L::ALPHA_CUT_HASH) {
		transparency = BM::TRANSPARENCY_ALPHA_HASH;
	}

	uint32_t flags = (1 << BM::FLAG_SRGB_VERTEX_COLOR) | (1 << BM::FLAG_ALBEDO_FROM_VERTEX_COLOR);
	if (p_node->get_draw_flag(L::FLAG_DISABLE_DEPTH_TEST)) {
		flags |= (1 << BM::FLAG_DISABLE_DEPTH_TEST);
	}
	if (p_node->get_draw_flag(L::FLAG_FIXED_SIZE)) {
		flags |= (1 << BM::FLAG_FIXED_SIZE);
	}
	if (p_node->get_billboard_mode() != BM::BILLBOARD_DISABLED) {
		flags |= (1 << BM::FLAG_BILLBOARD_KEEP_SCALE);
	}

	if (p_is_msdf) {
		flags |= (1 << BM::FLAG_ALBEDO_TEXTURE_MSDF);
	}

	return BaseMaterial3DDescription{
		.render_priority = p_outline ? p_node->get_outline_render_priority() : p_node->get_render_priority(),
		.shading_mode = p_node->get_draw_flag(L::FLAG_SHADED) ? BM::SHADING_MODE_PER_PIXEL : BM::SHADING_MODE_UNSHADED,
		.transparency = transparency,
		.cull_mode = p_node->get_draw_flag(L::FLAG_DOUBLE_SIDED) ? BM::CULL_DISABLED : BM::CULL_BACK,
		.texture_filter = p_node->get_texture_filter(),
		.billboard_mode = p_node->get_billboard_mode(),
		.flags = flags,
	};
}

void LabelLoader::update_deps(
		ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);
	TextureLoader *textures = std::get<TextureLoader *>(p_resource_loaders);

	Base::update_deps(p_resource_loaders);

	const godot::RenderingServer *rs = rendering_server();
	static auto text_prop_hasher = get_label_text_prop_hasher();
	static auto material_prop_hasher = get_label_material_prop_hasher();

	ChangedMeshDependencyListSet changed_mesh_deps = ChangedMeshDependencyListSet(get_capacity());
	ChangedDependencyListSet changed_material_deps = ChangedDependencyListSet(get_capacity());
	struct FontAtlasState {
		godot::Font *font = nullptr;
		uint32_t hash = 0;
		godot::HashSet<godot::RID> atlas_rids;
	};
	// Cache each font atlas scan for labels that share a font during this update.
	godot::LocalVector<FontAtlasState> font_atlas_cache;
	for_each_removed([&](uint32_t idx) {
		changed_mesh_deps.mark_changed(idx);
		changed_material_deps.mark_changed(idx);
	});
	for_each_valid([&](uint32_t idx) {
		godot::Label3D *node = nodes[idx];

		uint32_t mesh_hash_state = text_prop_hasher.hash(node);
		uint32_t material_hash_state = HASH_MURMUR3_SEED;
		accum_mesh_hash(node, mesh_hash_state, material_hash_state);
		// Include the generated surfaces so deferred Label3D mesh rebuilds trigger a reload.
		mesh_hash_state = godot::hash_murmur3_one_64(material_hash_state, mesh_hash_state);
		material_hash_state = godot::hash_murmur3_one_64(material_prop_hasher.hash(node), material_hash_state);

		bool text_dirty = false;
		const uint32_t text_hash = godot::hash_fmix32(mesh_hash_state);
		if (dep_states[idx].text_hash != text_hash) {
			for (uint32_t mesh_idx : add_mesh_deps(changed_mesh_deps, meshes, idx, node)) {
				meshes->mark_dirty(mesh_idx);
			}

			dep_states[idx].text_hash = text_hash;
			text_dirty = true;
		}

		const godot::HashSet<godot::RID> *font_atlas_rids = nullptr;
		uint32_t font_atlas_hash = dep_states[idx].font_atlas_hash;
		bool font_atlas_dirty = false;
		if (text_dirty) {
			const godot::Ref<godot::Font> font = get_label_font(node);
			for (FontAtlasState &state : font_atlas_cache) {
				if (state.font == font.ptr()) {
					font_atlas_hash = state.hash;
					font_atlas_rids = &state.atlas_rids;
					break;
				}
			}
			if (font_atlas_rids == nullptr) {
				FontAtlasState state;
				state.font = font.ptr();
				state.hash = get_font_atlas_hash(font, state.atlas_rids);
				font_atlas_cache.push_back(std::move(state));
				font_atlas_hash = font_atlas_cache[font_atlas_cache.size() - 1].hash;
				font_atlas_rids = &font_atlas_cache[font_atlas_cache.size() - 1].atlas_rids;
			}
			font_atlas_dirty = dep_states[idx].font_atlas_hash != font_atlas_hash;
		}

		// We mix the text properties hash into the material propeties hash, since if the text needs to be reloaded
		// the the material also needs to be reloaded to reference a potentially new font atlas texture (with a separate RID).
		// We also mark the font atlas texture(s) for each material as dirty here too.
		const uint32_t material_hash = godot::hash_fmix32(material_hash_state);
		if (dep_states[idx].material_hash != material_hash || text_dirty || font_atlas_dirty) {
			bool is_outline = false;
			for (uint32_t material_idx : add_material_deps(changed_material_deps, materials, idx, node)) {
				const godot::RID material_rid = materials->get_rid(material_idx);
				ERR_CONTINUE(!material_rid.is_valid());
				const godot::RID albedo_texture_rid = rs->material_get_param(material_rid, "texture_albedo");
				// Generated surfaces can use different atlas formats.
				const bool is_msdf = rs->material_get_param(material_rid, "msdf_pixel_range").get_type() != godot::Variant::NIL;
				ProgramDescription desc = get_label_material_description(node, is_outline, is_msdf);
				if (!is_outline) {
					is_outline = true;
				}

				materials->set_description(material_idx, std::move(desc));
				materials->mark_dirty(material_idx);

				if (font_atlas_dirty || (text_dirty && !font_atlas_rids->has(albedo_texture_rid))) {
					if (albedo_texture_rid.is_valid()) {
						// Recreate the texture only when the glyph atlas changes; cached glyphs can
						// reuse it, while unknown fallback atlases keep the conservative refresh path.
						const uint32_t albedo_texture_idx = textures->find_or_add(
								albedo_texture_rid, nullptr, TextureLoader::TextureUsage::Rendering, true);
						textures->mark_dirty(albedo_texture_idx);
					}
				}
			}

			dep_states[idx].material_hash = material_hash;
		}
		dep_states[idx].font_atlas_hash = font_atlas_hash;
	});

	mesh_deps.replace_changed(changed_mesh_deps, meshes);
	material_deps.replace_changed(changed_material_deps, materials);
}

void LabelLoader::update(const ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);
	MultiMeshLoader *multimeshes = std::get<MultiMeshLoader *>(p_resource_loaders);

	Base::update(p_resource_loaders);

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

	for_each_dirty([&](uint32_t idx) {
		godot::Label3D *node = nodes[idx];
		ERR_FAIL_NULL(node);

		// Wait for every surface to avoid invalid access and partial replacement.
		const godot::RID mesh_rid = node->get_base();
		const uint32_t surface_count = mesh_get_surface_count(mesh_rid);
		for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
			if (meshes->find_resource(mesh_rid, 0, surface_idx).isNone()) {
				return;
			}
			const godot::RID material_rid = get_surface_material(node, surface_idx).rid;
			if (material_rid.is_valid() && materials->is_loading(material_rid)) {
				return;
			}
		}

		node_entities[idx].entity.clearChildren();
		for (uint32_t surface_idx = 0; surface_idx < surface_count; surface_idx++) {
			GodotRealityKit::Entity child = mesh_surface_to_entity(node, surface_idx, meshes, materials, multimeshes);
			node_entities[idx].entity.addChild(child);
		}
	});
}
