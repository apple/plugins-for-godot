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

#include "skybox_loader.h"
#include "scene_tree.h"
#include "signposts.h"

#include <godot_cpp/classes/panorama_sky_material.hpp>
#include <godot_cpp/classes/sky.hpp>

#include "../Util/cgimage_util.h"

using namespace gdrk;

uint32_t SkyboxLoader::find_or_add(godot::RID p_env_rid, godot::Ref<godot::Environment> p_env) {
	if (environment_rid_to_idx.has(p_env_rid)) {
		return environment_rid_to_idx.get(p_env_rid);
	}

	const uint32_t idx = alloc_idx();

	if (p_env.is_valid()) {
		connect_changed(p_env.ptr(), idx);
	}

	skyboxes[idx] = Skybox{
		.environment = p_env
	};

	environment_rid_to_idx.insert(p_env_rid, idx);
	mark_dirty(idx);
	return idx;
}

bool SkyboxLoader::update(id<MTLCommandBuffer> p_command_buffer) {
	PROFILE_FUNC_SCOPE;

	const auto &settings = get_scene_tree()->get_extension_settings();
	if (!settings.should_convert_skybox()) {
		// Nothing to load when the skybox cannot be seen.
		// Returning false here would keep SceneLoader::update bailing before it
		// can tear down the boot-splash UIScene, leaving the app stuck on the
		// loading view ().
		return true;
	}

	return for_each_dirty_throttled([&](uint32_t idx) {
		if (!is_used_in_frame(idx)) {
			return LocalBitVector::IterationResult::SKIPPED;
		}
		godot::Ref<godot::Environment> env = skyboxes[idx].environment;
		const godot::RID env_rid = env->get_rid();
		ERR_FAIL_COND_V((!env_rid.is_valid()), LocalBitVector::IterationResult::SKIPPED);

		godot::Environment::BGMode bg_mode = env->get_background();
		switch (bg_mode) {
			case godot::Environment::BGMode::BG_COLOR: {
				godot::Color color = env->get_bg_color();
				CGFloat components[4] = {
					(CGFloat)color.r,
					(CGFloat)color.g,
					(CGFloat)color.b,
					(CGFloat)color.a
				};
				CGColorRef cgcolor = CGColorCreate(CGColorSpaceCreateWithName(kCGColorSpaceGenericRGBLinear), components);
				gdrk::emplace_replace(&skyboxes[idx].skybox, GodotRealityKit::Skybox::fromCGColor(cgcolor));
				CGColorRelease(cgcolor);
				break;
			}
			case godot::Environment::BGMode::BG_SKY: {
				godot::Sky *sky = *env->get_sky();

				godot::Texture2D *panorama = nullptr;

				// Checking for image textures
				if (godot::PanoramaSkyMaterial *mat = godot::Object::cast_to<godot::PanoramaSkyMaterial>(*sky->get_material())) {
					if (godot::Texture2D *texture = *mat->get_panorama()) {
						panorama = texture;
					}
				}

				if (panorama) {
					const godot::RID texture_rid = panorama->get_rid();
					const godot::RID rd_texture_rid = rendering_server()->texture_get_rd_texture(texture_rid, true);
					const uint64_t mtl_texture_u64 = rendering_device()->get_driver_resource(godot::RenderingDevice::DRIVER_RESOURCE_TEXTURE, rd_texture_rid, 0);
					id<MTLTexture> src_texture = (__bridge id<MTLTexture>)(void *)mtl_texture_u64;

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

					ERR_FAIL_COND_V_MSG(low_level_texture.isNone(), LocalBitVector::IterationResult::SKIPPED, "Failed to create low level texture");

					id<MTLTexture> dst_texture = low_level_texture.get().replace(p_command_buffer);
					id<MTLBlitCommandEncoder> blit_encoder = [p_command_buffer blitCommandEncoder];
					[blit_encoder copyFromTexture:src_texture toTexture:dst_texture];
					[blit_encoder endEncoding];

					swift::Optional<GodotRealityKit::TextureResource> resource = GodotRealityKit::TextureResource::init(low_level_texture.get());

					if (resource.isSome()) {
						gdrk::emplace_replace(&skyboxes[idx].skybox, GodotRealityKit::Skybox::fromTextureResource(resource.getSome()));
					}
				} else {
					godot::Vector2i size = godot::Vector2i(2048, 1024);
					godot::Ref<godot::Image> image = rendering_server()->sky_bake_panorama(sky->get_rid(), 1.0, false, size);
					CGImageRef cgimage = cgimage_from_godot_image(image);
					gdrk::emplace_replace(&skyboxes[idx].skybox, GodotRealityKit::Skybox::fromCGImage(cgimage));
					CGImageRelease(cgimage);
				}
				break;
			}
			case godot::Environment::BGMode::BG_CLEAR_COLOR:
			default: {
				gdrk::emplace_replace(&skyboxes[idx].skybox, GodotRealityKit::Skybox::init());
				break;
			}
		}
		return LocalBitVector::IterationResult::PROCESSED;
	});
}
