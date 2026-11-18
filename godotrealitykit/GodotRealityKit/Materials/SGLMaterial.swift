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

import RealityKit

protocol ReferenceHashable: AnyObject, Hashable {}
extension ReferenceHashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public struct SGLMaterialUpdateComponent: Component {
    typealias ModelMaterialParameters = [(name: String, value: MaterialParameters.Value)]
    
	var modelMaterials: [(SGLMaterial, ModelMaterialParameters)]
    
    func getMaterialForModel(index: Int) -> ShaderGraphMaterial? {
        let (material, modelMaterialParameters) = self.modelMaterials[index]
        if var materialValue = material.value {
            for (name, value) in modelMaterialParameters {
                try? materialValue.setParameter(name: name, value: value)
            }
            
            return materialValue
        } else {
            return nil
        }
    }
}

class SGLMaterialUpdateSystem: System {
	static let query = EntityQuery(where: .has(SGLMaterialUpdateComponent.self))
    
	required init(scene: Scene) {
	}

	func update(context: SceneUpdateContext) {
        var materials: Set<SGLMaterial> = .init()
        context.entities(matching: SGLMaterialUpdateSystem.query, updatingSystemWhen: .rendering).forEach({ entity in
			let updateComponent = entity.components[SGLMaterialUpdateComponent.self]!
            for (materialIndex, modelMaterial) in updateComponent.modelMaterials.enumerated() {
                let (material, modelMaterialParameters) = modelMaterial
                if material.dirty, let materialForModel = updateComponent.getMaterialForModel(index: materialIndex) {
                    entity.components[ModelComponent.self]?.materials[materialIndex] = materialForModel
                    materials.insert(material)
                }
            }
		})

        for material in materials {
            material.dirty = false
        }
	}
}

public class SGLMaterialLoadResult {
	public let result: SGLProgram
	public let errorDescription: String?
	
	public static func fromRawPointer(_ rawPointer: UnsafeMutableRawPointer) -> SGLMaterialLoadResult {
		return Unmanaged<SGLMaterialLoadResult>.fromOpaque(rawPointer).takeUnretainedValue()
	}
	
	init(result: ShaderGraphMaterial?, errorDescription: String?) {
		self.result = SGLProgram(result)
		self.errorDescription = errorDescription
	}
}

public enum ParameterType {
	case Bool
	case Float
	case Vector2
	case Vector3
	case Vector4
	case Color
	case Texture
	
	func cacheStorageSize() -> UInt16 {
		switch self {
			case .Bool:
				return 1
			case .Float:
				return 4
			case .Vector2:
				return 8
			case .Vector3:
				return 12
			case .Vector4:
				return 16
			case .Color:
				return 4
			case .Texture:
				return 4
		}
	}
}

public class SGLProgram: @unchecked Sendable {
    static let transparentSortGroup = RealityKit.ModelSortGroup()
    static let depthPostpassSortGroup = RealityKit.ModelSortGroup(depthPass: .postPass)
    static let depthPrepassSortGroup = RealityKit.ModelSortGroup(depthPass: .prePass)
    
	static let debugShaderDump: Bool = {
		let value = UserDefaults.standard.bool(forKey: "gdrk-debug-shader-dump")
		if value {
			print("User default \"gdrk-debug-shader-dump\" enabled: will save shaders to disk, for debugging purposes")
		}
		return value
	}()
	
	public static func load(
		named name: String,
		from string: String,
		delegate: GDRKMaterialLoadDelegate
	) {
		assumeMainActor(delegate) { delegate in
			guard let data = string.data(using: .utf8) else {
				print("Failed to create UTF8 encoded data from string")
				return
			}
			
			withBlockingAsyncTaskScope{
				do {
					if Self.debugShaderDump {
						Task.detached() {
							func strHash(_ str: String) -> UInt64 {
								var result = UInt64 (5381)
								let buf = [UInt8](str.utf8)
								for b in buf {
									result = 127 * (result & 0x00ffffffffffffff) + UInt64(b)
								}
								return result
							}
							let contentHash = strHash(string) % 9999 // stable hash across runs
							let randomID = UUID().hashValue % 9999 // random
							let fileName = "\(name)_\(contentHash)_\(randomID).usda"
							let url = FileManager.default.temporaryDirectory.appending(path: fileName)
							try! data.write(to: url)
							print("Wrote shader to \(url)")
						}
					}
					
					let shaderGraphMaterial = try await RealityKit.ShaderGraphMaterial(named: name, from: data)
					let loadResult = SGLMaterialLoadResult(result: shaderGraphMaterial, errorDescription: nil)
					delegate.onCompleted(consuming: Unmanaged<SGLMaterialLoadResult>.passRetained(loadResult).toOpaque())
				} catch {
					let loadResult = SGLMaterialLoadResult(result: nil, errorDescription: "Failed to load base material: \(error)")
					delegate.onCompleted(consuming: Unmanaged<SGLMaterialLoadResult>.passRetained(loadResult).toOpaque())
				}
			}
		}
	}

	struct ParameterDescriptor {
		let defaultValue: MaterialParameters.Value?
		let handle: MaterialParameters.Handle
		let name: String
		
		init(_ name: String,
			 _ defaultValue: MaterialParameters.Value?) {
			self.defaultValue = defaultValue
			self.handle = ShaderGraphMaterial.parameterHandle(name: name)
			self.name = name
		}
	}
	
	typealias ParameterBlockDescriptor = Array<ParameterDescriptor>
	
	class ParameterBlock {
		var values: [MaterialParameters.Value?]
		
        init(_ values: [MaterialParameters.Value?]) {
			self.values = values
		}
		
        func set(_ material: SGLMaterial, _ index: UInt8, _ value: MaterialParameters.Value) throws -> Bool {
			let idx = Int(index)
			if values[idx] != value, let paramDesc = material.program?.parameterBlockDescriptor[idx] {
				try material.value?.setParameter(handle: paramDesc.handle, value: value)
				values[idx] = value;
				return true
			}
			return false
		}
	}

	var sgMaterial: ShaderGraphMaterial? = nil
	var parameterBlockDescriptor: ParameterBlockDescriptor = .init()
	var sortOrder: Int32 = 0
    var sortGroup: ModelSortGroup? = nil
	var transparent: Bool = false
    var billboard: Bool = false
    var boundsMultiplier: Float = 1.0
    var isBrokenMaterial: Bool = false
	
	init(_ material: ShaderGraphMaterial?) {
		sgMaterial = material
	}
	
	public init() {
		sgMaterial = nil
	}
    
    public func setIsBrokenMaterial(isBrokenMaterial: Bool) {
        self.isBrokenMaterial = isBrokenMaterial
    }
	
	public func instantiate() -> SGLMaterial {
        return SGLMaterial(program: self)
	}
	public func makeVariant() -> SGLProgram {
		let variant = SGLProgram(sgMaterial)
		// parameterBlockDescriptor intentionally not copied; finalize() will populate it
		return variant
	}
	public func bindParameter(_ name: String, _ value: MaterialParameters.Value? = nil) -> UInt8 {
		parameterBlockDescriptor.append(ParameterDescriptor(name, value))
		return UInt8(parameterBlockDescriptor.count - 1)
	}
	public func bindNullParameter(_ name: String) -> UInt8 {
		return bindParameter(name, nil)
	}
	public func bindBoolParameter(_ name: String, _ value: Bool) -> UInt8  {
        return bindParameter(name, .int(value ? 1 : 0))
	}
	public func bindIntParameter(_ name: String, _ value: Int32) -> UInt8  {
		return bindParameter(name, .int(value))
	}
	
	public func bindFloatParameter(_ name: String, _ value: Float) -> UInt8  {
		return bindParameter(name, .float(value))
	}
	public func bindFloat2Parameter(_ name: String, _ value: Vector2) -> UInt8  {
		return bindParameter(name, .simd2Float(value.to_simd()))
	}
	public func bindFloat3Parameter(_ name: String, _ value: Vector3) -> UInt8  {
		return bindParameter(name, .simd3Float(value.to_simd()))
	}
	public func bindFloat4Parameter(_ name: String, _ value: Vector4) -> UInt8  {
		return bindParameter(name, .simd4Float(value.to_simd()))
	}
	public func bindColorParameter(_ name: String, _ value: GDRKColorRef) -> UInt8  {
		return bindParameter(name, .color(value))
	}
	public func bindTextureParameter(_ name: String, _ value: TextureResource) -> UInt8  {
		var v: MaterialParameters.Value? = nil
		if let textureValue = value.value {
			v = .textureResource(textureValue)
		}
		return bindParameter(name, v)
	}
	
	public func setReadsDepth(value: Bool) {
		sgMaterial?.readsDepth = value
	}

	public func setWritesDepth(value: Bool) {
		sgMaterial?.writesDepth = value
	}

	public func setSortOrder(value: Int32) {
		sortOrder = value
	}
    
	public func getSortOrder() -> Int32 {
		return sortOrder
	}
    
    public func setBillboard(value: Bool) {
        billboard = value
    }
    
    public func setBoundsMultiplier(value: Float) {
        boundsMultiplier = value
    }
	
	public func setCullMode(value: Int) {
		switch value {
		case 0:
			sgMaterial?.faceCulling = .back
		case 1:
			sgMaterial?.faceCulling = .front
		case 2:
			sgMaterial?.faceCulling = .none
		default:
			print("SGLProgram.setCullMode: Invalid cull mode specified")
		}
	}
    
    public func setSortGroup(value: Int) {
        switch value {
        case 0:
            sortGroup = nil
        case 1:
            sortGroup = SGLProgram.transparentSortGroup
        case 2:
            sortGroup = SGLProgram.depthPostpassSortGroup
        case 3:
            sortGroup = SGLProgram.depthPrepassSortGroup
        default:
            print("SGLProgram.setSortGroup: Invalid sort group value")
        }
    }
}

public class SGLMaterial: @unchecked Sendable, ReferenceHashable {
    var program: SGLProgram? = nil
	var value: ShaderGraphMaterial? = nil
	var parameterBlock: SGLProgram.ParameterBlock?
	var dirty: Bool = false

	public init() {}
	
	init(program: SGLProgram) {
		self.program = program
		self.parameterBlock = SGLProgram.ParameterBlock(program.parameterBlockDescriptor.map({ paramDesc in
            return paramDesc.defaultValue
        }))
		self.value = program.sgMaterial
	}
	
	public static func brokenMaterial() -> SGLMaterial {
		
		return SGLMaterial()
	}
	
	public func isLoading() -> Bool {
		return self.program == nil
	}

	public func isSome() -> Bool {
		return self.value != nil
	}

	public func setWorldScale(value: Float) {
		do {
            try self.value?.setParameter(name: "_world_scale", value: .simd3Float(SIMD3<Float>(value, value, value)))
		} catch {
			print("SGLMaterial.setWorldScale: Error setting material parameter _world_scale: \(error)")
		}
	}

    private func setParameter(
        index: UInt8,
        value: MaterialParameters.Value,
        typeName: String
    ) {
        do {
            let newDirty: Bool = try self.parameterBlock?.set(self, index, value) ?? false
            dirty = newDirty || dirty
        } catch {
            let name = program?.parameterBlockDescriptor[Int(index)].name
            print("SGLMaterial.set\(typeName): Error setting material param \(name): \(error)")
        }
    }

    public func setBool(index: UInt8, value: Bool) {
        setParameter(index: index, value: .int(value ? 1 : 0), typeName: "Bool")
    }

    public func setInt(index: UInt8, value: Int32) {
        setParameter(index: index, value: .int(value), typeName: "Int")
    }

    public func setFloat(index: UInt8, value: Float) {
        setParameter(index: index, value: .float(value), typeName: "Float")
    }

    public func setFloat2(index: UInt8, value: Vector2) {
        setParameter(index: index, value: .simd2Float(value.to_simd()), typeName: "Float2")
    }

    public func setFloat3(index: UInt8, value: Vector3) {
        setParameter(index: index, value: .simd3Float(value.to_simd()), typeName: "Float3")
    }

    public func setFloat4(index: UInt8, value: Vector4) {
        setParameter(index: index, value: .simd4Float(value.to_simd()), typeName: "Float4")
    }

    public func setTexture(index: UInt8, texture: TextureResource) {
        guard let textureValue = texture.value else {
            return
        }

        setParameter(index: index, value: .textureResource(textureValue), typeName: "Texture")
    }

}
