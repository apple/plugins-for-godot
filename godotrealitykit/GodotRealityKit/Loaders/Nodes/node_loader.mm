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

#import "node_loader.h"
#import "directional_light_shadow_loader.h"
#import "node_loaders.h"

using namespace gdrk;

template <typename Derived, std::derived_from<godot::Node> Node>
void NodeLoaderBase<Derived, Node>::update(const ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;
	Base::for_each_dirty([&](uint32_t p_idx) {
		const ResolvedEffectRIDs resolved = owner->resolve_inherited_effects(nodes[p_idx]);
		resolved.for_each([&]<typename Effect>(const ResolvedEffectRID<Effect> &p_resolved) {
			static_cast<Derived *>(this)->template _update_effect<Effect>(p_idx, p_resolved.rid);
		});
	});
}

template <typename Derived, std::derived_from<godot::Node> Node>
void NodeLoader<Derived, Node>::register_entity(uint32_t p_index) {
	if (node_entities[p_index].registered) {
		return;
	}

	node_entities[p_index].registered = true;
	GodotRealityKit::Entity &entity = node_entities[p_index].entity;
	entity.materialize();

	GodotRealityKit::Entity root_entity = Base::owner->get_root_entity();
	entity.setParent(swift::Optional<GodotRealityKit::Entity>::some(root_entity));

	Node *node = Base::nodes[p_index];

	entity.setName(to_swift_string(node->get_name()));
	entity.setDebugInfo(typeid(Node).name(), to_swift_string(node->get_path().get_concatenated_names()));
	entity.setEnabled(node_entities[p_index].enabled);

	on_transform_changed(p_index, node_transform_states[p_index]);

	if constexpr (Derived::requires_node_entity_mapping) {
		Base::owner->map_entity(node, entity.id());
	}

	// Resolve rather than replaying node_effect_rids_set: a deferred registration
	// (CollisionObjectLoader's ray-pickable gating, MeshInstanceLoader's culling entry) can land
	// before the loader owning the effect has run, so the cached rid may be absent or may belong
	// to an effect that was freed earlier this frame.
	const ResolvedEffectRIDs resolved = Base::owner->resolve_inherited_effects(node);
	resolved.for_each([&]<typename Effect>(const ResolvedEffectRID<Effect> &p_resolved) {
		static_cast<Derived *>(this)->template _update_effect<Effect>(p_index, p_resolved.rid);
	});
}

template <typename Derived, std::derived_from<godot::Node> Node>
uint32_t NodeLoader<Derived, Node>::add(Node *p_node) {
	const uint32_t idx = Base::add(p_node);

	node_transform_states[idx] = godot::Transform3D();

	node_entities[idx].enabled = p_node->is_visible_in_tree();
	visibility_changed_collector.connect(p_node, idx);

	if constexpr (!Derived::manages_visibility_state) {
		mark_visible(idx);
	}
	if constexpr (!Derived::manages_entity_registrations) {
		register_entity(idx);
	}

	return idx;
}

template <typename Derived, std::derived_from<godot::Node> Node>
void NodeLoader<Derived, Node>::unregister_entity(uint32_t p_index, godot::Node *p_node) {
	if (!node_entities[p_index].registered) {
		return;
	}

	if constexpr (Derived::requires_node_entity_mapping) {
		Base::owner->unmap_entity(p_node);
	}

	node_entities[p_index].registered = false;
	node_entities[p_index].entity.dematerialize();
}

template <typename Derived, std::derived_from<godot::Node> Node>
uint32_t NodeLoader<Derived, Node>::remove(Node *p_node) {
	const uint32_t idx = Base::remove(p_node);
	unregister_entity(idx, p_node);
	mark_invisible(idx);
	visibility_changed_collector.disconnect(idx);
	return idx;
}

template <typename Derived, std::derived_from<godot::Node> Node>
void NodeLoader<Derived, Node>::on_transform_changed(uint32_t p_idx, const godot::Transform3D &transform) {
	if (!is_registered(p_idx)) {
		return;
	}
	node_entities[p_idx].entity.setTransform(to_vector3(transform.basis.get_scale()),
			to_vector4(transform.basis.get_rotation_quaternion()),
			to_vector3(transform.origin));
}

template <typename Derived, std::derived_from<godot::Node> Node>
void NodeLoader<Derived, Node>::update_transform_ifn(uint32_t p_idx) {
	if (!node_entities[p_idx].enabled) {
		return;
	}
	godot::Transform3D transform = Base::nodes[p_idx]->get_global_transform();
	if (node_transform_states[p_idx] != transform) {
		node_transform_states[p_idx] = transform;
		static_cast<Derived *>(this)->on_transform_changed(p_idx, transform);
	}
}

template <typename Derived, std::derived_from<godot::Node> Node>
void NodeLoader<Derived, Node>::update_transforms() {
	Base::for_each_valid([&](uint32_t p_idx) {
		update_transform_ifn(p_idx);
	});
}

template <typename Derived, std::derived_from<godot::Node> Node>
void NodeLoader<Derived, Node>::update(const ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;
	Base::update(p_resource_loaders);
}

template class gdrk::NodeLoader<RealityPortalMeshInstanceLoader, RealityPortalMeshInstance3D>;
template class gdrk::NodeLoader<MeshInstanceLoader, godot::MeshInstance3D>;
template class gdrk::NodeLoader<MultiMeshInstanceLoader, godot::MultiMeshInstance3D>;
template class gdrk::NodeLoader<GridMapLoader, godot::GridMap>;
template class gdrk::NodeLoader<CPUParticlesLoader, godot::CPUParticles3D>;
template class gdrk::NodeLoader<CollisionObjectLoader, godot::CollisionObject3D>;
template class gdrk::NodeLoader<SpriteLoader, godot::Sprite3D>;
template class gdrk::NodeLoader<CSGShape3DLoader, godot::CSGShape3D>;
template class gdrk::NodeLoader<DirectionalLightLoader, godot::DirectionalLight3D>;
template class gdrk::NodeLoader<PointLightLoader, godot::OmniLight3D>;
template class gdrk::NodeLoader<SpotLightLoader, godot::SpotLight3D>;
template class gdrk::NodeLoader<LabelLoader, godot::Label3D>;
template class gdrk::NodeLoader<ImageBasedLightLoader, gdrk::RealityImageBasedLight3D>;

template class gdrk::NodeLoaderBase<CameraLoader, godot::Node3D>;
template class gdrk::NodeLoaderBase<RealityHoverEffectLoader, RealityHoverEffect3D>;
template class gdrk::NodeLoaderBase<RealityPortalCrossingLoader, RealityPortalCrossing3D>;
template class gdrk::NodeLoaderBase<WorldEnvironmentLoader, godot::WorldEnvironment>;
template class gdrk::NodeLoaderBase<AnyNodeLoader, godot::Node>;
template class gdrk::NodeLoaderBase<RealityKitDirectionalLightShadow3DLoader, RealityKitDirectionalLightShadow3D>;
template class gdrk::NodeLoaderBase<RealityClippingLoader, RealityClipping3D>;
template class gdrk::NodeLoaderBase<RealityKitEnvironmentLightingConfigurationLoader, RealityKitEnvironmentLightingConfiguration>;
