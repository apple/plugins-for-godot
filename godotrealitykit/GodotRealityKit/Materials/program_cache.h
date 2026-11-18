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

#ifndef BASE_MATERIAL_GEN_H
#define BASE_MATERIAL_GEN_H

// clang-format off
#import "GodotRealityKit.h"
#import "GodotRealityKit-Swift.h"
// clang-format on

#include "material_bridge.h"
#include "program_description.h"
#include "utility.h"

#undef check
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/local_vector.hpp>

#define MATERIAL_EXPORT_DIRECTORY "res://.godot/gdrk/materials"

namespace gdrk {

class TextureLoader;

class ProgramCache {
public:
	enum LoadingMode : uint8_t {
		DEFAULT = 0,
		FORCE_CACHE,
		DISABLE_CACHE,
	};

	using ProgramLoadedCallback = std::function<void(uint32_t)>;
	ProgramCache(ProgramLoadedCallback &&callback, const char *p_export_directory = MATERIAL_EXPORT_DIRECTORY);

	uint32_t create_program_async(const ProgramDescription &p_material_description);

	void preload_program(godot::String p_path);
	bool is_program_loading(uint32_t p_idx) const { return program_loading_idxs.has(p_idx); }
	bool has_loading() const { return program_loading_idxs.count() > 0; }
	uint32_t base_program_count() const { return base_programs.size(); }
	uint32_t program_count() const { return programs.size(); }

	GodotRealityKit::SGLMaterial create_material(uint32_t p_program_idx);

	void update();
	inline const ProgramDescription &get_description(uint32_t idx) const {
		return programs[idx].description;
	}

	void set_loading_mode(LoadingMode p_mode) { loading_mode = p_mode; }
	uint32_t create_broken_program_async();
	void reset();

	TESTABLE();

private:
	struct Program {
		GodotRealityKit::SGLProgram value = GodotRealityKit::SGLProgram::init();
		ProgramDescription description;
	};

	struct BaseProgram {
		GodotRealityKit::SGLProgram value = GodotRealityKit::SGLProgram::init();
		ProgramDescription description;
	};

	godot::String read_file(godot::String p_path) const;
	godot::String read_from_cache(godot::String p_path) const;

	bool load_cached_visual_shader(uint32_t p_base_program_index, ShaderMaterialDescription &p_program_description);
	bool preload_base_program(const ProgramDescription &p_program_description);
	template <MaterialType MT>
	bool create_program_async(uint32_t p_base_program_idx, ProgramDescription &p_program_description);

	void load_usda(uint32_t p_base_program_idx, swift::String &content);
	bool make_usda(uint32_t p_base_program_idx, const swift::Array<GodotRealityKit::ProgramPart> &p_program_parts);
	bool load_usda_from_file(uint32_t p_base_program_idx, godot::String p_resource_path);

	uint32_t alloc_variant(const ProgramDescription &p_desc);
	void finalize_pending_variants(uint32_t p_base_idx);
	void finalize_variant(uint32_t p_variant_idx, uint32_t p_base_idx);

	friend typename ::GDRKMaterialLoadDelegate;

	std::optional<GodotRealityKit::ProgramPart> parse_snippet(const swift::String &p_source);

	godot::HashMap<uint32_t, uint32_t> program_description_to_idx;
	godot::LocalVector<Program> programs;
	LocalBitVector program_loading_idxs;

	godot::HashMap<uint32_t, uint32_t> base_program_hash_to_base_idx;
	godot::LocalVector<BaseProgram> base_programs;
	godot::LocalVector<ProgramDescription> base_programs_descriptions;
	LocalBitVector base_loading_idxs;
	godot::HashMap<uint32_t, godot::LocalVector<uint32_t>> loading_variants;

	godot::HashMap<uint64_t, GodotRealityKit::ProgramPart> snippet_cache;
	swift::Optional<GodotRealityKit::Compiler> compiler;
	ProgramLoadedCallback notify_program_loaded;

	godot::LocalVector<godot::Ref<godot::Resource>> preloaded_materials;

	uint32_t broken_material_index = UINT32_MAX;
	godot::String export_directory;
	LoadingMode loading_mode = LoadingMode::DEFAULT;
};

} // namespace gdrk

#endif // BASE_MATERIAL_GEN_H
