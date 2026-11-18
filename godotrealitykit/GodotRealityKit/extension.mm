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

#include <cstring>
#include <type_traits>

#import "clipping_3d.h"
#import "controller_xr_interface.h"
#import "directional_light_shadow_3d.h"
#import "environment_lighting_configuration.h"
#import "hover_effect_3d.h"
#import "image_based_light_3d.h"
#import "input_events.h"
#import "node_loaders.h"
#import "portal_mesh_instance_3d.h"
#import "resource_loaders.h"
#import "scene_tree.h"
#import "volume_camera_3d.h"

#if TESTING_ENABLED
#include "Tests/Common/GodotXCTestNode.h"
#endif

#include "Materials/exporter.h"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/xr_interface.hpp>
#include <godot_cpp/classes/xr_server.hpp>

#if !TARGET_OS_OSX
#include "Loaders/Util/cgimage_util.h"
#endif

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include "extension.h"
namespace gdrk {

void install_renderer_relaunch_guard();

void initialize_gdrk_module(godot::ModuleInitializationLevel p_level) {
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();

	if (p_level == godot::MODULE_INITIALIZATION_LEVEL_SERVERS) {
		// This is a setting required by all Godot visionOS projects, so we set it for convenience here
		project_settings->set_setting("rendering/textures/vram_compression/import_etc2_astc", true);

		install_renderer_relaunch_guard();
	}

	if (p_level == godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_RUNTIME_CLASS(RealitySceneTree);
		GDREGISTER_RUNTIME_CLASS(TextureLoader);
		GDREGISTER_RUNTIME_CLASS(EnvironmentLoader);
		GDREGISTER_RUNTIME_CLASS(SkyboxLoader);
		GDREGISTER_RUNTIME_CLASS(MaterialLoader);
		GDREGISTER_RUNTIME_CLASS(MeshLoader);
		GDREGISTER_RUNTIME_CLASS(MultiMeshLoader);
		GDREGISTER_RUNTIME_CLASS(ShapeLoader);
		GDREGISTER_RUNTIME_CLASS(NodeLoaders);
		GDREGISTER_RUNTIME_CLASS(RealityControllerXRInterface);
		GDREGISTER_CLASS(GodotRealityKit);
		GDREGISTER_CLASS(RealityVolumeCamera3D);
		GDREGISTER_CLASS(RealityHoverEffect3D);
		GDREGISTER_CLASS(RealityClipping3D);
		GDREGISTER_CLASS(RealityPortalMeshInstance3D);
		GDREGISTER_CLASS(RealityPortalCrossing3D);
		GDREGISTER_CLASS(RealityImageBasedLight3D);
		GDREGISTER_CLASS(RealityKitDirectionalLightShadow3D);
		GDREGISTER_CLASS(RealityKitEnvironmentLightingConfiguration);
		GDREGISTER_CLASS(InputEventSpatialTouch);
		GDREGISTER_CLASS(InputEventSpatialDrag);

#if TESTING_ENABLED
		godot::print_line("Testing enabled: Registering GodotXCTestNode");
		GDREGISTER_RUNTIME_CLASS(testing::GodotXCTestNode);
#endif
	}

	if (p_level == godot::MODULE_INITIALIZATION_LEVEL_EDITOR) {
		GDREGISTER_CLASS(MaterialEditorExportPlugin);
	}
}

void uninitialize_gdrk_module(godot::ModuleInitializationLevel p_level) {
	if (p_level == godot::MODULE_INITIALIZATION_LEVEL_EDITOR) {
	}
}

void main_loop_frame() {
	godot::Engine *engine = godot::Engine::get_singleton();
	godot::MainLoop *main_loop = engine->get_main_loop();
	RealitySceneTree *reality_scene_tree = godot::Object::cast_to<RealitySceneTree>(main_loop);
	if (!reality_scene_tree || !reality_scene_tree->get_loader()) {
		return;
	}

	SceneLoader *loader = reality_scene_tree->get_loader();

	for (const godot::String &path : GodotRealityKit::preloading_materials) {
		loader->get_materials()->preload(path);
	}
	GodotRealityKit::preloading_materials.reset();

	loader->update();
}

godot::LocalVector<godot::String> GodotRealityKit::preloading_materials;

void GodotRealityKit::_bind_methods() {
	godot::ClassDB::bind_static_method("GodotRealityKit", godot::D_METHOD("preload_material", "path"), &GodotRealityKit::preload_material);
}

void GodotRealityKit::preload_material(godot::String p_path) {
	preloading_materials.push_back(p_path);
}

} // namespace gdrk

GDRKTransform GDRKTransform::identity = GDRKTransform{
	.scale = simd_make_float3(1.0f, 1.0f, 1.0f),
	.position = simd_make_float3(0.0f, 0.0f, 0.0f),
	.orientation = simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f)
};

void GDRKBridgeDelegate::printError(const char *p_msg) {
	ERR_PRINT(p_msg);
}

void GDRKBridgeDelegate::printWarning(const char *p_msg) {
	WARN_PRINT(p_msg);
}

bool GDRKBridgeDelegate::ExtensionSettings::should_convert_world_environment() const {
	switch (world_environment) {
		case WorldEnvironmentConversion::kEnable:
			return true;
		case WorldEnvironmentConversion::kDisable:
			return false;
		case WorldEnvironmentConversion::kAutomatic:
#if TARGET_OS_OSX
			return true; // no AR lighting on macOS; use the virtual IBL
#else
			switch (presentationStyle) {
				case PresentationStyle::kVolumetricWindow:
					return false; // Windows should receive AR lighting by default, from the OS.
				case PresentationStyle::kVolumetricPortal:
					return true; // Scenes in Portals should receive use the virtual IBL.
				case PresentationStyle::kImmersive:
					// TODO: use IBL in full and progressive mode; but not in mixed mode
					return true; // Fully immersive scene should use the virtual IBl.
			}
#endif
	}
}

bool GDRKBridgeDelegate::ExtensionSettings::should_convert_skybox() const {
	if (!should_convert_world_environment()) {
		return false;
	}

	// Mixed/progressive immersion shows passthrough behind the scene.
	if (presentationStyle == kImmersive && immersionStyle != kFull) {
		return false;
	}

#if !TARGET_OS_OSX
	if (presentationStyle == kVolumetricWindow) {
		return false;
	}
#endif

	return true;
}

GDRKBridgeDelegate::ExtensionSettings GDRKBridgeDelegate::getExtensionSettings() const {
	static bool fetched = false;
	static GDRKBridgeDelegate::ExtensionSettings cached;
	if (!fetched) {
		fetched = true;
		godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();

		// Game controller events
		{
			bool value = true;
			const auto key = "reality_kit/handles_game_controller_events";
			if (project_settings->has_setting(key)) {
				value = project_settings->get_setting(key).booleanize();
			}
			cached.handlesGameControllerEvents = value;
		}

		// Presentation style
		{
			godot::String value = "Volumetric Window";
			godot::String key = "reality_kit/presentation_style";
			if (project_settings->has_setting(key)) {
				value = project_settings->get(key).stringify();
			}
			if (value == "Volumetric Window") {
				cached.presentationStyle = PresentationStyle::kVolumetricWindow;
			} else if (value == "Portal Window") {
				cached.presentationStyle = PresentationStyle::kVolumetricPortal;
			} else if (value == "Immersive") {
				cached.presentationStyle = PresentationStyle::kImmersive;
			} else {
				printf("Unsupported presentation style \"%s\"\n", value.utf8().ptr());
				cached.presentationStyle = PresentationStyle::kVolumetricWindow;
			}
		}

		// Immersion style
		{
			godot::String value = "Mixed";
			const auto key = "reality_kit/immersion_style";
			if (project_settings->has_setting(key)) {
				value = project_settings->get(key).stringify();
			}
			if (value == "Mixed") {
				cached.immersionStyle = ImmersionStyle::kMixed;
			} else if (value == "Full") {
				cached.immersionStyle = ImmersionStyle::kFull;
			} else if (value == "Progressive") {
				cached.immersionStyle = ImmersionStyle::kProgressive;
			} else {
				printf("Unsupported reality_kit/immersion_style \"%s\"\n", value.utf8().ptr());
				cached.immersionStyle = ImmersionStyle::kFull;
			}
		}

		// World Environment conversion
		{
			godot::String value = "Automatic";
			const auto key = "reality_kit/world_environment";
			if (project_settings->has_setting(key)) {
				value = project_settings->get(key).stringify();
			}
			if (value == "Automatic") {
				cached.world_environment = WorldEnvironmentConversion::kAutomatic;
			} else if (value == "Enable") {
				cached.world_environment = WorldEnvironmentConversion::kEnable;
			} else if (value == "Disable") {
				cached.world_environment = WorldEnvironmentConversion::kDisable;
			} else {
				printf("Unsupported reality_kit/world_environment \"%s\"\n", value.utf8().ptrw());
				cached.world_environment = WorldEnvironmentConversion::kAutomatic;
			}
		}

		// Portal world scale
		{
			float value = 0.0f;
			const auto key = "reality_kit/portal_presentation_world_scale";
			if (project_settings->has_setting(key)) {
				value = (float)project_settings->get_setting(key);
			}
			cached.portalWorldScale = value;
		}
	}
	return cached;
}

godot::Vector3 convert(simd_float3 value) {
	return godot::Vector3(value.x, value.y, value.z);
}

godot::Quaternion convert(simd_quatf value) {
	simd_float4 vector = value.vector;
	return godot::Quaternion(vector.x, vector.y, vector.z, vector.w);
}

static godot::Object *phase_manager = nullptr;

void GDRKBridgeDelegate::initialize_phase_manager() const {
	godot::SceneTree *scene_tree = gdrk::get_scene_tree();

	godot::Node *singleton = scene_tree->get_root()->get_node_or_null("PhaseManagerSingleton");

	if (singleton == nullptr) {
		printf("GodotRealityKit: PHASE on visionOS not detected. No need to synchronize transforms with GodotRealityKit.\n");
		return;
	}

	godot::Variant variant = singleton->get("phase_manager");
	if (!variant) {
		ERR_PRINT_ONCE("GodotRealityKit: phase_manager not found on PhaseManagerSingleton.");
		return;
	}
	if (variant.get_type() != godot::Variant::Type::OBJECT) {
		ERR_PRINT_ONCE("GodotRealityKit: phase_manager is not an object.");
		return;
	}

	godot::Object *manager = variant.get_validated_object();
	if (!manager->has_method("set_world_transform")) {
		ERR_PRINT_ONCE("GodotRealityKit: phase_manager not found on PhaseManagerSingleton.");
		return;
	}

	phase_manager = manager;

	printf("GodotRealityKit: PHASE on visionOS detected: synchronizing transforms.\n");
}

void GDRKBridgeDelegate::setPHASETransform(GDRKTransform gdrk_transform) const {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		initialize_phase_manager();
	});

	if (phase_manager == nullptr) {
		return;
	}

	godot::Transform3D transform;
	transform.origin = convert(gdrk_transform.position);
	transform.basis.set_quaternion(convert(gdrk_transform.orientation));
	transform.basis.scale(convert(gdrk_transform.scale));
	// godotphase's transform_to_simd_float4x4 treats Godot basis rows as SIMD
	// columns, which transposes the rotation. Pre-transpose to compensate.
	transform.basis.transpose();
	phase_manager->call("set_world_transform", transform);
}

#if TARGET_OS_OSX
NSWindow *GDRKBridgeDelegate::getDisplayServerWindow() const {
	godot::DisplayServer *display_server = godot::DisplayServer::get_singleton();
	const uint64_t window_u64 = display_server->window_get_native_handle(godot::DisplayServer::WINDOW_HANDLE);
	return (__bridge NSWindow *)(void *)window_u64;
}
#else
UIViewController *GDRKBridgeDelegate::getDisplayServerViewController() const {
	godot::DisplayServer *display_server = godot::DisplayServer::get_singleton();
	const uint64_t view_controller_u64 = display_server->window_get_native_handle(godot::DisplayServer::WINDOW_HANDLE);
	UIViewController *view_controller = (__bridge UIViewController *)(void *)view_controller_u64;
	return view_controller;
}

UIImage *GDRKBridgeDelegate::getBootSplashImage() const {
	godot::ProjectSettings *ps = godot::ProjectSettings::get_singleton();

	bool show_image = ps->get_setting("application/boot_splash/show_image", true);
	if (!show_image) {
		return nil;
	}

	godot::Ref<godot::Image> image;
	image.instantiate();

	godot::String image_path = ps->get_setting("application/boot_splash/image", "");
	if (image_path.is_empty()) {
		// Mirror upstream Godot's setup_boot_logo() fallback: when no custom
		// boot splash is set, render the default Godot splash baked into the binary.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc++11-narrowing"
		static constexpr unsigned char default_splash_png[] = {
#embed "splash.png"
		};
#pragma clang diagnostic pop
		godot::PackedByteArray buffer;
		buffer.resize(sizeof(default_splash_png));
		memcpy(buffer.ptrw(), default_splash_png, sizeof(default_splash_png));
		if (image->load_png_from_buffer(buffer) != godot::OK) {
			return nil;
		}
	} else if (image->load(image_path) != godot::OK) {
		return nil;
	}

	image->convert(godot::Image::FORMAT_RGBAF);
	CGImageRef cg_image = gdrk::cgimage_from_godot_image(image);
	UIImage *ui_image = [UIImage imageWithCGImage:cg_image];
	CGImageRelease(cg_image);
	return ui_image;
}

UIColor *GDRKBridgeDelegate::getBootSplashBgColor() const {
	godot::ProjectSettings *ps = godot::ProjectSettings::get_singleton();
	godot::Color color = godot::Color(ps->get_setting("application/boot_splash/bg_color", godot::Color(0.14, 0.14, 0.14)));
	return [UIColor colorWithRed:color.r green:color.g blue:color.b alpha:color.a];
}
#endif

void *GDRKBridgeDelegate::getCameraEntity() const {
	return loader->get_nodes()->get_cameras().get_current_entity().getRawPointer();
}

void GDRKBridgeDelegate::onWorldScaleChanged(float p_scale) const {
	loader->get_materials()->set_world_scale(p_scale);
	loader->get_nodes()->get_directional_lights().set_world_scale(p_scale);
	loader->get_nodes()->get_point_lights().set_world_scale(p_scale);
	loader->get_nodes()->get_spot_lights().set_world_scale(p_scale);
}

void GDRKBridgeDelegate::onExtraLightFrustumScaleChanged(float p_scale) const {
	loader->get_nodes()->get_directional_lights().set_extra_light_frustum_scale(p_scale);
}

#if TARGET_OS_OSX
void GDRKBridgeDelegate::onWindowResized(simd_float2 p_new_size) const {
	loader->set_viewport_size(godot::Vector3(p_new_size.x, p_new_size.y, 1024.0));
}
#else
void GDRKBridgeDelegate::onWindowResized(simd_float3 p_new_size) const {
	loader->set_viewport_size(gdrk::from_simd3(p_new_size));
}
#endif

void GDRKBridgeDelegate::onEntityPressUpdate(int64_t p_event_id,
		bool p_ended,
		uint64_t p_entity_id,
		simd_float3 p_position,
		simd_float3 p_hit_position,
		simd_float3 p_hit_normal,
		int64_t p_hit_shape_idx,
		bool p_has_input_device_pose,
		GDRKPose p_input_device_pose,
		bool p_has_selection_ray,
		GDRKRay p_selection_ray,
		bool p_has_chirality,
		uint32_t p_chirality) const {
	uint32_t cur_press_idx = 0;
	bool is_first_press = true;
	for (uint32_t press_idx = 0; press_idx < loader->max_active_presses; press_idx++) {
		if (loader->active_presses[press_idx] == p_event_id) {
			is_first_press = false;
			cur_press_idx = press_idx;
			break;
		}
	}

	if (is_first_press) {
		cur_press_idx = loader->next_active_press_idx;
		loader->next_active_press_idx = (loader->next_active_press_idx + 1) % loader->max_active_presses;
		loader->active_presses[cur_press_idx] = p_event_id;
	}

	godot::Node3D *camera = loader->get_nodes()->get_cameras().get_current_node();
	if (!camera) {
		WARN_COMPAT_MSG("Spatial input event recieved but no volumetric camera found in scene");
	}

	simd_float2 location = simd_make_float2(0.0f, 0.0f);
	if (godot::Camera3D *camera_3d = godot::Object::cast_to<godot::Camera3D>(camera)) {
		location = gdrk::to_simd2(camera_3d->unproject_position(gdrk::from_simd3(p_hit_position)));
	} else if (gdrk::RealityVolumeCamera3D *volume_camera_3d = godot::Object::cast_to<gdrk::RealityVolumeCamera3D>(camera)) {
		location = gdrk::to_simd2(volume_camera_3d->unproject_position(gdrk::from_simd3(p_hit_position)));
	}

	godot::Node *node = loader->get_nodes()->find_node(p_entity_id);

	godot::Ref<godot::InputEventFromWindow> input_event;
	if (is_first_press || p_ended) {
		godot::Ref<gdrk::InputEventSpatialTouch> touch_event;
		touch_event.instantiate();

		touch_event->set_index(int32_t(p_event_id));
		touch_event->set_pressed(!p_ended);
		touch_event->set_position(gdrk::from_simd2(location));
		touch_event->set_world_position(gdrk::from_simd3(p_position));
		touch_event->set_double_tap(false);

		touch_event->set_flag(gdrk::InputEventSpatialTouch::FLAG_HAS_SELECTION_RAY, p_has_selection_ray);
		touch_event->set_flag(gdrk::InputEventSpatialTouch::FLAG_HAS_INPUT_DEVICE_POSE, p_has_input_device_pose);
		touch_event->set_flag(gdrk::InputEventSpatialTouch::FLAG_HAS_CHIRALITY, p_has_chirality);

		touch_event->set_selection_ray_origin(gdrk::from_simd3(p_selection_ray.origin));
		touch_event->set_selection_ray_direction(gdrk::from_simd3(p_selection_ray.direction));

		touch_event->set_input_device_pose_position(gdrk::from_simd3(p_input_device_pose.position));
		touch_event->set_input_device_pose_orientation(gdrk::from_quatf(p_input_device_pose.orientation));

		touch_event->set_chirality(p_chirality == 0 ? gdrk::InputEventSpatialTouch::CHIRALITY_LEFT : gdrk::InputEventSpatialTouch::CHIRALITY_RIGHT);

		input_event = touch_event;
	} else {
		const godot::Vector3 world_relative = gdrk::from_simd3(p_position) -
				gdrk::from_simd3(loader->last_active_press_position[cur_press_idx]);
		const godot::Vector2 relative = gdrk::from_simd2(location) -
				gdrk::from_simd2(loader->last_active_press_location[cur_press_idx]);

		godot::Ref<gdrk::InputEventSpatialDrag> drag_event;
		drag_event.instantiate();

		drag_event->set_index(int32_t(p_event_id));
		drag_event->set_position(gdrk::from_simd2(location));
		drag_event->set_world_position(gdrk::from_simd3(p_position));
		drag_event->set_relative(relative);
		drag_event->set_screen_relative(drag_event->get_relative());

		drag_event->set_world_relative(world_relative);

		drag_event->set_flag(gdrk::InputEventSpatialTouch::FLAG_HAS_SELECTION_RAY, p_has_selection_ray);
		drag_event->set_flag(gdrk::InputEventSpatialTouch::FLAG_HAS_INPUT_DEVICE_POSE, p_has_input_device_pose);
		drag_event->set_flag(gdrk::InputEventSpatialTouch::FLAG_HAS_CHIRALITY, p_has_chirality);

		drag_event->set_selection_ray_origin(gdrk::from_simd3(p_selection_ray.origin));
		drag_event->set_selection_ray_direction(gdrk::from_simd3(p_selection_ray.direction));

		drag_event->set_input_device_pose_position(gdrk::from_simd3(p_input_device_pose.position));
		drag_event->set_input_device_pose_orientation(gdrk::from_quatf(p_input_device_pose.orientation));

		drag_event->set_chirality(p_chirality == 0 ? gdrk::InputEventSpatialTouch::CHIRALITY_LEFT : gdrk::InputEventSpatialTouch::CHIRALITY_RIGHT);

		input_event = drag_event;
	}

	loader->last_active_press_position[cur_press_idx] = p_position;
	loader->last_active_press_location[cur_press_idx] = location;

	if (node) {
		loader->push_input_event(gdrk::ColliderInputEventParams{
				.collider_id = node->get_instance_id(),
				.camera_id = camera->get_instance_id(),
				.input_event = input_event,
				.position = gdrk::from_simd3(p_hit_position),
				.normal = gdrk::from_simd3(p_hit_normal),
				.shape_idx = p_hit_shape_idx,
		});
	}
}

GDRKTransform GDRKBridgeDelegate::getXROrigin() const {
	godot::XRServer *xr_server = godot::XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, GDRKTransform::identity);

	const float inv_world_scale = 1.0f / xr_server->get_world_scale();
	const godot::Transform3D world_origin = xr_server->get_world_origin();
	return GDRKTransform{
		.scale = simd_make_float3(inv_world_scale, inv_world_scale, inv_world_scale),
		.position = gdrk::to_simd3(world_origin.get_origin()),
		.orientation = gdrk::to_quatf(world_origin.get_basis().get_rotation_quaternion()),
	};
}

bool GDRKBridgeDelegate::wantsControllerAnchors() const {
	return gdrk::RealityControllerXRInterface::get_active() != nullptr;
}

void GDRKBridgeDelegate::setControllerAnchor(ControllerHand p_hand, GDRKTransform p_transform, bool p_tracked) const {
	gdrk::RealityControllerXRInterface *controller_interface = gdrk::RealityControllerXRInterface::get_active();
	if (controller_interface == nullptr) {
		return;
	}

	godot::Transform3D pose;
	pose.basis.set_quaternion(convert(p_transform.orientation));
	pose.basis.scale(convert(p_transform.scale));
	pose.origin = convert(p_transform.position);

	const godot::XRPositionalTracker::TrackerHand hand = p_hand == kLeftHand
			? godot::XRPositionalTracker::TRACKER_HAND_LEFT
			: godot::XRPositionalTracker::TRACKER_HAND_RIGHT;

	controller_interface->set_anchor_pose(hand, pose, p_tracked);
}

void GDRKBridgeDelegate::setControllerInput(ControllerHand p_hand, void *p_gc_controller) const {
	gdrk::RealityControllerXRInterface *controller_interface = gdrk::RealityControllerXRInterface::get_active();
	if (controller_interface == nullptr || p_gc_controller == nullptr) {
		return;
	}

	GCController *gc_controller = (__bridge GCController *)p_gc_controller;
	GCControllerLiveInput *input = gc_controller.input;
	if (input == nil) {
		return;
	}

	auto button_value = [&](GCInputButtonName name) -> float {
		id<GCButtonElement> button = input.buttons[name];
		return button ? button.pressedInput.value : 0.0f;
	};
	auto button_pressed = [&](GCInputButtonName name) -> bool {
		id<GCButtonElement> button = input.buttons[name];
		return button ? button.pressedInput.isPressed : false;
	};

	gdrk::RealityControllerXRInterface::ControllerInput in;
	in.trigger = button_value(GCInputTrigger);
	in.trigger_click = button_pressed(GCInputTrigger);
	in.grip = button_value(GCInputGripButton);
	in.grip_click = button_pressed(GCInputGripButton);
	in.primary_button = button_pressed(GCInputButtonA);
	in.secondary_button = button_pressed(GCInputButtonB);
	in.menu_button = button_pressed(GCInputButtonMenu);
	id<GCDirectionPadElement> thumbstick = input.dpads[GCInputThumbstick];
	if (thumbstick != nil) {
		in.thumbstick = godot::Vector2(thumbstick.xAxis.value, thumbstick.yAxis.value);
	}
	in.thumbstick_click = button_pressed(GCInputThumbstickButton);

	const godot::XRPositionalTracker::TrackerHand hand = p_hand == kLeftHand
			? godot::XRPositionalTracker::TRACKER_HAND_LEFT
			: godot::XRPositionalTracker::TRACKER_HAND_RIGHT;
	controller_interface->set_controller_input(hand, in, p_gc_controller);
}

void log_version() {
	NSBundle *bundle = gdrk::get_gdrk_bundle();
	NSString *plistPath = [bundle pathForResource:@"Info" ofType:@"plist"];
	NSDictionary *plistData = [NSDictionary dictionaryWithContentsOfFile:plistPath];

	printf("Godot-RealityKit version %s: rendering a Godot scene with RealityKit.\n",
			[[plistData valueForKey:@"CFBundleVersion"] UTF8String]);
}

void log_help() {
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	if ([defaults boolForKey:@"gdrk-print-help"]) {
		NSBundle *bundle = gdrk::get_gdrk_bundle();
		NSURL *url = [bundle URLForResource:@"HelpCommands" withExtension:@"txt"];
		printf([[NSString stringWithContentsOfURL:url] UTF8String]);
	} else {
		printf("(Run with \"-gdrk-print-help YES\" to print a list of debug commands)\n");
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT gdrk_extension_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
#if TESTING_ENABLED
	gdrk::testing::GodotXCTestNode::init_dependencies(p_get_proc_address, p_library, r_initialization);
#endif
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(gdrk::initialize_gdrk_module);
	init_obj.register_terminator(gdrk::uninitialize_gdrk_module);
	init_obj.register_frame_callback(gdrk::main_loop_frame);
	init_obj.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_EDITOR);

	log_version();
	log_help();

	GDExtensionBool res = init_obj.init();
#if TESTING_ENABLED
	godot::internal::register_engine_classes();
#endif
	return res;
}
} // extern "C"
