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

#ifndef NODE_LOADERS_H
#define NODE_LOADERS_H

#import "bridge.h"
#import "object_loader.h"
#import "resource_loaders.h"

#include "Nodes/camera_loader.h"
#include "Nodes/clipping_loader.h"
#include "Nodes/collision_object_loader.h"
#include "Nodes/cpu_particles_loader.h"
#include "Nodes/csg_shape3d_loader.h"
#include "Nodes/directional_light_loader.h"
#include "Nodes/directional_light_shadow_loader.h"
#include "Nodes/environment_lighting_configuration_loader.h"

#include "Nodes/grid_map_loader.h"
#include "Nodes/image_based_light_loader.h"
#include "Nodes/label_loader.h"
#include "Nodes/mesh_instance_loader.h"
#include "Nodes/multimesh_instance_loader.h"
#include "Nodes/point_light_loader.h"
#include "Nodes/spot_light_loader.h"
#include "Nodes/sprite_loader.h"
#include "Nodes/world_environment_loader.h"

#include "portal_mesh_instance_3d.h"
#include "volume_camera_3d.h"

#include <godot_cpp/core/class_db.hpp>

namespace gdrk {

using NodeLoaderSet = std::tuple<
		RealityPortalMeshInstanceLoader, MeshInstanceLoader, MultiMeshInstanceLoader, GridMapLoader,
		CPUParticlesLoader, CollisionObjectLoader, SpriteLoader, CSGShape3DLoader, DirectionalLightLoader, RealityKitDirectionalLightShadow3DLoader, PointLightLoader,
		SpotLightLoader, LabelLoader, CameraLoader, RealityHoverEffectLoader,
		RealityPortalCrossingLoader, WorldEnvironmentLoader, ImageBasedLightLoader, RealityClippingLoader,
		RealityKitEnvironmentLightingConfigurationLoader, AnyNodeLoader>;

// Umbrella class for loading all node types, plus the camera.
// Also manages mappings between Godot node IDs and RealityKit Entity IDs.
class NodeLoaders : public godot::Object {
	GDCLASS(NodeLoaders, Object);

protected:
	static void _bind_methods() {}

public:
	NodeLoaders();

	template <typename T>
	T &get() { return std::get<T>(loaders); }

	template <typename T>
	const T &get() const { return std::get<T>(loaders); }

	static constexpr uint32_t size() { return std::tuple_size_v<NodeLoaderSet>; }

	template <typename Ret, typename Fn>
	Ret visit(godot::Node *p_node, Ret p_default, Fn &&p_fn) {
		[&]<size_t... Is>(std::index_sequence<Is...>) {
			((([&]() -> bool {
				if (auto *n = std::get<Is>(loaders).cast(p_node)) {
					emplace_replace(&p_default, p_fn(std::get<Is>(loaders), n));
					return true;
				}
				return false;
			})()) || ...);
		}(std::make_index_sequence<std::tuple_size_v<NodeLoaderSet>>{});
		return static_cast<const Ret &>(p_default);
	}

	template <typename Fn>
	void visit(godot::Node *p_node, Fn &&p_fn) {
		[&]<size_t... Is>(std::index_sequence<Is...>) {
			((([&]() -> bool {
				if (auto *n = std::get<Is>(loaders).cast(p_node)) {
					p_fn(std::get<Is>(loaders), n);
					return true;
				}
				return false;
			})()) || ...);
		}(std::make_index_sequence<std::tuple_size_v<NodeLoaderSet>>{});
	}

	void node_added(godot::Node *p_node);
	void node_removed(godot::Node *p_node);

	swift::Optional<GodotRealityKit::Entity> find_entity(godot::Node *p_node) const {
		if (!p_node) {
			return swift::Optional<GodotRealityKit::Entity>::none();
		}

		const uint64_t node_id = p_node->get_instance_id();
		const auto found = node_id_to_entity_id.find(node_id);
		return found ? root_entity.findEntity(found->value) : swift::Optional<GodotRealityKit::Entity>::none();
	}

	godot::Node *find_node(uint64_t p_entity_id) const {
		const auto found = entity_id_to_node_id.find(p_entity_id);
		return found ? get_node_instance(found->value) : nullptr;
	}

	void map_entity(godot::Node *p_node, uint64_t p_entity_id) {
		const uint64_t node_id = p_node->get_instance_id();
		node_id_to_entity_id.insert(node_id, p_entity_id);
		entity_id_to_node_id.insert(p_entity_id, node_id);
	}

	void unmap_entity(godot::Node *p_node) {
		const uint64_t node_id = p_node->get_instance_id();
		if (auto found = node_id_to_entity_id.find(node_id)) {
			entity_id_to_node_id.erase(found->value);
			node_id_to_entity_id.remove(found);
		}
	}

	CameraLoader &get_cameras() { return get<CameraLoader>(); }
	DirectionalLightLoader &get_directional_lights() { return get<DirectionalLightLoader>(); }
	PointLightLoader &get_point_lights() { return get<PointLightLoader>(); }
	SpotLightLoader &get_spot_lights() { return get<SpotLightLoader>(); }
	GodotRealityKit::Entity get_root_entity() const { return root_entity; }

	// MARK: Hierarchical effects

	template <typename Fn>
	void for_each_effect(Fn &&p_fn) {
		effects.for_each(std::forward<Fn>(p_fn));
	}

	template <typename Effect>
	bool has_effect_root(uint64_t p_root_id) {
		return effects.template get<Effect>().has(p_root_id);
	}

	// The rid of the nearest ancestor-or-self effect root, per effect, resolved against each
	// HierarchicalEffect's root_id_to_rid rather than another node's cached rid, so the result
	// does not depend on the order loaders process their dirty nodes in.
	ResolvedEffectRIDs resolve_inherited_effects(godot::Node *p_node);

	godot::RID hover_effect_create(uint64_t p_root_id, const HoverEffectStyle &p_style) {
		HierarchicalEffect<HoverEffect> &hover_effects = effects.get<HoverEffect>();
		ERR_FAIL_COND_V_MSG(hover_effects.has(p_root_id), godot::RID(), "Node cannot have multiple hover effects");
		return hover_effects.create(p_root_id, HoverEffect{ .style = p_style });
	}

	void hover_effect_free(uint64_t p_root_id) {
		HierarchicalEffect<HoverEffect> &hover_effects = effects.get<HoverEffect>();
		ERR_FAIL_COND(!hover_effects.has(p_root_id));
		hover_effects.free(p_root_id);
	}

	const HoverEffectStyle &get_hover_effect_style(godot::RID p_rid) {
		HierarchicalEffect<HoverEffect> &hover_effects = effects.get<HoverEffect>();
		return hover_effects.get_effect(p_rid).style;
	}

	godot::RID portal_create(uint64_t p_root_id) {
		HierarchicalEffect<PortalEffect> &portal_effects = effects.get<PortalEffect>();

		godot::RID rid;
		if (!portal_effects.has(p_root_id)) {
			GodotRealityKit::Entity portal_world_entity = GodotRealityKit::Entity::initAndMaterialize();
			portal_world_entity.setParent(swift::Optional<GodotRealityKit::Entity>::some(root_entity));
			portal_world_entity.setIsWorld(true);

			const PortalEffect effect = PortalEffect{
				.world_entity = portal_world_entity,
				.ref_count = 0
			};

			rid = portal_effects.create(p_root_id, effect);
		} else {
			rid = portal_effects.get(p_root_id);
		}

		if (rid.is_valid()) {
			PortalEffect &effect = portal_effects.get_effect(rid);
			effect.ref_count++;
		}

		return rid;
	}

	void portal_free(uint64_t p_root_id) {
		HierarchicalEffect<PortalEffect> &portal_effects = effects.get<PortalEffect>();
		ERR_FAIL_COND(!portal_effects.has(p_root_id));

		const godot::RID rid = portal_effects.get(p_root_id);
		PortalEffect &effect = portal_effects.get_effect(rid);

		effect.ref_count--;
		if (effect.ref_count == 0) {
			portal_effects.free(p_root_id);
		}
	}

	GodotRealityKit::Entity get_portal_world_entity(godot::RID p_rid) {
		HierarchicalEffect<PortalEffect> &portal_effects = effects.get<PortalEffect>();
		return portal_effects.get_effect(p_rid).world_entity;
	}

	godot::RID portal_crossing_create(uint64_t p_root_id) {
		HierarchicalEffect<PortalCrossingEffect> &portal_crossing_effects = effects.get<PortalCrossingEffect>();
		ERR_FAIL_COND_V_MSG(portal_crossing_effects.has(p_root_id), godot::RID(), "Node cannot have multiple portal crossings");
		return portal_crossing_effects.create(p_root_id, PortalCrossingEffect{});
	}

	void portal_crossing_free(uint64_t p_root_id) {
		HierarchicalEffect<PortalCrossingEffect> &portal_crossing_effects = effects.get<PortalCrossingEffect>();
		ERR_FAIL_COND(!portal_crossing_effects.has(p_root_id));
		portal_crossing_effects.free(p_root_id);
	}

	godot::RID ibl_create(uint64_t p_root_id, GodotRealityKit::Entity p_ibl_entity) {
		HierarchicalEffect<IBLEffect> &ibl_effects = effects.get<IBLEffect>();
		ERR_FAIL_COND_V_MSG(ibl_effects.has(p_root_id), godot::RID(), "Node cannot have multiple IBLs");
		return ibl_effects.create(p_root_id, IBLEffect{ .ibl_entity = p_ibl_entity });
	}

	void ibl_free(uint64_t p_root_id) {
		HierarchicalEffect<IBLEffect> &ibl_effects = effects.get<IBLEffect>();
		ERR_FAIL_COND(!ibl_effects.has(p_root_id));
		ibl_effects.free(p_root_id);
	}

	GodotRealityKit::Entity get_ibl_entity(godot::RID p_rid) {
		HierarchicalEffect<IBLEffect> &ibl_effects = effects.get<IBLEffect>();
		return ibl_effects.get_effect(p_rid).ibl_entity;
	}

	godot::RID environment_lighting_create(uint64_t p_root_id, float p_weight) {
		HierarchicalEffect<EnvironmentLightingEffect> &lighting_effects = effects.get<EnvironmentLightingEffect>();
		ERR_FAIL_COND_V_MSG(lighting_effects.has(p_root_id), godot::RID(), "Node cannot have multiple environment lighting configurations");
		return lighting_effects.create(p_root_id, EnvironmentLightingEffect{ .weight = p_weight });
	}

	void environment_lighting_update(uint64_t p_root_id, float p_weight) {
		HierarchicalEffect<EnvironmentLightingEffect> &lighting_effects = effects.get<EnvironmentLightingEffect>();
		ERR_FAIL_COND(!lighting_effects.has(p_root_id));
		lighting_effects.get_effect(lighting_effects.get(p_root_id)).weight = p_weight;
		lighting_effects.mark_changed(p_root_id);
	}

	void environment_lighting_free(uint64_t p_root_id) {
		HierarchicalEffect<EnvironmentLightingEffect> &lighting_effects = effects.get<EnvironmentLightingEffect>();
		ERR_FAIL_COND(!lighting_effects.has(p_root_id));
		lighting_effects.free(p_root_id);
	}

	float get_environment_lighting_weight(godot::RID p_rid) {
		HierarchicalEffect<EnvironmentLightingEffect> &lighting_effects = effects.get<EnvironmentLightingEffect>();
		return lighting_effects.get_effect(p_rid).weight;
	}

	// A rigid (scale = 1) rotation + translation; the clipping rig is always rigid so that the
	// anchor's inverse is representable exactly (an RK Transform cannot store shear).
	struct ClippingRigid {
		GodotRealityKit::Vector4 rotation = GodotRealityKit::Vector4::init(0, 0, 0, 1);
		GodotRealityKit::Vector3 translation = GodotRealityKit::Vector3::init(0, 0, 0);
	};

	struct ClippingParams {
		ClippingRigid clipper; // rigid(T)
		ClippingRigid anchor; // rigid(T)^-1
		GodotRealityKit::Vector3 bounds_min = GodotRealityKit::Vector3::init(0, 0, 0);
		GodotRealityKit::Vector3 bounds_max = GodotRealityKit::Vector3::init(0, 0, 0); // scale-folded, componentwise-sorted
		bool feather_enabled = false;
		GodotRealityKit::Vector3 feather_inset = GodotRealityKit::Vector3::init(0, 0, 0);
		uint32_t falloff = 0;
	};

	// GodotRealityKit::Entity has no default constructor, so it can't live directly in a
	// LocalVector (LocalVector::resize/clear requires default-constructibility of T even on the
	// unreachable shrink path). Give the pending-teardown entities a default-constructible home.
	struct ClippingRigEntities {
		GodotRealityKit::Entity clipper = GodotRealityKit::Entity::init();
		GodotRealityKit::Entity anchor = GodotRealityKit::Entity::init();
	};

	godot::RID clipping_create(uint64_t p_root_id, const ClippingParams &p_params) {
		HierarchicalEffect<ClippingEffect> &clipping_effects = effects.get<ClippingEffect>();
		ERR_FAIL_COND_V_MSG(clipping_effects.has(p_root_id), godot::RID(), "Node cannot have multiple clipping effects");
		const GodotRealityKit::Vector3 unit = GodotRealityKit::Vector3::init(1, 1, 1);

		GodotRealityKit::Entity clipper = GodotRealityKit::Entity::initAndMaterialize();
		clipper.setParent(swift::Optional<GodotRealityKit::Entity>::some(root_entity));
		clipper.setTransform(unit, p_params.clipper.rotation, p_params.clipper.translation);
		clipper.setClippingComponent(p_params.bounds_min, p_params.bounds_max, p_params.feather_enabled, p_params.feather_inset, p_params.falloff);

		GodotRealityKit::Entity anchor = GodotRealityKit::Entity::initAndMaterialize();
		anchor.setParent(swift::Optional<GodotRealityKit::Entity>::some(clipper));
		anchor.setTransform(unit, p_params.anchor.rotation, p_params.anchor.translation);

		return clipping_effects.create(p_root_id, ClippingEffect{ .clipper_entity = clipper, .anchor_entity = anchor });
	}

	void clipping_update(uint64_t p_root_id, const ClippingParams &p_params) {
		HierarchicalEffect<ClippingEffect> &clipping_effects = effects.get<ClippingEffect>();
		ERR_FAIL_COND(!clipping_effects.has(p_root_id));
		const GodotRealityKit::Vector3 unit = GodotRealityKit::Vector3::init(1, 1, 1);

		ClippingEffect &effect = clipping_effects.get_effect(clipping_effects.get(p_root_id));
		effect.clipper_entity.setTransform(unit, p_params.clipper.rotation, p_params.clipper.translation);
		effect.anchor_entity.setTransform(unit, p_params.anchor.rotation, p_params.anchor.translation);
		effect.clipper_entity.setClippingComponent(p_params.bounds_min, p_params.bounds_max, p_params.feather_enabled, p_params.feather_inset, p_params.falloff);
	}

	void clipping_free(uint64_t p_root_id) {
		HierarchicalEffect<ClippingEffect> &clipping_effects = effects.get<ClippingEffect>();
		ERR_FAIL_COND(!clipping_effects.has(p_root_id));

		// Capture the rig entities before free() discards the effect struct. free() only queues a
		// propagation that reparents the subtree back to root; that reparent must land (in
		// NodeLoaders::update, after the flush) before we drop the rig, or content is momentarily
		// orphaned. So defer dematerialize() to the teardown drain instead of doing it here.
		ClippingEffect &effect = clipping_effects.get_effect(clipping_effects.get(p_root_id));
		clipping_pending_teardown.push_back({ .clipper = effect.clipper_entity, .anchor = effect.anchor_entity });
		clipping_effects.free(p_root_id);
	}

	GodotRealityKit::Entity get_clip_reparent_anchor(godot::RID p_rid) {
		HierarchicalEffect<ClippingEffect> &clipping_effects = effects.get<ClippingEffect>();
		return clipping_effects.get_effect(p_rid).anchor_entity;
	}

	void initialize(GodotRealityKit::Entity p_root_entity) {
		root_entity = p_root_entity;
	}

	void update_deps(ResourceLoaderSet &p_resource_loaders);

	void update_transforms();
	void update_dirty_flags(const ResourceLoaderSet &p_resource_loaders);
	void update_visibility_states(const ResourceLoaderSet &p_resource_loaders);
	void update_deps_usage(ResourceLoaderSet &p_resource_loaders);

	void update(ResourceLoaderSet &p_resource_loaders);

	void reset_dirty();

private:
	template <typename Effect>
	friend class HierarchicalEffect;

	NodeLoaderSet loaders;

	godot::HashMap<uint64_t, uint64_t> node_id_to_entity_id;
	godot::HashMap<uint64_t, uint64_t> entity_id_to_node_id;

	GodotRealityKit::Entity root_entity = GodotRealityKit::Entity::initAndMaterialize();

	HierarchicalEffectSet effects{ this };

	// Drained by NodeLoaders::update, after flush_propagations has reparented removed clips'
	// subtrees back to root, so it's safe to dematerialize the rig entities at that point.
	godot::LocalVector<ClippingRigEntities> clipping_pending_teardown;
};

} // namespace gdrk

#endif // NODE_LOADERS_H
