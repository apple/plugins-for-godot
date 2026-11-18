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

#include "bridge.h"

#undef check
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/templates/rid_owner.hpp>

namespace gdrk {

class NodeLoaders;

struct HoverEffectStyle {
	GodotRealityKit::HoverEffectGroupID group_id = GodotRealityKit::HoverEffectGroupID::init();
	GDRKColorRef color = nullptr;
	float strength = 1.0f;
	bool spotlight = false;
};

struct HoverEffect {
	HoverEffectStyle style;

	static void update(NodeLoaders *p_nodes, GodotRealityKit::Entity p_entity, godot::RID p_new_rid);
};

struct PortalEffect {
	GodotRealityKit::Entity world_entity = GodotRealityKit::Entity::initAndMaterialize();
	uint32_t ref_count = 0;

	static void update(NodeLoaders *p_nodes, GodotRealityKit::Entity p_entity, godot::RID p_new_rid);
};

struct PortalCrossingEffect {
	static void update(NodeLoaders *p_nodes, GodotRealityKit::Entity p_entity, godot::RID p_new_rid);
};

struct IBLEffect {
	GodotRealityKit::Entity ibl_entity = GodotRealityKit::Entity::initAndMaterialize();

	static void update(NodeLoaders *p_nodes, GodotRealityKit::Entity p_entity, godot::RID p_new_rid);
};

struct EnvironmentLightingEffect {
	float weight = 1.0f;

	static void update(NodeLoaders *p_nodes, GodotRealityKit::Entity p_entity, godot::RID p_new_rid);
};

// Two entities parented to root: `clipper_entity` (C) carries the ClippingComponent and a rigid
// (rotation + translation only) transform; `anchor_entity` (A) is C's child with transform = C's
// inverse, so reparenting content under A cancels C's transform and content keeps its correct
// world pose while still being clipped (C.shouldClipChildren clips all of C's descendants).
struct ClippingEffect {
	GodotRealityKit::Entity clipper_entity = GodotRealityKit::Entity::initAndMaterialize();
	GodotRealityKit::Entity anchor_entity = GodotRealityKit::Entity::initAndMaterialize();

	static void update(NodeLoaders *p_nodes, GodotRealityKit::Entity p_entity, godot::RID p_new_rid);
};

template <template <typename> typename Value, typename... Effects>
struct EffectSet {
private:
	template <typename Effect>
	struct Entry {
		Value<Effect> value;
	};

	struct Entries : Entry<Effects>... {
		Entries() = default;

		template <typename... Ts>
		Entries(const Ts &...args) :
				Entry<Effects>{ Value<Effects>(args...) }... {}
	} entries;

public:
	EffectSet() = default;

	template <typename... Ts>
	EffectSet(const Ts &...args) :
			entries(args...) {}

	template <typename Effect>
	constexpr auto &get() {
		return static_cast<Entry<Effect> &>(entries).value;
	}

	template <typename Effect>
	constexpr const auto &get() const {
		return static_cast<const Entry<Effect> &>(entries).value;
	}

	template <typename Fn>
	void for_each(Fn &&p_fn) {
		(p_fn(get<Effects>()), ...);
	}

	template <typename Fn>
	void for_each(Fn &&p_fn) const {
		(p_fn(get<Effects>()), ...);
	}
};

template <typename Effect>
class HierarchicalEffect {
public:
	HierarchicalEffect(NodeLoaders *p_owner) :
			owner(p_owner) {}

	Effect &get_effect(godot::RID p_rid);
	godot::Node *get_effect_root(godot::RID p_rid);
	bool owns(godot::RID p_rid);

	godot::RID create(uint64_t p_root_id, const Effect &p_effect);
	void free(uint64_t p_root_id);
	godot::RID get(uint64_t p_root_id) const;
	bool has(uint64_t p_root_id) const;

	// Non-null only for nodes that are an effect root. Returned by pointer so the ancestor walk
	// in NodeLoaders::resolve_inherited_effects needs no RID::is_valid() call, which is an
	// out-of-line ptrcall in godot-cpp.
	const godot::RID *find(uint64_t p_root_id) const {
		const auto found = root_id_to_rid.find(p_root_id);
		return found ? &found->value : nullptr;
	}

	bool is_empty() const { return root_id_to_rid.is_empty(); }

	void mark_changed(uint64_t p_root_id) { queued_propagations.push_back(p_root_id); }

	void flush_propagations();

private:
	template <bool root>
	void propagate_update(godot::Node *p_node, godot::RID p_rid);

	struct EffectAndRoot {
		Effect effect;
		uint64_t root_id;
	};

	godot::HashMap<uint64_t, godot::RID> root_id_to_rid;
	godot::RID_Owner<EffectAndRoot> effect_owner;
	godot::LocalVector<uint64_t> queued_propagations;
	NodeLoaders *owner;
};

template <typename Effect> using LocalRIDVector = godot::LocalVector<godot::RID>;

// The rid of the nearest ancestor-or-self effect root, per effect, as produced by
// NodeLoaders::resolve_inherited_effects. `resolved` is tracked separately from the rid so the
// ancestor walk can skip already-resolved effects without calling RID::is_valid().
template <typename Effect>
struct ResolvedEffectRID {
	godot::RID rid;
	bool resolved = false;
};

// All three sets must list the effects in the same order: EffectSet::for_each is a comma fold
// over that order, and PortalEffect has to run before ClippingEffect so clipping's setParent
// wins over the portal's (see ClippingEffect::update).
using EffectRIDsSet = EffectSet<LocalRIDVector, HoverEffect, PortalEffect, PortalCrossingEffect, IBLEffect, ClippingEffect, EnvironmentLightingEffect>;
using HierarchicalEffectSet = EffectSet<HierarchicalEffect, HoverEffect, PortalEffect, PortalCrossingEffect, IBLEffect, ClippingEffect, EnvironmentLightingEffect>;
using ResolvedEffectRIDs = EffectSet<ResolvedEffectRID, HoverEffect, PortalEffect, PortalCrossingEffect, IBLEffect, ClippingEffect, EnvironmentLightingEffect>;

} // namespace gdrk
