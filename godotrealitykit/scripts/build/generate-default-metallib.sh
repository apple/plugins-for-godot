#!/bin/bash

#===----------------------------------------------------------------------===#
# Copyright © 2026 Apple Inc.
#
# Licensed under the MIT license (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# LICENSE
#
#===----------------------------------------------------------------------===#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(realpath "$SCRIPT_DIR/../../")"

cd "$REPO_DIR/GodotRealityKit"

airFiles=()

mkdir -p "$METAL_LIBRARY_OUTPUT_DIR"

# Reproduce in the GodotRealityKit demo by adding a MeshInstance3D with a BoxMesh
# and StandardMaterial3D to the main RealityKit scene, exporting the visionOS
# Window app, and launching it on the visionOS 27 simulator. The box should render
# and the app should keep drawing. The old bridge compiled default.metallib with
# the macOS SDK for every target, so the simulator failed to create its render
# pipeline; the first draw made SimMetalHost abort with "Attempting to dispatch
# without pipeline set" and the app then lost its Metal XPC connection. Compiling
# with the active Apple platform SDK and target makes the same scene run normally.
case "${PLATFORM_NAME:-}" in
    macosx)
        metalSDK="macosx"
        metalTarget="air64-apple-macos${MACOSX_DEPLOYMENT_TARGET}"
        ;;
    xros)
        metalSDK="xros"
        metalTarget="air64-apple-xros${XROS_DEPLOYMENT_TARGET}"
        ;;
    xrsimulator)
        metalSDK="xrsimulator"
        metalTarget="air64-apple-xros${XROS_DEPLOYMENT_TARGET}-simulator"
        ;;
    *)
        echo "Unsupported Metal build platform: ${PLATFORM_NAME:-unset}" >&2
        exit 1
        ;;
esac

for metalFile in "$REPO_DIR/GodotRealityKit/Metal/"*.metal ; do
    f="$(basename "$metalFile")"
    airFile="$BUILT_PRODUCTS_DIR/${f%.metal}.air"
    airFiles+=("$airFile")

    xcrun -sdk "$metalSDK" metal \
          -c "$metalFile" \
          -o "$airFile" \
          -std=metal3.0 \
          -target "$metalTarget"
done

xcrun -sdk "$metalSDK" metallib \
            "${airFiles[@]}" \
            -o "$METAL_LIBRARY_OUTPUT_DIR/default.metallib"
