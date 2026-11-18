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

#include "../resource_loaders.h"
#include "hover_effect_3d.h"
#include "node_loader.h"

#include <godot_cpp/classes/collision_object3d.hpp>

namespace gdrk {

class CollisionObjectLoader : public NodeLoader<CollisionObjectLoader, godot::CollisionObject3D> {
	NODE_LOADER(CollisionObjectLoader, NodeLoader, godot::CollisionObject3D);

public:
	static constexpr bool receives_hover_effects = true;
	static constexpr bool requires_node_entity_mapping = true;
	static constexpr bool manages_entity_registrations = true;

	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		node_is_ray_pickable.resize(p_capacity);
		node_has_hover_effect_meta.resize(p_capacity);
		dep_states.resize(p_capacity);
	}

	uint32_t add(godot::CollisionObject3D *p_node) {
		const uint32_t idx = Base::add(p_node);
		node_is_ray_pickable.remove(idx);
		node_has_hover_effect_meta.remove(idx);
		dep_states[idx] = DependencyState();
		return idx;
	}

	void on_transform_changed(uint32_t p_idx, const godot::Transform3D &transform);

	template <typename Effect>
	void _update_effect(uint32_t p_idx, godot::RID p_rid) {
		if constexpr (!std::is_same_v<Effect, ClippingEffect>) {
			if (!node_is_ray_pickable.has(p_idx)) {
				return;
			}
		}
		Base::template _update_effect<Effect>(p_idx, p_rid);
	}

	void update_deps(ResourceLoaderSet &p_resource_loaders);

	void update_dirty_flags(const ResourceLoaderSet &p_resource_loaders);
	void update_deps_usage(ResourceLoaderSet &p_resource_loaders) const;

	void update(const ResourceLoaderSet &p_resource_loaders);

private:
	bool node_has_hover_effect(godot::CollisionObject3D *p_node) const;
	bool node_is_pickable(godot::CollisionObject3D *p_node) const;

	struct DependencyState {
		uint32_t shape_hash = 0;
	};

	LocalBitVector node_is_ray_pickable;
	LocalBitVector node_has_hover_effect_meta;
	DependencyList shape_deps;

	godot::LocalVector<DependencyState> dep_states;
};

class RealityHoverEffectLoader : public NodeLoaderBase<RealityHoverEffectLoader, RealityHoverEffect3D> {
	NODE_LOADER(RealityHoverEffectLoader, NodeLoaderBase, RealityHoverEffect3D)
public:
	void _reserve(uint32_t p_capacity) {
		Base::_reserve(p_capacity);
		node_hover_effect_states.resize(p_capacity);
		node_hover_effect_rids.resize(p_capacity);
	}

	uint32_t add(RealityHoverEffect3D *p_node);
	uint32_t remove(RealityHoverEffect3D *p_node);

	void update(const ResourceLoaderSet &p_resource_loaders);

private:
	struct HoverEffectState {
		uint32_t properties_hash = 0;
	};

	godot::LocalVector<HoverEffectState> node_hover_effect_states;
	godot::LocalVector<godot::RID> node_hover_effect_rids;
};

} //namespace gdrk
