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

#ifndef ENVIRONMENT_LIGHTING_CONFIGURATION
#define ENVIRONMENT_LIGHTING_CONFIGURATION

#include <godot_cpp/classes/node.hpp>

namespace gdrk {

class RealityKitEnvironmentLightingConfiguration : public godot::Node {
	GDCLASS(RealityKitEnvironmentLightingConfiguration, Node)

protected:
	static void _bind_methods();

public:
	float get_environment_lighting_weight() const { return environment_lighting_weight; }
	void set_environment_lighting_weight(float p_weight) {
		environment_lighting_weight = p_weight;
	}

private:
	float environment_lighting_weight = 1.0f;
};

} // namespace gdrk

#endif // ENVIRONMENT_LIGHTING_CONFIGURATION
