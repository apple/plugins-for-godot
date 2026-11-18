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

#import "environment_lighting_configuration.h"

namespace gdrk {

void RealityKitEnvironmentLightingConfiguration::_bind_methods() {
	godot::ClassDB::bind_method(godot::D_METHOD("get_environment_lighting_weight"), &RealityKitEnvironmentLightingConfiguration::get_environment_lighting_weight);
	godot::ClassDB::bind_method(godot::D_METHOD("set_environment_lighting_weight", "weight"), &RealityKitEnvironmentLightingConfiguration::set_environment_lighting_weight);
	ADD_PROPERTY(godot::PropertyInfo(godot::Variant::FLOAT, "environment_lighting_weight", godot::PROPERTY_HINT_RANGE, "0,1,0.01"),
			"set_environment_lighting_weight", "get_environment_lighting_weight");
}

} // namespace gdrk
