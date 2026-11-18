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


#import "node_loaders.h"
#include "Nodes/hierarchical_effect.h"
#include "resource_loaders.h"
#import "signposts.h"

#include <cstdio>
#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/text_server_manager.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/engine_ptrcall.hpp>

namespace gdrk {

namespace {

template <typename T>
struct LoaderInit {
	NodeLoaders *owner;
	operator T() const { return T(owner); }
};

template <typename... Ts>
std::tuple<Ts...> make_node_loaders(std::tuple<Ts...> *, NodeLoaders *p_owner) {
	return std::tuple<Ts...>(LoaderInit<Ts>{ p_owner }...);
}

} // namespace

NodeLoaders::NodeLoaders() :
		godot::Object(),
		loaders(make_node_loaders((NodeLoaderSet *)nullptr, this)) {
	get<MeshInstanceLoader>().initialize(&get<CameraLoader>());
	get<SpotLightLoader>().initialize(&get<CameraLoader>());
}

void NodeLoaders::node_added(godot::Node *p_node) {
	if (p_node->has_meta("_gdrk_skip") && p_node->get_meta("_gdrk_skip")) {
		return;
	}

	visit(p_node, [&]<class NodeLoader, class N>(NodeLoader &p_loader, N *p_node) {
		const uint64_t node_id = p_node->get_instance_id();
		if (p_loader.has(node_id)) {
			WARN_COMPAT_MSG("Attempting to add node multiple times");
			return;
		}

		const uint32_t idx = p_loader.add(p_node);

		const uint64_t entity_id = p_loader.get_entity_id(idx);
		if (entity_id) {
			node_id_to_entity_id.insert(node_id, entity_id);
			entity_id_to_node_id.insert(entity_id, node_id);
		}
	});
}

void NodeLoaders::node_removed(godot::Node *p_node) {
	const uint64_t node_id = p_node->get_instance_id();

	if (p_node->has_meta("_gdrk_skip") && p_node->get_meta("_gdrk_skip")) {
		return;
	}

	visit(p_node, [&]<class NodeLoader, class N>(NodeLoader &p_loader, N *p_node) {
		if (!p_loader.has(node_id)) {
			WARN_COMPAT_MSG("Attempting to remove node multiple times");
			return;
		}

		p_loader.remove(p_node);
	});

	if (auto found = node_id_to_entity_id.find(node_id)) {
		entity_id_to_node_id.erase(found->value);
		node_id_to_entity_id.remove(found);
	}
}

ResolvedEffectRIDs NodeLoaders::resolve_inherited_effects(godot::Node *p_node) {
	ResolvedEffectRIDs resolved;

	uint32_t pending = 0;
	effects.for_each([&](const auto &p_effect) {
		pending += p_effect.is_empty() ? 0 : 1;
	});

	for (godot::Node *node = p_node; node && pending > 0; node = node->get_parent()) {
		const uint64_t node_id = node->get_instance_id();
		effects.for_each([&]<typename Effect>(const HierarchicalEffect<Effect> &p_effect) {
			ResolvedEffectRID<Effect> &out = resolved.get<Effect>();
			if (out.resolved) {
				return;
			}

			if (const godot::RID *rid = p_effect.find(node_id)) {
				out.rid = *rid;
				out.resolved = true;
				pending--;
			}
		});
	}

	return resolved;
}

void NodeLoaders::update_deps(ResourceLoaderSet &p_resource_loaders) {
	for_each_loader(loaders, [&](auto &p_loader) {
		p_loader.update_deps(p_resource_loaders);
	});
}

void NodeLoaders::update_transforms() {
	for_each_loader(loaders, [&]<typename NodeLoader>(NodeLoader &p_loader) {
		if constexpr (requires { p_loader.update_transforms(); }) {
			p_loader.update_transforms();
		}
	});
}

void NodeLoaders::update_dirty_flags(const ResourceLoaderSet &p_resource_loaders) {
	for_each_loader(loaders, [&]<typename NodeLoader>(NodeLoader &p_loader) {
		if constexpr (requires { p_loader.update_dirty_flags(p_resource_loaders); }) {
			p_loader.update_dirty_flags(p_resource_loaders);
		}
	});
}

void NodeLoaders::update_visibility_states(const ResourceLoaderSet &p_resource_loaders) {
	// CameraLoader must refresh its culling info before any visibility-managing
	// loader queries it; otherwise update_visibility_state runs against stale
	// (or first-frame uninitialized) camera state. Then update() below skips
	// the camera so it isn't updated twice in the same frame.
	get<CameraLoader>().update(p_resource_loaders);

	const MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	for_each_loader(loaders, [&]<typename NodeLoader>(NodeLoader &p_loader) {
		if constexpr (requires { NodeLoader::manages_visibility_state; }) {
			if constexpr (NodeLoader::manages_visibility_state) {
				p_loader.update_visibility_state(meshes);
			}
		}
	});
}

void NodeLoaders::update_deps_usage(ResourceLoaderSet &p_resource_loaders) {
	for_each_loader(loaders, [&]<typename NodeLoader>(NodeLoader &p_loader) {
		if constexpr (requires { p_loader.update_deps_usage(p_resource_loaders); }) {
			p_loader.update_deps_usage(p_resource_loaders);
		}
	});
}

void NodeLoaders::update(ResourceLoaderSet &p_resource_loaders) {
	// CameraLoader was already updated by update_visibility_states this frame.
	for_each_loader(loaders, [&]<typename NodeLoader>(NodeLoader &p_loader) {
		if constexpr (!std::is_same_v<NodeLoader, CameraLoader>) {
			p_loader.update(p_resource_loaders);
		}
	});

	effects.for_each([&]<typename Effect>(HierarchicalEffect<Effect> &effect) {
		effect.flush_propagations();
	});

	// The flush above has now reparented any removed clips' subtrees back to root, so it's safe
	// to drop the clipper/anchor entities.
	for (ClippingRigEntities &rig : clipping_pending_teardown) {
		rig.clipper.dematerialize();
		rig.anchor.dematerialize();
	}
	clipping_pending_teardown.clear();
}

void NodeLoaders::reset_dirty() {
	for_each_loader(loaders, [&](auto &p_loader) {
		p_loader.reset_dirty();
	});
}

} // namespace gdrk
