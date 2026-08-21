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

#include "resource_loader.h"

#include <godot_cpp/classes/viewport_texture.hpp>

namespace gdrk {

class TextureLoader : public ResourceLoader<TextureLoader> {
	GDCLASS(TextureLoader, Object);

protected:
	static void _bind_methods() {}

public:
	enum TextureUsage : uint8_t {
		Rendering = 0b01, // uses MTLPixelFormatR8Unorm_sRGB Texture View
		Compute = 0b10, // uses MTLPixelFormatR8Unorm Texture View
	};

	void _reserve(uint32_t p_capacity) {
		ResourceLoader<TextureLoader>::_reserve(p_capacity);
		textures.resize(p_capacity);
	}

	uint32_t find_or_add(godot::RID p_texture_rid, godot::Ref<godot::Texture2D> p_texture = nullptr, TextureUsage p_usage = TextureUsage::Rendering, bool p_requires_godot_frame = false);

	void remove(uint32_t p_idx) {
		texture_rid_to_idx.remove(textures[p_idx].texture_rid);
		godot::Texture2D *texture = textures[p_idx].texture.ptr();
		if (texture) {
			disconnect_changed(texture, p_idx);
		}

		textures[p_idx] = Texture();
		free_idx(p_idx);
	}

	void mark_dirty(uint32_t p_idx) {
		ResourceLoader<TextureLoader>::mark_dirty(p_idx);
		textures[p_idx].dirty_usages = textures[p_idx].required_usages;
	}

	bool update(id<MTLCommandBuffer> p_command_buffer, bool &r_needs_godot_frame);

	swift::Optional<GodotRealityKit::TextureResource> find_resource(godot::RID p_texture_rid, TextureUsage p_usage = TextureUsage::Rendering) const {
		if (!p_texture_rid.is_valid()) {
			return swift::Optional<GodotRealityKit::TextureResource>::none();
		}

		ERR_FAIL_COND_V(!texture_rid_to_idx.has(p_texture_rid), swift::Optional<GodotRealityKit::TextureResource>::none());
		const uint32_t idx = texture_rid_to_idx.get(p_texture_rid);
		return textures[idx].get_resource_for(p_usage);
	}

private:
	struct Texture {
		uint8_t required_usages;
		uint8_t dirty_usages;
		uint8_t godot_frame_usages = 0;
		bool is_viewport_texture = false;

		godot::RID texture_rid;

		godot::Ref<godot::Texture2D> texture;
		godot::RID rd_texture_linear_rid;
		swift::Optional<GodotRealityKit::TextureResource> resource_linear = swift::Optional<GodotRealityKit::TextureResource>::none();
		godot::RID rd_texture_srgb_rid;
		swift::Optional<GodotRealityKit::TextureResource> resource_srgb = swift::Optional<GodotRealityKit::TextureResource>::none();

		inline bool ready_for(TextureUsage p_usage) const {
			return required_usages & p_usage;
		}

		inline swift::Optional<GodotRealityKit::TextureResource> get_resource_for(TextureUsage p_usage) const {
			return p_usage == TextureUsage::Rendering ? resource_srgb : resource_linear;
		}
	};

	RID_Associated<uint32_t> texture_rid_to_idx;
	godot::LocalVector<Texture> textures;
};

} //namespace gdrk
