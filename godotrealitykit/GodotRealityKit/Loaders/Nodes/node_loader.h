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

#include "../object_loader.h"
#include "bridge.h"
#include "hierarchical_effect.h"
#include "signal_collector.h"

#undef check
#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/memory.hpp>

#define NODE_LOADER(self, base, node_type)        \
	using Base = base<self, node_type>;           \
                                                  \
public:                                           \
	self(NodeLoaders *p_owner) : Base(p_owner) {} \
                                                  \
private:

namespace gdrk {

class NodeLoaders;

// Base class for all node loader types.
// Handles common node management, including adding/removing entities to the scene and
// updating each entity's transform if changed.
// Derived classes are responsible for implementing at least the following methods:
// update_deps:
//     This updates the loader's list of resource dependencies for each node.
//     It also ensures that each node's resources are registered with their respective resource loaders.
// update:
//     This propagates the dirty state of the nodes' resource dependencies to the nodes they affect;
//     then iterates over all dirty nodes to update their RealityKit representation.
// Note that unlike resources, there is no consistent "changed" signal emitted when a node's property has changed.
// (No, Object's property_list_changed is not emitted consistently)
// Therefore, we are forced to iterate over all nodes every frame, and we need some efficient way of keeping track of when different aspects of a node have changed.
// To handle this, node loaders store hashes of material, mesh, and other property values and compare them every frame.
// When a hash has changed, the node's dependencies are updated in update_deps() and the node is marked as dirty so it can be updated in update().
template <typename Derived, std::derived_from<godot::Node> Node>
class NodeLoaderBase : public ObjectLoader<Derived> {
	using Self = NodeLoaderBase<Derived, Node>;
	using Base = ObjectLoader<Derived>;

public:
	using NodeType = Node;

	static constexpr bool has_associated_entity = false;
	static constexpr bool is_geometry_instance_loader = std::is_base_of_v<godot::GeometryInstance3D, Node>;

	NodeLoaderBase(NodeLoaders *p_owner) :
			owner(p_owner) {}

	void _reserve(uint32_t p_capacity) {
		ObjectLoader<Derived>::_reserve(p_capacity);
		nodes.resize(p_capacity);
		node_parent_skeleton_idxs.resize(p_capacity);
		node_effect_rids_set.for_each([&](auto &effect) {
			effect.resize(p_capacity);
		});
	}

	template <typename Effect>
	godot::RID _update_effect(uint32_t p_idx, godot::RID p_rid) {
		const godot::RID old_rid = node_effect_rids_set.template get<Effect>()[p_idx];
		node_effect_rids_set.template get<Effect>()[p_idx] = p_rid;
		return old_rid;
	}

	template <typename Effect>
	godot::RID get_effect_rid(uint32_t p_idx) const {
		return node_effect_rids_set.template get<Effect>()[p_idx];
	}

	_FORCE_INLINE_ Node *cast(godot::Node *p_node) const {
		return godot::Object::cast_to<Node>(p_node);
	}

	uint32_t add(Node *p_node) {
		const uint32_t idx = Base::alloc_idx();
		const uint64_t node_id = p_node->get_instance_id();

		node_id_to_idx.insert(node_id, idx);
		nodes[idx] = p_node;

		if (godot::Object::cast_to<godot::Skeleton3D>(p_node->get_parent())) {
			node_parent_skeleton_idxs.insert(idx);
		} else {
			node_parent_skeleton_idxs.remove(idx);
		}

		node_effect_rids_set.for_each([&](auto &effect) {
			effect[idx] = godot::RID();
		});

		return idx;
	}

	uint32_t remove(Node *p_node) {
		const uint64_t node_id = p_node->get_instance_id();
		const auto found = node_id_to_idx.find(node_id);
		ERR_FAIL_COND_V(!found, 0);

		const uint32_t idx = found->value;
		nodes[idx] = nullptr;

		node_id_to_idx.remove(found);
		Base::free_idx(idx);

		return idx;
	}

	_FORCE_INLINE_ bool has(uint64_t node_id) const {
		return node_id_to_idx.has(node_id);
	}

	_FORCE_INLINE_ Node *get_node(uint32_t p_idx) { return nodes[p_idx]; }
	_FORCE_INLINE_ uint64_t get_entity_id(uint32_t p_idx) const { return 0; }

	void update_deps(ResourceLoaderSet &p_resource_loaders) {}

	void update(const ResourceLoaderSet &p_resource_loaders);

	godot::HashMap<uint64_t, uint32_t> node_id_to_idx;

protected:
	NodeLoaders *owner;

	godot::LocalVector<Node *> nodes;
	LocalBitVector node_parent_skeleton_idxs;

	EffectRIDsSet node_effect_rids_set;

private:
	friend class MeshLoader;

	template <typename Effect>
	friend class HierarchicalEffect;
};

class AnyNodeLoader : public NodeLoaderBase<AnyNodeLoader, godot::Node> {
	NODE_LOADER(AnyNodeLoader, NodeLoaderBase, godot::Node)
};

template <typename Derived, std::derived_from<godot::Node> Node>
class NodeLoader : public NodeLoaderBase<Derived, Node> {
	using Self = NodeLoader<Derived, Node>;
	using Base = NodeLoaderBase<Derived, Node>;

public:
	static constexpr bool has_associated_entity = true;
	static constexpr bool receives_hover_effects = false;
	static constexpr bool manages_entity_registrations = false;
	static constexpr bool manages_visibility_state = false;
	static constexpr bool requires_node_entity_mapping = false;

	NodeLoader(NodeLoaders *p_owner) :
			Base(p_owner) {
		visibility_changed_collector.initialize(this, &NodeLoader::_visibility_changed);
	}

	GodotRealityKit::Entity _create_entity() {
		return GodotRealityKit::Entity::init();
	}

	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		node_entities.resize(p_capacity);
		node_transform_states.resize(p_capacity);
		node_visible_idxs.resize(p_capacity);
		visibility_changed_collector.resize(p_capacity);
	}

	_FORCE_INLINE_ bool is_visible(uint32_t p_idx) const { return node_visible_idxs.has(p_idx); }
	_FORCE_INLINE_ void mark_visible(uint32_t p_idx) { node_visible_idxs.insert(p_idx); }
	_FORCE_INLINE_ void mark_invisible(uint32_t p_idx) { node_visible_idxs.remove(p_idx); }
	_FORCE_INLINE_ bool is_enabled(uint32_t p_idx) const { return node_entities[p_idx].enabled; }
	_FORCE_INLINE_ bool is_registered(uint32_t p_idx) const { return node_entities[p_idx].registered; }

	template <std::invocable<uint32_t> Fn>
	void for_each_dirty_and_visible(const Fn &fn) const {
		Base::for_each_dirty([&](uint32_t p_idx) {
			if (is_visible(p_idx)) {
				fn(p_idx);
			}
		});
	}

	template <typename Effect>
	godot::RID _update_effect(uint32_t p_idx, godot::RID p_rid) {
		const godot::RID old_rid = Base::template _update_effect<Effect>(p_idx, p_rid);
		if constexpr (!std::is_same_v<Effect, HoverEffect> || Derived::receives_hover_effects) {
			// node_entities[p_idx].entity is only materialized once registered; calling
			// Effect::update on it beforehand (e.g. a node marked visible before its
			// deferred registration, like CollisionObjectLoader's ray-pickable gating)
			// would touch a nil RealityKit entity.
			if (is_visible(p_idx) && node_entities[p_idx].registered) {
				Effect::update(Base::owner, get_entity(p_idx), p_rid);
			}
		}

		return old_rid;
	}

	void register_entity(uint32_t p_index);
	void unregister_entity(uint32_t p_index, godot::Node *p_node);

	uint32_t add(Node *p_node);
	uint32_t remove(Node *p_node);

	_FORCE_INLINE_ uint64_t get_entity_id(uint32_t p_idx) const {
		return node_entities[p_idx].registered ? const_cast<GodotRealityKit::Entity &>(node_entities[p_idx].entity).id() : 0;
	}

	void on_transform_changed(uint32_t p_idx, const godot::Transform3D &transform);

	_FORCE_INLINE_ GodotRealityKit::Entity get_entity(uint32_t p_idx) const { return node_entities[p_idx].entity; }
	_FORCE_INLINE_ godot::Transform3D get_transform(uint32_t p_idx) const { return node_transform_states[p_idx]; }

	void update_transform_ifn(uint32_t p_idx);
	void update_transforms();
	void update(const ResourceLoaderSet &p_resource_loaders);

protected:
	inline void _visibility_changed(uint32_t p_idx) {
		const bool enabled = Base::nodes[p_idx]->is_visible_in_tree();
		if (enabled != node_entities[p_idx].enabled) {
			node_entities[p_idx].enabled = enabled;
			static_cast<Derived *>(this)->_on_visibility_changed(p_idx);
		}
	}
	inline void _on_visibility_changed(uint32_t p_idx) {
		if (node_entities[p_idx].registered) {
			node_entities[p_idx].entity.setEnabled(node_entities[p_idx].enabled);
		}

		if (node_entities[p_idx].enabled) {
			update_transform_ifn(p_idx);
		}
	}

	void _on_enabled_changed(uint32_t, bool, bool) {}

	struct Entity {
		GodotRealityKit::Entity entity = GodotRealityKit::Entity::init();
		bool registered = false;
		bool enabled = false;
	};

	godot::LocalVector<Entity> node_entities;
	LocalBitVector node_visible_idxs;

	DECLARE_SIGNAL_COLLECTOR(VisibilityChanged, "visibility_changed", Self, godot::Node3D);
	VisibilityChangedCollector visibility_changed_collector;
	godot::LocalVector<godot::Transform3D> node_transform_states;

	friend class NodeLoaders;
};

} //namespace gdrk
