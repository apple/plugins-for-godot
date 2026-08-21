## Prerequisites

- macOS with [Xcode](https://developer.apple.com/xcode/) installed (including the visionOS SDK)
    - visionOS 26 and visionOS 27 SDKs are supported.
    - The Metal toolchain is required to build Godot. Install it with `xcodebuild -downloadComponent metalToolchain`.
- [SCons](https://scons.org/) build system: `python3 -m pip install scons` or `brew install scons`
- Python 3.x

## Building the Plugin

GodotRealityKit depends on custom forks of Godot and [godot-cpp](https://github.com/godotengine/godot-cpp). Their URLs and branches are configured in `deps.conf`:

```ini
# Option 1: Use an existing shared workspace with pre-built deps (default)
SHARED_WORKSPACE=../../shared_workspace

# Option 2: Specify repository URLs to clone and build from source
GODOT_URL=<godot git repository URL>
GODOT_BRANCH=<godot commit or branch>
GODOT_CPP_URL=<godot-cpp git repository URL>
GODOT_CPP_BRANCH=<godot-cpp commit or branch>
```

Running `scons` with no arguments builds everything: builds dependencies (if not already present), builds the macOS editor framework and visionOS template framework, assembles the addon, and generates documentation.

```sh
scons
```

The addon is produced at `out/addons/GodotRealityKit/`.

To build with a release configuration:

```sh
scons config=release
```

### Individual build targets

| Command | Description |
|---|---|
| `scons deps` | Clone and build Godot + godot-cpp only |
| `scons framework platform=macos` | Build macOS framework only |
| `scons framework platform=visionos` | Build visionOS framework only |
| `scons addon` | Assemble addon for distribution |
| `scons docs` | Regenerate `doc_data.gen.cpp` from `doc_classes/*.xml` and rebuild the frameworks to embed the updated docs |

## Addon Structure

```
addons/GodotRealityKit/
    GodotRealityKit.gdextension
    plugin.cfg
    gdrk.gd
    gdrk_export.gd
    volume_camera_gizmo/
    directional_light_shadow_gizmo/
    macos.editor/                # or macos.template_release with config=release
        GodotRealityKit.framework
        godot_macos.zip
    macos.template_debug -> macos.editor
    visionos.template_debug/     # or visionos.template_release with config=release
        GodotRealityKit.framework
        godot_visionos.zip
```
