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

import codecs
import os
import subprocess
import sys

import common_compiler_flags


def has_visionos_osxcross():
    return "OSXCROSS_VISIONOS" in os.environ


def options(opts):
    opts.Add("visionos_min_version", "Target minimum visionos version", "2.0")
    opts.Add("VISIONOS_TOOLCHAIN_PATH", "Path to visionOS toolchain", "")
    opts.Add("VISIONOS_SDK_PATH", "Path to the visionOS SDK", "")

    if has_visionos_osxcross():
        opts.Add("visionos_triple", "Triple for visionos toolchain", "")


def exists(env):
    return sys.platform == "darwin" or has_visionos_osxcross()


def generate(env):
    if env["arch"] not in ("universal", "arm64", "x86_64"):
        raise ValueError("Only universal, arm64, and x86_64 are supported on visionOS. Exiting.")

    sdk_name = "xrsimulator" if env["ios_simulator"] else "xros"
    target_flag = "-mtargetos=xros{}{}".format(env["visionos_min_version"], "-simulator" if env["ios_simulator"] else "")

    env.Append(ASFLAGS=[target_flag])
    env.Append(CCFLAGS=[target_flag])

    if sys.platform == "darwin":
        if env["VISIONOS_SDK_PATH"] == "":
            try:
                env["VISIONOS_SDK_PATH"] = codecs.utf_8_decode(
                    subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"]).strip()
                )[0]
            except (subprocess.CalledProcessError, OSError):
                raise ValueError(
                    "Failed to find SDK path while running xcrun --sdk {} --show-sdk-path.".format(sdk_name)
                )
                
        if env["VISIONOS_TOOLCHAIN_PATH"] == "":
            try:
                env["VISIONOS_TOOLCHAIN_PATH"] = codecs.utf_8_decode(
                    subprocess.check_output(["xcrun", "--show-toolchain-path"]).strip()
                )[0]
            except (subprocess.CalledProcessError, OSError):
                raise ValueError(
                    "Failed to find toolchain path while running xcrun  --show-toolchain-path."
                )

        compiler_path = env["VISIONOS_TOOLCHAIN_PATH"] + "/usr/bin/"
        env["CC"] = compiler_path + "clang"
        env["CXX"] = compiler_path + "clang++"
        env["AR"] = compiler_path + "ar"
        env["RANLIB"] = compiler_path + "ranlib"
        env["SHLIBSUFFIX"] = ".dylib"
        env["ENV"]["PATH"] = env["VISIONOS_TOOLCHAIN_PATH"] + "/Developer/usr/bin/:" + env["ENV"]["PATH"]

    else:
        # OSXCross
        compiler_path = "$VISIONOS_TOOLCHAIN_PATH/usr/bin/${visionos_triple}"
        env["CC"] = compiler_path + "clang"
        env["CXX"] = compiler_path + "clang++"
        env["AR"] = compiler_path + "ar"
        env["RANLIB"] = compiler_path + "ranlib"
        env["SHLIBSUFFIX"] = ".dylib"

        env.Prepend(
            CPPPATH=[
                "$VISIONOS_SDK_PATH/usr/include",
                "$VISIONOS_SDK_PATH/System/Library/Frameworks/AudioUnit.framework/Headers",
            ]
        )

        env.Append(CCFLAGS=["-stdlib=libc++"])

        binpath = os.path.join(env["VISIONOS_TOOLCHAIN_PATH"], "usr", "bin")
        if binpath not in env["ENV"]["PATH"]:
            env.PrependENVPath("PATH", binpath)

    if env["arch"] == "universal":
        env.Append(LINKFLAGS=["-arch", "arm64"])
        env.Append(CCFLAGS=["-arch", "arm64"])
    else:
        env.Append(LINKFLAGS=["-arch", env["arch"]])
        env.Append(CCFLAGS=["-arch", env["arch"]])

    env.Append(CCFLAGS=["-isysroot", env["VISIONOS_SDK_PATH"]])
    env.Append(LINKFLAGS=["-isysroot", env["VISIONOS_SDK_PATH"], "-F" + env["VISIONOS_SDK_PATH"]])

    env.Append(CPPDEFINES=["VISIONOS_ENABLED", "UNIX_ENABLED"])

    # Refer to https://github.com/godotengine/godot/blob/master/platform/ios/detect.py:
    # Disable by default as it makes linking in Xcode very slow.
    if env["lto"] == "auto":
        env["lto"] = "none"

    common_compiler_flags.generate(env)
