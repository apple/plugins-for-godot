# Changelog

## [1.2.0] - 2026-10-17

Materials:
- Split shader compilation into a reusable base program (SGL generation) and
  a per-material finalize step. `ProgramDescription` gains `base_program_hash()`
  so materials that differ only in per-instance state share one base program.
- Make depth prepass/postpass a `DepthPassMode` on the program description
  instead of a material variant. Base programs are shared across both passes.
  `MaterialLoader` now keys materials by depth pass mode and the variant logic
  is removed.
- Add material preloading: expose a GodotRealityKit object to GDScript with a
  static preload_material(path) that compiles the base program ahead of use.
- Include `render_priority` in the shader-material program hash.

Emission:
- Honor `BaseMaterial3D.emission_operator` instead of hardcoding Multiply.
  RealityKit samples an unset texture parameter as white and ignores the
  nodedef default, so the untextured case is specialized into the program
  rather than relying on Godot's `hint_default_black`. `emission_op` and
  `has_emission_texture` are added to the description hash so materials
  differing only in operator no longer collide in the cache.
- Fix UV and UV2 default expressions when used in the fragment shader. atlas
  subregions rendered as the full atlas.

Hierarchical effects (hover, portal, portal crossing, IBL, clipping):
- Resolve a node's effect RID by walking ancestors against each
  `HierarchicalEffect`'s `root_id_to_rid` instead of reading the immediate
  parent's cached RID. Loaders process dirty nodes in set order, not
  topological order, so a child updated before its parent read an unwritten
  RID. nodes are only dirty on the frame they are added, so the wrong RID was
  never re-derived.
- Start the walk at the node itself so effect roots stop overwriting their own
  RID with their parent's when re-dirtied.
- Stop register_entity from replaying a cached RID that free may have already
  handed back to the RID_Owner.
- Queue only the root id for propagation and resolve the RID at flush time, so
  a create and a free of the same root in one frame cannot propagate a
  reclaimed RID. Also removes the error spam on invalid RIDs.
- Apply clipping to collision objects regardless of ray-pickable state.
- Remove `HierarchicalEffect::get_rid`, `NodeLoaders::get_effect_rid` and
  `node_id_to_topo_priority`, all now unused.

Lighting:
- Scale a directional light's fixed shadow projection extents by a new
  `extra_light_frustum_scale`, derived from the ratio between scaled and
  unscaled world scaling compensation. Kept separate from world_scale, which
  RealityKit already accounts for on point lights, spot lights and materials.
  Fixes shadows clipping against the projection boundary and disappearing as
  the window moves in depth.

Skinning:
- Resolve deform state once per mesh and reuse it across surfaces.
- Cache the bind-to-bone mapping and inverse bind poses on the mesh, rebuilt
  on bind count change, `Skeleton3D` version change or skin swap, instead of
  reading them across the GDExtension boundary every frame.
- Fix SkeletonLoader never resetting its dirty flags.
- Capture bone poses from Skeleton3D's `"skeleton_updated"` signal, emitted after
  modifiers run and before poses are restored to T-pose. Removes
  `SkeletonLoader::add_skeleton_modifier`.

Meshes:
- Recreate `LowLevelMesh` buffers when vertex or index counts grow, not only
  when they shrink. A mesh that regenerates with more vertices (Label3D gaining
  characters) kept its smaller buffer and tripped Metal blit validation.

Input:
- Handle only `indirectPinch` events on visionOS, ignoring other kinds in the
  `SpatialEventCollection`, so a drag releases when the object is not looked at.

Environment:
- Skip skybox conversion in volumetric window presentation and in
  mixed/progressive immersion, where it cannot be seen.

Scene tree:
- Hold the `RealitySceneTree` in `SceneLoader` instead of the current scene root
  and bail when there is no tree. Fixes a crash when the scene tree is empty
  after a reload.

New Node: `RealityKitEnvironmentLightingConfiguration`
- Provides a mean for developers to control IBL contribution in the scene


## [1.1.0] - 2026-08-27

### Added
- Experimental `RealityClipping3D` node wrapping RealityKit's
  `ClippingComponent`, with an editor gizmo, to clip a subtree to a box with
  optional feathered edges.

### Documentation
- Documented the macOS RealityKit preview mode, including the Godot editor
  setting that must be disabled so the running game isn't embedded in the
  editor.
- `Building.md` now recommends the visionOS 27 SDK instead of visionOS 26.

### Refactors
- Split each node loader's monolithic `update()` into four phases
  (`update_transforms`, `update_dirty_flags`, `update_visibility_states`,
  `update_deps_usage`) orchestrated by `SceneLoader::update()`, and added
  `used_in_frame` tracking infrastructure to `ResourceLoader<>`. Gives per-frame
  optimizations a consistent place to skip unchanged work instead of each loader
  inventing its own dirty-tracking.
- Consolidated per-surface AABB computation into a single
  `MeshLoader::get_aabb()` call instead of querying `find_mesh` once per
  surface, cutting redundant lookups on meshes with many surfaces, and fixed
  missing "used in frame" marking on material textures.

### Performance
- Reduced deformation update cost, which was taking 25% of total plugin frame
  time, by reusing deform matrices across surfaces and caching bone inverse
  transforms instead of round-tripping to Godot every frame.
- MultiMesh instances now dematerialize their RealityKit entities when they stop
  contributing to the scene, instead of keeping them materialized and paying for
  entities that no longer render anything.
- Materials use default emission/albedo parameters when possible, so channels a
  material doesn't actually customize take RealityKit's cheap built-in path
  instead of a full shader graph evaluation.
- Fixed RealityKit rendering inefficiency caused by having SGL materials output
  a default vertex-position-offset parameter when no clipping is needed,
  avoiding an unnecessary second render pass for meshes that never move their
  vertices.
- Split mesh attribute (color/UV) encoding from position encoding, so animated
  (skinned/blend-shaped) meshes no longer re-upload unchanged color/UV data
  every frame just because positions are dirty.
- Mesh surfaces are now compacted into a single RealityKit `MeshResource` when
  possible, replacing a separate `Mesh::compacted` flag with a derived
  `compacted_resource` state, cutting the number of RealityKit resources a
  multi-surface mesh needs to create.

### Fixed
- Crash on background/foreground relaunch in immersive apps, caused by the
  engine re-running its setup and double-registering singletons.
- Crash after remaining idle for an extended period, caused by reentrant calls
  into the nested Godot view recursing the display link.
- Incorrect XROrigin scale relative to Compositor Services, caused by the bridge
  double-applying the world scale.
- Incorrect XROrigin translation relative to Compositor Services.
- Directional lights had incorrect intensity.
- Vertex colors lost their alpha channel; the vertex-color path now carries full
  RGBA.
- Possible crash when a MultiMesh isn't a valid instance.
- `MeshInstanceLoader` never showing a node that started invisible outside the
  volumetric window.
- Various log spam fixes.

### Fixed (Hand/Controller Tracking)
> These fixes only matter if you cherry-pick hand- and controller-tracking
> support into your own Godot engine checkout — this is not an officially
> supported workflow.

- Crash on visionOS caused by a missing privacy usage key in the exported
  `Info.plist` when RealityKit implicitly starts an ARKit session for spatial
  gestures.
- PSVR2 anchor failing to reappear after backgrounding and reconnecting a
  controller in windowed mode.
- PSVR2 tracking/anchoring failing in immersive space.
- PSVR2 anchoring using the wrong transform/offset in shared space and windowed
  apps.
- Hand tracking (anchor and joints) failing.
- Mismatched visionOS project settings preventing the hand- and controller-
  tracking privacy usage keys from being emitted in the exported `Info.plist`,
  which otherwise crashes the app when it requests hand/controller-tracking
  authorization.
