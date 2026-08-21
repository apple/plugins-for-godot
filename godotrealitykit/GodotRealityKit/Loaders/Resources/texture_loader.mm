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

#include <TargetConditionals.h>

using namespace gdrk;

uint32_t TextureLoader::find_or_add(godot::RID p_texture_rid, godot::Ref<godot::Texture2D> p_texture, TextureUsage p_usage) {
	uint32_t idx = UINT32_MAX;

	if (texture_rid_to_idx.has(p_texture_rid)) {
		idx = texture_rid_to_idx.get(p_texture_rid);
		Texture &texture = textures[idx];

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
			.is_viewport_texture = p_texture.is_valid() && godot::Object::cast_to<godot::ViewportTexture>(p_texture.ptr()) != nullptr,
			.texture_rid = p_texture_rid,
			.texture = p_texture,
		};

		texture_rid_to_idx.insert(p_texture_rid, idx);
	}
	mark_dirty(idx);
	return idx;
}

bool TextureLoader::update(id<MTLCommandBuffer> p_command_buffer) {
	PROFILE_FUNC_SCOPE;

	bool has_pending_usages = false;
	for_each_valid([&](uint32_t idx) {
		if (textures[idx].is_viewport_texture) {
			mark_dirty(idx);
		} else if (textures[idx].dirty_usages != 0) {
			ResourceLoader<TextureLoader>::mark_dirty(idx);
			has_pending_usages = true;
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
				// Render target not yet available (e.g. viewport hasn't rendered its first frame).
				// Leave dirty so we retry next frame.
				return;
			}
			if (existing_rid != rd_texture_rid) {
				if ([src_texture mipmapLevelCount] <= 1) {
					godot::String texture_path = rendering_server()->texture_get_path(texture_rid);
					if (texture_path.is_empty()) {
						texture_path = "<none>";
					}

					WARN_COMPAT_MSG(godot::String(
							"No mipmaps for texture with path {0}. This texture may have aliasing artifacts when viewed on visionOS. "
							"If this is a font atlas consider enabling \"Font Generate Mipmaps\" in your project's settings.")
									.format(godot::Array{ texture_path }));
				}

				NSUInteger texture_usage = [src_texture usage];
#if TARGET_OS_SIMULATOR
				// The copy is sampled, not rendered into; Simulator rejects swizzled render-target textures.
				texture_usage &= ~(MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget);
#endif
				swift::Optional<GodotRealityKit::LowLevelTexture> low_level_texture =
						GodotRealityKit::LowLevelTexture::init([src_texture textureType],
								[src_texture pixelFormat],
								[src_texture width],
								[src_texture height],
								[src_texture depth],
								[src_texture mipmapLevelCount],
								[src_texture arrayLength],
								texture_usage,
								[src_texture swizzle]);

				ERR_FAIL_COND_MSG(low_level_texture.isNone(), "Failed to create low level texture");

				id<MTLTexture> dst_texture = low_level_texture.get().replace(p_command_buffer);
				id<MTLBlitCommandEncoder> blit_encoder = [p_command_buffer blitCommandEncoder];
				[blit_encoder copyFromTexture:src_texture toTexture:dst_texture];
				[blit_encoder endEncoding];

				swift::Optional<GodotRealityKit::TextureResource> resource = GodotRealityKit::TextureResource::init(low_level_texture.get());
				ERR_FAIL_COND(resource.isNone());
				if (usage == TextureUsage::Rendering) {
					texture.resource_srgb = resource;
					texture.rd_texture_srgb_rid = rd_texture_rid;
					ERR_FAIL_COND(texture.resource_srgb.isNone());
				} else {
					texture.resource_linear = resource;
					texture.rd_texture_linear_rid = rd_texture_rid;
					ERR_FAIL_COND(texture.resource_linear.isNone());
				}
			} else if (rd_texture_rid.is_valid()) {
				id<MTLTexture> dst_texture = nil;
				swift::Optional<GodotRealityKit::LowLevelTexture> low_level_texture = swift::Optional<GodotRealityKit::LowLevelTexture>::none();
				if (usage == TextureUsage::Rendering) {
					ERR_FAIL_COND(texture.resource_srgb.isNone());
					dst_texture = texture.resource_srgb.get().lowLevelTexture().get().replace(p_command_buffer);
				} else {
					ERR_FAIL_COND(texture.resource_linear.isNone());
					dst_texture = texture.resource_linear.get().lowLevelTexture().get().replace(p_command_buffer);
				}
				id<MTLBlitCommandEncoder> blit_encoder = [p_command_buffer blitCommandEncoder];
				[blit_encoder copyFromTexture:src_texture toTexture:dst_texture];
				[blit_encoder endEncoding];
			}

			processed_usages |= usage;
		}

		// Downstream materials don't need to update their references to this texture
		// since the resource was updated in-place.
		texture.dirty_usages &= ~processed_usages;
		if (texture.dirty_usages == 0) {
			dirty_idxs.remove(idx);
		} else {
			has_pending_usages = true;
		}
	});

	return throttle_finished && !has_pending_usages;
}
