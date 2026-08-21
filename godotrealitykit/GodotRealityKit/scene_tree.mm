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

#import "scene_tree.h"
#import "node_loaders.h"
#import "resource_loaders.h"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/xr_interface.hpp>
#include <godot_cpp/classes/xr_server.hpp>

namespace {

bool should_dump_reality_file() {
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	const bool res = [defaults boolForKey:@"gdrk-reality-file-dump"];
	if (res) {
		printf("User default \"gdrk-reality-file-dump\" enabled: will dump first frame to a reality file and then quit\n");
	}

	return res;
}

bool should_dump_metal_capture() {
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	const bool res = [defaults boolForKey:@"gdrk-metal-capture-dump"];
	if (res) {
		printf("User default \"gdrk-reality-file-dump\" enabled: will capture and dump first frame's Metal workload to a gpucapture file\n");
	}

	return res;
}

godot::CharString get_scene_name() {
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();
	godot::String main_scene_path = project_settings->get_setting("application/run/main_scene");
	godot::StringName main_scene_name = main_scene_path.trim_prefix("res://").trim_suffix("/scene.tscn");
	return main_scene_name.to_lower().to_snake_case().ascii();
}

} //namespace

namespace gdrk {

// High-level class responsible for loading the Godot scene into RealityKit
// The idea is to keep things reasonably efficient and data-oriented:
// Ex. First iterate over dirty textures and update them, then iterate over dirty materials
// (which potentially reference the new textures) and update them, then iterate over all the mesh instance nodes
// (which potentially reference the new materials) and update them, and so on.
// See update().
MaterialLoader *SceneLoader::get_materials() {
	return std::get<MaterialLoader *>(resource_loaders);
}

void SceneLoader::initialize(godot::Node *p_node, GodotRealityKit::Entity p_entity) {
	PROFILE_FUNC_SCOPE;

	root_node = p_node;
	root_entity = p_entity;

	const uint32_t frame_delay = rendering_device()->get_frame_delay();
	command_buffers.resize(frame_delay);

	std::get<TextureLoader *>(resource_loaders) = memnew(gdrk::TextureLoader);
	std::get<MaterialLoader *>(resource_loaders) = memnew(gdrk::MaterialLoader);
	std::get<MeshLoader *>(resource_loaders) = memnew(gdrk::MeshLoader);
	std::get<MultiMeshLoader *>(resource_loaders) = memnew(gdrk::MultiMeshLoader);
	std::get<ShapeLoader *>(resource_loaders) = memnew(gdrk::ShapeLoader);
	std::get<EnvironmentLoader *>(resource_loaders) = memnew(gdrk::EnvironmentLoader);
	std::get<SkyboxLoader *>(resource_loaders) = memnew(gdrk::SkyboxLoader);

	nodes = memnew(gdrk::NodeLoaders);
	nodes->initialize(root_entity);

	std::get<MeshLoader *>(resource_loaders)->initialize();

	took_capture = !should_dump_metal_capture();

	GodotRealityKit::Initialize();
}

SceneLoader::~SceneLoader() {
	if (nodes) {
		memfree(nodes);
	}

	for_each_loader(resource_loaders, [](auto *&loader) {
		if (loader) {
			memfree(loader);
		}
	});
}

void SceneLoader::update() {
	PROFILE_FUNC_SCOPE;

	id<MTLCommandBuffer> prev_buffer = command_buffers[current_command_buffer_idx];
	if (prev_buffer) {
		const MTLCommandBufferStatus status = [prev_buffer status];
		if (status == MTLCommandBufferStatusNotEnqueued) {
			return;
		}
		[prev_buffer waitUntilCompleted];
	}

	TextureLoader *textures = std::get<TextureLoader *>(resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(resource_loaders);
	MeshLoader *meshes = std::get<MeshLoader *>(resource_loaders);
	MultiMeshLoader *multimeshes = std::get<MultiMeshLoader *>(resource_loaders);
	ShapeLoader *shapes = std::get<ShapeLoader *>(resource_loaders);
	EnvironmentLoader *environments = std::get<EnvironmentLoader *>(resource_loaders);
	SkyboxLoader *skyboxes = std::get<SkyboxLoader *>(resource_loaders);

	frame_count++;
	nodes->update_deps(resource_loaders);
	materials->update_deps(textures);

	if (materials->has_programs_loading()) {
		return;
	}

	textures->remove_unreferenced();
	meshes->remove_unreferenced();
	multimeshes->remove_unreferenced();
	shapes->remove_unreferenced();
	environments->remove_unreferenced();
	skyboxes->remove_unreferenced();

	id<MTLCommandQueue> command_queue = gdrk::get_metal_command_queue(rendering_device());

	if (!took_capture) {
		dump_metal_capture(command_queue);
		took_capture = true;
	}

	id<MTLCommandBuffer> command_buffer = [command_queue commandBuffer];

	bool texture_needs_godot_frame = false;
	bool finished = textures->update(command_buffer, texture_needs_godot_frame);
	// Keep Godot running for frame-generated textures to avoid a circular wait.
	bool should_block = !finished && !texture_needs_godot_frame;
	auto update_finished = [&](bool p_finished) {
		finished &= p_finished;
		should_block |= !p_finished;
	};
	update_finished(materials->update(command_buffer, textures));
	update_finished(meshes->update(command_buffer));
	update_finished(multimeshes->update());
	update_finished(shapes->update());
	update_finished(environments->update());
	update_finished(skyboxes->update(command_buffer));

	[command_buffer commit];
	command_buffers[current_command_buffer_idx] = command_buffer;
	current_command_buffer_idx = (current_command_buffer_idx + 1) % command_buffers.size();

	MTLCaptureManager *capture_manager = [MTLCaptureManager sharedCaptureManager];
	if ([capture_manager isCapturing]) {
		[capture_manager stopCapture];
	}

	if (should_block && !loading_in_progress) {
		loading_in_progress = true;
		GodotRealityKit::startBlockingAsyncTask();
	} else if (!should_block && loading_in_progress) {
		loading_in_progress = false;
		GodotRealityKit::stopBlockingAsyncTask();
	}

	if (!finished) {
		return;
	}

	nodes->update(resource_loaders);

	textures->reset_dirty();
	materials->reset_dirty();
	meshes->reset_dirty();
	multimeshes->reset_dirty();
	shapes->reset_dirty();
	nodes->reset_dirty();
	environments->reset_dirty();
	skyboxes->reset_dirty();

	if (!get_scene_tree()->is_paused() && on_next_frame_completion != std::nullopt) {
		[command_buffer waitUntilCompleted];
		(*on_next_frame_completion)();
		on_next_frame_completion = std::nullopt;
	}

#if !TARGET_OS_OSX
	if (!original_scene_destroyed && GodotRealityKit::isSceneVisible()) {
		[command_buffer waitUntilCompleted];
		GodotRealityKit::destroyOriginalScene();
		original_scene_destroyed = true;
	}
#endif
}

void SceneLoader::call_on_next_frame_completion(const std::function<void()> &p_on_next_frame_completion) {
	on_next_frame_completion = p_on_next_frame_completion;
}

void SceneLoader::flush_input_events() {
	for (const ColliderInputEventParams &params : input_event_queue) {
		godot::Node3D *camera =
				godot::Object::cast_to<godot::Node3D>(godot::ObjectDB::get_instance(params.camera_id));
		ERR_CONTINUE(!camera);

		godot::CollisionObject3D *collision_object =
				godot::Object::cast_to<godot::CollisionObject3D>(godot::ObjectDB::get_instance(params.collider_id));
		ERR_CONTINUE(!collision_object);

		collision_object->emit_signal("input_event", camera, params.input_event, params.position, params.normal, params.shape_idx);
	}

	input_event_queue.clear();
}

void SceneLoader::dump_metal_capture(id<MTLCommandQueue> p_command_queue) {
	const uint32_t random_id = rand() % 9999;
	NSString *ns_file_name = [NSString stringWithFormat:@"%s_%u.gputrace",
			get_scene_name().ptr(), random_id];
	NSURL *tmp_dir = [NSURL fileURLWithPath:@"~/Documents/" isDirectory:YES];
	NSURL *file_path = [tmp_dir URLByAppendingPathComponent:ns_file_name];

	MTLCaptureDescriptor *capture_descriptor = [[MTLCaptureDescriptor alloc] init];
	capture_descriptor.captureObject = p_command_queue;
	capture_descriptor.destination = MTLCaptureDestinationGPUTraceDocument;
	capture_descriptor.outputURL = file_path;

	NSError *error;
	[[MTLCaptureManager sharedCaptureManager] startCaptureWithDescriptor:capture_descriptor error:&error];

	if (error) {
		ERR_PRINT([[error localizedDescription] UTF8String]);
	} else {
		printf("Dumping Metal capture to %s\n", [[file_path absoluteString] UTF8String]);
	}
}

RealitySceneTree::~RealitySceneTree() {
	if (loader) {
		memfree(loader);
	}
}

void RealitySceneTree::_initialize() {
	PROFILE_FUNC_SCOPE;

	godot::Engine *engine = godot::Engine::get_singleton();
	godot::RenderingServer *rendering_server = godot::RenderingServer::get_singleton();
	if (engine->is_embedded_in_editor() || engine->is_editor_hint()) {
		enabled = false;
	}

#if TARGET_OS_OSX
	{
		godot::ProjectSettings *ps = godot::ProjectSettings::get_singleton();
		const char *key = "reality_kit/debug_rendering_on_macos";
		if (!ps->has_setting(key) || !ps->get_setting(key).booleanize()) {
			enabled = false;
		}
	}
#endif

	if (!enabled) {
		godot::SceneTree::_initialize();
		return;
	}

	loader = memnew(SceneLoader);
	loader->initialize(get_current_scene(), bridge.getRoot());
	connect("node_added", callable_mp(loader->get_nodes(), &gdrk::NodeLoaders::node_added));
	connect("node_removed", callable_mp(loader->get_nodes(), &gdrk::NodeLoaders::node_removed));

	GDRKBridgeDelegate bridge_delegate = GDRKBridgeDelegate(loader);
	bridge.initialize(bridge_delegate);

	extension_settings = bridge_delegate.getExtensionSettings();

#if TARGET_OS_XR
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();

	const bool controller_tracking_enabled = project_settings->get("xr/visionos/enable_controller_tracking_module");
	godot::Ref<godot::XRInterface> controller_interface = godot::XRServer::get_singleton()->find_interface("visionOSControllerTracker");
	if (controller_interface.is_valid() && controller_tracking_enabled &&
			(extension_settings.presentationStyle == kVolumetricWindow || extension_settings.presentationStyle == kImmersive)) {
		controller_interface->initialize();
	}

	const bool hand_tracking_enabled = project_settings->get("xr/visionos/enable_hand_tracking_module");
	godot::Ref<godot::XRInterface> hands_interface = godot::XRServer::get_singleton()->find_interface("visionOSHandTracker");
	if (hands_interface.is_valid() && hand_tracking_enabled && extension_settings.presentationStyle == kImmersive) {
		hands_interface->initialize();
	}
#endif // TARGET_OS_XR

	godot::SceneTree::_initialize();

	if (should_dump_reality_file()) {
		dump_reality_file_and_quit();
	}
}

bool RealitySceneTree::_process(double p_time) {
	PROFILE_FUNC_SCOPE;
	if (!enabled) {
		return godot::SceneTree::_process(p_time);
	}

	const godot::RID viewport_rid = get_root()->get_viewport_rid();
	rendering_server()->viewport_set_update_mode(viewport_rid, godot::RenderingServer::VIEWPORT_UPDATE_DISABLED);

	// Early exit if the game is paused while we wait for blocking async tasks
	godot::SceneTree *scene_tree = loader->get_root_node()->get_tree();
	if (GodotRealityKit::isBlockingAsyncTaskRunning()) {
		if (!paused_for_blocking_task) {
			scene_tree->set_pause(true);
			paused_for_blocking_task = true;
		}

		return false;
	} else {
		if (paused_for_blocking_task) {
			scene_tree->set_pause(false);
			paused_for_blocking_task = false;
		}
	}

	// Only update the RealityKit scene if the app is in the foreground (visible)
#if !TESTING_ENABLED
	if (!bridge.isSceneVisible()) {
		return false;
	}
#endif

	const bool res = godot::SceneTree::_process(p_time);

	return res;
}

bool RealitySceneTree::_physics_process(double p_time) {
	PROFILE_FUNC_SCOPE;

	if (GodotRealityKit::isBlockingAsyncTaskRunning()) {
		return false;
	}

	const bool res = godot::SceneTree::_physics_process(p_time);
	if (loader) {
		loader->flush_input_events();
	}
	return res;
}

void RealitySceneTree::clear_boot_image() {
	godot::RenderingServer *rendering_server = godot::RenderingServer::get_singleton();

	godot::PackedByteArray empty_boot_logo_data;
	empty_boot_logo_data.resize(4);
	empty_boot_logo_data.fill(0);

	godot::Ref<godot::Image> empty_boot_logo;
	empty_boot_logo.instantiate();
	empty_boot_logo->set_data(1, 1, false, godot::Image::FORMAT_RGBA8, empty_boot_logo_data);
	rendering_server->set_boot_image(empty_boot_logo, godot::Color(0.0, 0.0, 0.0, 0.0), false);
}

void RealitySceneTree::dump_reality_file_and_quit() {
	loader->call_on_next_frame_completion([this]() {
		const uint32_t random_id = rand() % 9999;
		NSString *ns_file_name = [NSString stringWithFormat:@"%s_%u.reality",
				get_scene_name().ptr(), random_id];
		NSURL *tmp_dir = [NSURL fileURLWithPath:@"~/Documents/" isDirectory:YES];
		NSURL *file_path = [tmp_dir URLByAppendingPathComponent:ns_file_name];

		GDRKEntityWriteDelegate entity_write_delegate = GDRKEntityWriteDelegate([this] {
			quit();
		});

		GodotRealityKit::Entity root_entity = get_loader()->get_nodes()->get_root_entity();
		root_entity.writeAsync(swift::String::init([file_path relativeString]),
				entity_write_delegate);
	});
}

} // namespace gdrk
