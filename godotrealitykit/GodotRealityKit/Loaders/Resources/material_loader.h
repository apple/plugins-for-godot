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

#include "Materials/program_description.h"
#include "resource_loader.h"

#include <godot_cpp/classes/standard_material3d.hpp>

namespace gdrk {

// When registering a material_rid through find_or_add, if no p_material is specified then not only will
// change tracking not happen automatically but the material description will not be updated
// (or initialized) automatically.
// In this case, the node most not only manually implement dirty tracking but also update the description
// when the material changes.
// Not all information about a material can be found using its RID so we have this sort of awkward setup.
class MaterialLoader : public ResourceLoader<MaterialLoader> {
	GDCLASS(MaterialLoader, Object);

protected:
	static void _bind_methods() {}

public:
	MaterialLoader();

	static const char *get_variants_dict_path() {
		return "res://.godot/bm_variants.dict";
	}

	static ProgramDescription program_description_for_material(const godot::Material &p_material);

	void _reserve(uint32_t p_capacity) {
		ResourceLoader<MaterialLoader>::_reserve(p_capacity);
		materials.resize(p_capacity);
		material_dep_states.resize(p_capacity);
	}

	uint32_t find(godot::RID p_material_rid) const {
		return material_rid_to_idx.has(p_material_rid) ? material_rid_to_idx.get(p_material_rid) : UINT32_MAX;
	}

	uint32_t find_or_add(godot::RID p_material_rid, godot::Ref<godot::Material> p_material);

	const ProgramDescription &get_description(uint32_t p_index) const {
		return materials[p_index].description;
	}

	bool set_description(uint32_t p_idx, ProgramDescription &&p_description) {
		Material &mat = materials[p_idx];
		if (p_description.hash != mat.description.hash) {
			mat.description = std::move(p_description);
			mat.program_idx = UINT32_MAX;
			mat.resource = GodotRealityKit::SGLMaterial::init();
			mark_dirty(p_idx);
			return true;
		}
		return false;
	}

	godot::RID get_rid(uint32_t p_idx) const { return materials[p_idx].material_rid; }

	void remove(uint32_t p_idx) {
		godot::Material *material = materials[p_idx].material.ptr();
		if (material) {
			disconnect_changed(material, p_idx);
		}
		material_rid_to_idx.remove(materials[p_idx].material_rid);
		materials[p_idx].material = nullptr;
		free_idx(p_idx);
	}

	void changed(uint32_t p_idx) {
		update_description(p_idx);
		ResourceLoader<MaterialLoader>::changed(p_idx);
	}

	void update_deps(TextureLoader *p_textures);
	bool update(id<MTLCommandBuffer> p_command_buffer, const TextureLoader *p_textures);
	bool has_programs_loading() const { return program_cache.has_loading(); }

	swift::Optional<GodotRealityKit::SGLMaterial> get_resource(uint32_t p_idx) const {
		const GodotRealityKit::SGLMaterial &resource = materials[p_idx].resource;
		if (const_cast<GodotRealityKit::SGLMaterial &>(resource).isLoading()) {
			return swift::Optional<GodotRealityKit::SGLMaterial>::none();
		}
		return swift::Optional<GodotRealityKit::SGLMaterial>::some(resource);
	}

	swift::Optional<GodotRealityKit::SGLMaterial> find_resource(godot::RID p_material_rid) const {
		ERR_FAIL_COND_V(p_material_rid.is_valid() && !material_rid_to_idx.has(p_material_rid), swift::Optional<GodotRealityKit::SGLMaterial>::none());
		const uint32_t idx = p_material_rid.is_valid() ? material_rid_to_idx.get(p_material_rid) : default_material_idx;
		return get_resource(idx);
	}

	bool is_loading(godot::RID p_material_rid) const {
		// Treat unregistered materials as loading to avoid a missing-RID crash.
		if (!material_rid_to_idx.has(p_material_rid)) {
			return true;
		}
		const uint32_t idx = material_rid_to_idx.get(p_material_rid);
		return materials[idx].is_loading();
	}

	void set_world_scale(float p_world_scale);

	void reset_dirty() {
		ResourceLoader<MaterialLoader>::reset_dirty();
	}

private:
	struct Material {
		godot::RID material_rid;
		uint32_t program_idx = UINT32_MAX;
		ProgramDescription description;
		godot::Ref<godot::Material> material = nullptr;
		GodotRealityKit::SGLMaterial resource = GodotRealityKit::SGLMaterial::init();

		inline bool is_loading() const {
			return program_idx != UINT32_MAX && const_cast<GodotRealityKit::SGLMaterial &>(resource).isLoading();
		}
	};

	struct DependencyState {
		uint32_t texture_hash = 0;
	};

	void update_description(uint32_t p_index);
	void update_constants(const TextureLoader &p_textures, uint32_t p_index);
	void update_parameters(const TextureLoader &p_textures, uint32_t p_index);

	void on_program_loaded(uint32_t program_index);
	void update_default_texture_deps(TextureLoader *p_textures, ChangedDependencyListSet &p_changed_texture_deps, uint32_t p_index, godot::Material *p_material);
	void update_parameter_texture_deps(TextureLoader *p_textures, ChangedDependencyListSet &p_changed_texture_deps, uint32_t p_index, godot::Material *p_material);

private:
	ProgramCache program_cache;
	RID_Associated<uint32_t> material_rid_to_idx;
	godot::LocalVector<Material> materials;
	godot::LocalVector<DependencyState> material_dep_states;
	DependencyList texture_deps;

	godot::Ref<godot::StandardMaterial3D> default_material;
	uint32_t default_material_idx;
	float world_scale = 1.0;
};

} //namespace gdrk
