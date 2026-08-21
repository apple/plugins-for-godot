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

#include "texture_loader.h"
#include "signposts.h"

using namespace gdrk;

uint32_t TextureLoader::find_or_add(godot::RID p_texture_rid, godot::Ref<godot::Texture2D> p_texture, TextureUsage p_usage, bool p_requires_godot_frame) {
	uint32_t idx = UINT32_MAX;
	const bool is_viewport_texture =
			p_texture.is_valid() && godot::Object::cast_to<godot::ViewportTexture>(p_texture.ptr()) != nullptr;
	const bool requires_godot_frame = p_requires_godot_frame || is_viewport_texture;
	const uint8_t godot_frame_usages = requires_godot_frame ? p_usage : 0;

	if (texture_rid_to_idx.has(p_texture_rid)) {
		idx = texture_rid_to_idx.get(p_texture_rid);
		Texture &texture = textures[idx];
		// Track frame-produced usages separately so unrelated pending usages still block.
		texture.godot_frame_usages |= godot_frame_usages;

		if (texture.ready_for(p_usage)) {
			return idx;
		}

		texture.required_usages |= p_usage;
		texture.dirty_usages |= p_usage;
	} else {
		idx = alloc_idx();

		if (p_texture.is_valid()) {
			connect_changed(p_texture.ptr(), idx);
		}

		textures[idx] = Texture{
			.required_usages = p_usage,
			.dirty_usages = p_usage,
			.godot_frame_usages = godot_frame_usages,
			.is_viewport_texture = is_viewport_texture,
			.texture_rid = p_texture_rid,
			.texture = p_texture,
		};

		texture_rid_to_idx.insert(p_texture_rid, idx);
	}
	mark_dirty(idx);
	return idx;
}

bool TextureLoader::update(id<MTLCommandBuffer> p_command_buffer, bool &r_needs_godot_frame) {
	PROFILE_FUNC_SCOPE;

	bool has_pending_usages = false;
	bool has_blocking_pending_usages = false;
	for_each_valid([&](uint32_t idx) {
		if (textures[idx].is_viewport_texture) {
			mark_dirty(idx);
		} else if (textures[idx].dirty_usages != 0) {
			ResourceLoader<TextureLoader>::mark_dirty(idx);
		}
	});

	bool throttle_finished = for_each_dirty_throttled([&](uint32_t idx) {
		Texture &texture = textures[idx];
		const godot::RID texture_rid = texture.texture_rid;
		ERR_FAIL_COND(!texture_rid.is_valid());

		// A single godot::Texture2D can be bound as MTLPixelFormatR8Unorm or MTLPixelFormatR8Unorm_sRGB
		// RealityKit LowLevelTextures don't support Texture View for native color space conversion
		// To account for that, we store 2 versions for each purpose:
		//	 	- Rendering: Values are in sRGB space, this will automatically be converted in linear space the shader
		// 		- Compute: Values are already in linear space: this is mostly used for data texture
		// Having an extra texture is not a big deal, as it probably will rarely happen to use the texture for both
		// compute and rendering.
		// When calling find_or_add or find, the caller need to provide the usage (Rendering or Compute) based on their
		// internal knowledge of the use of the texture.
		uint8_t processed_usages = 0;
		for (TextureUsage usage : { TextureUsage::Rendering, TextureUsage::Compute }) {
			if (!(usage & texture.dirty_usages)) {
				continue;
			}

			// We assume that if the RD texture RID hasn't changed, then the underlying image size/format hasn't changed
			const godot::RID rd_texture_rid = rendering_server()->texture_get_rd_texture(texture_rid, usage == TextureUsage::Rendering);
			if (!rd_texture_rid.is_valid()) {
				continue;
			}
			const godot::RID existing_rid = usage == TextureUsage::Rendering ? texture.rd_texture_srgb_rid : texture.rd_texture_linear_rid;
			const uint64_t mtl_texture_u64 = rendering_device()->get_driver_resource(godot::RenderingDevice::DRIVER_RESOURCE_TEXTURE, rd_texture_rid, 0);
			if (mtl_texture_u64 == 0) {
				continue;
			}
			id<MTLTexture> src_texture = (__bridge id<MTLTexture>)(void *)mtl_texture_u64;
			if (src_texture == nil) {
				// Retry temporary unavailability instead of stalling generated textures.
				continue;
			}
			const bool recreate_resource = existing_rid != rd_texture_rid ||
					((texture.godot_frame_usages & usage) && !texture.is_viewport_texture);
			if (recreate_resource) {
				if (existing_rid != rd_texture_rid && [src_texture mipmapLevelCount] <= 1) {
					godot::String texture_path = rendering_server()->texture_get_path(texture_rid);
					if (texture_path.is_empty()) {
						texture_path = "<none>";
					}

					WARN_COMPAT_MSG(godot::String(
							"No mipmaps for texture with path {0}. This texture may have aliasing artifacts when viewed on visionOS. "
							"If this is a font atlas consider enabling \"Font Generate Mipmaps\" in your project's settings.")
									.format(godot::Array{ texture_path }));
				}

				// A regenerated atlas may keep its RID while changing its backing texture.
				swift::Optional<GodotRealityKit::LowLevelTexture> low_level_texture =
						GodotRealityKit::LowLevelTexture::init([src_texture textureType],
								[src_texture pixelFormat],
								[src_texture width],
								[src_texture height],
								[src_texture depth],
								[src_texture mipmapLevelCount],
								[src_texture arrayLength],
								[src_texture usage],
								[src_texture swizzle]);

				// Keep transient creation failures pending instead of stalling the loader.
				if (low_level_texture.isNone()) {
					ERR_PRINT("Failed to create low level texture");
					continue;
				}

				id<MTLTexture> dst_texture = low_level_texture.get().replace(p_command_buffer);
				id<MTLBlitCommandEncoder> blit_encoder = [p_command_buffer blitCommandEncoder];
				[blit_encoder copyFromTexture:src_texture toTexture:dst_texture];
				[blit_encoder endEncoding];

				swift::Optional<GodotRealityKit::TextureResource> resource = GodotRealityKit::TextureResource::init(low_level_texture.get());
				if (resource.isNone()) {
					// Retry resource creation instead of aborting the texture pass.
					ERR_PRINT("Failed to create texture resource");
					continue;
				}
				if (usage == TextureUsage::Rendering) {
					texture.resource_srgb = resource;
					texture.rd_texture_srgb_rid = rd_texture_rid;
				} else {
					texture.resource_linear = resource;
					texture.rd_texture_linear_rid = rd_texture_rid;
				}
			} else if (rd_texture_rid.is_valid()) {
				id<MTLTexture> dst_texture = nil;
				swift::Optional<GodotRealityKit::LowLevelTexture> low_level_texture = swift::Optional<GodotRealityKit::LowLevelTexture>::none();
				// Missing resources stay pending instead of aborting the texture pass.
				if (usage == TextureUsage::Rendering) {
					if (texture.resource_srgb.isNone()) {
						ERR_PRINT("Missing rendering texture resource");
						continue;
					}
					dst_texture = texture.resource_srgb.get().lowLevelTexture().get().replace(p_command_buffer);
				} else {
					if (texture.resource_linear.isNone()) {
						ERR_PRINT("Missing compute texture resource");
						continue;
					}
					dst_texture = texture.resource_linear.get().lowLevelTexture().get().replace(p_command_buffer);
				}
				id<MTLBlitCommandEncoder> blit_encoder = [p_command_buffer blitCommandEncoder];
				[blit_encoder copyFromTexture:src_texture toTexture:dst_texture];
				[blit_encoder endEncoding];
			}

			processed_usages |= usage;
		}

		// Materials update next and pick up the replacement resource.
		texture.dirty_usages &= ~processed_usages;
		if (texture.dirty_usages == 0) {
			dirty_idxs.remove(idx);
		} else {
			has_pending_usages = true;
			has_blocking_pending_usages |= (texture.dirty_usages & ~texture.godot_frame_usages) != 0;
		}
	});

	// Advance Godot for frame-dependent textures to avoid a circular wait.
	r_needs_godot_frame = throttle_finished && has_pending_usages && !has_blocking_pending_usages;
	return throttle_finished && !has_pending_usages;
}
