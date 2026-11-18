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
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public func Initialize() {
	MainActor.assumeIsolated {
        _ = PhysicallyBasedMaterial()
		SGLMaterialUpdateComponent.registerComponent()
		SGLMaterialUpdateSystem.registerSystem()
		DebugVisualizationComponent.registerComponent()
	}
}

private struct UnsafeSendable<T> {
    nonisolated(unsafe) let value: T
}

func assumeMainActor<each Argument, Return>(_ arguments: repeat each Argument, body: @Sendable @MainActor (_ arguments: repeat each Argument) -> Return) -> Return {
    let smuggled = (repeat UnsafeSendable(value: each arguments))
    return MainActor.assumeIsolated { UnsafeSendable(value: body(repeat (each smuggled).value)) }.value
}

public func errPrint(msg: String) {
    MainActor.assumeIsolated{
        msg.withCString{ cStringMsg in
            Bridge.delegate?.printError(cStringMsg)
        }
    }
}

public func warnPrint(msg: String) {
    MainActor.assumeIsolated{
        msg.withCString{ cStringMsg in
            Bridge.delegate?.printWarning(cStringMsg)
        }
    }
}

internal enum GenericError: Swift.Error, LocalizedError {
    case value(String)

    var errorDescription: String? {
        switch self {
        case let .value(string):
            return string
        }
    }
}

// TODO: remove once simd can be used

public struct Vector2 : @unchecked Sendable {
	public let x: Float
	public let y: Float
	
	public init(x: Float, y: Float) {
		self.x = x
		self.y = y
	}
	
	init(_ v: SIMD3<Float>) {
		self.x = v.x
		self.y = v.y
	}
	
	func to_simd() -> SIMD2<Float> {
		return SIMD2<Float>(self.x, self.y)
	}
}

public struct Vector3 : @unchecked Sendable {
    public let x: Float
    public let y: Float
    public let z: Float
    
    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
    
    init(_ v: SIMD3<Float>) {
        self.x = v.x
        self.y = v.y
        self.z = v.z
    }
    
    func to_simd() -> SIMD3<Float> {
        return SIMD3<Float>(self.x, self.y, self.z)
    }
}

// TODO: confirm godot quaterion element ordering
public struct Vector4 : @unchecked Sendable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float
    
    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
    
    func to_simd_quat() -> simd_quatf {
        return simd_quatf(ix: self.x, iy: self.y, iz: self.z, r: self.w)
    }
    
    func to_simd() -> simd_float4 {
        return simd_float4(self.x, self.y, self.z, self.w)
    }
}

public struct Matrix44 : @unchecked Sendable {
    public let c0: Vector4
    public let c1: Vector4
    public let c2: Vector4
    public let c3: Vector4
    
    public init(c0: Vector4, c1: Vector4, c2: Vector4, c3: Vector4) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }
    
    func to_simd() -> simd_float4x4 {
        return simd_float4x4(c0.to_simd(), c1.to_simd(), c2.to_simd(), c3.to_simd())
    }
}

public struct VertexBufferFlags: OptionSet, Sendable
{
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
    
    public let rawValue: UInt8
    
    public static let hasNormals = VertexBufferFlags(rawValue: 0x01)
    public static let hasTangents = VertexBufferFlags(rawValue: 0x02)
    public static let hasColor = VertexBufferFlags(rawValue: 0x04)
    public static let hasUV1 = VertexBufferFlags(rawValue: 0x08)
    public static let hasUV2 = VertexBufferFlags(rawValue: 0x10)
    public static let hasCompressedAttributes = VertexBufferFlags(rawValue: 0x20)
    public static let hasCompressedUVs = VertexBufferFlags(rawValue: 0x40)
    public static let max = VertexBufferFlags(rawValue: 0x80)
}

public func isBlockingAsyncTaskRunning() -> Bool {
    MainActor.assumeIsolated{ Bridge.blockingAsyncTaskCount > 0 }
}

public func isSceneVisible() -> Bool {
    MainActor.assumeIsolated{ Bridge.sceneVisible }
}

public func hasOriginalScene() -> Bool {
#if os(macOS)
    return false
#else
    return MainActor.assumeIsolated{ Bridge.originalScene != nil }
#endif
}

public func startBlockingAsyncTask() {
	MainActor.assumeIsolated{ Bridge.blockingAsyncTaskCount += 1 }
}

public func stopBlockingAsyncTask() {
	MainActor.assumeIsolated{ Bridge.blockingAsyncTaskCount -= 1 }
}

#if !os(macOS)
public func destroyOriginalScene() {
	MainActor.assumeIsolated {
		guard let originalScene = Bridge.originalScene else {
			return
		}
		Bridge.originalScene = nil

		// Destroying the original scene triggers sceneDidDisconnect on Godot's
		// delegate, which calls on_focus_out() and stops the audio driver.
		// Observe the disconnect so we can restart audio afterward.
		var token: (any NSObjectProtocol)?
		token = NotificationCenter.default.addObserver(
			forName: UIScene.didDisconnectNotification,
			object: originalScene,
			queue: .main
		) { _ in
			if let token { NotificationCenter.default.removeObserver(token) }
			let sel = Selector(("sceneDidBecomeActive:"))
			if let appDelegate = UIApplication.shared.delegate,
			   appDelegate.responds(to: sel),
			   let activeScene = UIApplication.shared.connectedScenes.first {
				appDelegate.perform(sel, with: activeScene)
			}
			if let godotView = Bridge.originalViewController?.view,
			   godotView.responds(to: Selector(("stopRendering"))) {
				godotView.perform(Selector(("stopRendering")))
			}
		}

		UIApplication.shared.requestSceneSessionDestruction(originalScene.session, options: nil) { error in
			print("Error destroying scene session: \(error.localizedDescription)")
		}
	}
}
#endif

@MainActor
func withBlockingAsyncTaskScope(body: @escaping @MainActor () async -> Void) {
	startBlockingAsyncTask()
	
	Task { @MainActor in
		await body()
		
		stopBlockingAsyncTask()
	}
}

public struct MeshResource: @unchecked Sendable {
    let value: RealityKit.MeshResource?
    let flags: VertexBufferFlags
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var uvScale: SIMD4<Float>

    public init() {
        self.value = nil
        self.flags = VertexBufferFlags()
        self.boundsMin = .init(0, 0, 0)
        self.boundsMax = .init(0, 0, 0)
        self.uvScale = .init(0, 0, 0, 0)
    }

    public func isSome() -> Bool {
        return value != nil
    }

    public init?(from lowLevelMesh: LowLevelMesh,
                 withBoundsMin boundsMin: Vector3,
                 withBoundsMax boundsMax: Vector3,
                 withUVScale uvScale: Vector4) {
        let value = MainActor.assumeIsolated{
            var value: RealityKit.MeshResource? = nil
            do {
                value = try RealityKit.MeshResource(from: lowLevelMesh.value)
            } catch {
                print(error)
            }
            return value
        }
        
        if let value = value {
            self.value = value
            self.flags = lowLevelMesh.flags
            self.boundsMin = boundsMin.to_simd()
            self.boundsMax = boundsMax.to_simd()
            self.uvScale = uvScale.to_simd()
        } else {
            return nil
        }
    }
    
    public func lowLevelMesh() -> LowLevelMesh? {
        return MainActor.assumeIsolated{
            if let lowLevelMesh = self.value?.lowLevelMesh {
                return LowLevelMesh(
                    coreLowLevelMesh: lowLevelMesh,
                    flags: flags
                )
            } else {
                return nil
            }
        }
    }

    public mutating func setBounds(boundsMin: Vector3, boundsMax: Vector3) {
        self.boundsMin = boundsMin.to_simd()
        self.boundsMax = boundsMax.to_simd()
    }

    public mutating func setUVScale(uvScale: Vector4) {
        self.uvScale = uvScale.to_simd()
    }
}

public struct TextureResource: @unchecked Sendable {
    let value: RealityKit.TextureResource?
    let lowLevelValue: RealityKit.LowLevelTexture?

    public init() {
        self.value = nil
        self.lowLevelValue = nil
    }

    public func isSome() -> Bool {
        return value != nil
    }

    public init?(from lowLevelTexture: LowLevelTexture) {
        let value: RealityKit.TextureResource? = MainActor.assumeIsolated {
            do {
                return try RealityKit.TextureResource(from: lowLevelTexture.value)
            } catch {
                print(error)
            }
            return nil
        }
        
        if let value = value {
            self.value = value
            self.lowLevelValue = lowLevelTexture.value
        } else {
            return nil
        }
    }

    public func lowLevelTexture() -> LowLevelTexture? {
        self.lowLevelValue.map{ LowLevelTexture(value: $0) }
    }
}

public struct Skybox: @unchecked Sendable {

    enum Value {
        case none
        case color(CGColor)
        case texture(RealityKit.TextureResource)
    }

    var value: Value

    private init(value: Value) {
        self.value = value
    }

    public init() {
        self.value = .none
    }

    public func isSome() -> Bool {
        if case .none = value { return false }
        return true
    }

    public static func fromCGImage(_ cgimage: CGImage) -> Skybox {
        let value = MainActor.assumeIsolated {
            return try! RealityKit.TextureResource(image: cgimage, options: .init(semantic: .hdrColor))
        }
        return Skybox(value: .texture(value))
    }

    public static func fromTextureResource(_ value: TextureResource) -> Skybox {
        return Skybox(value: value.value.map { .texture($0) } ?? .none)
    }

    public static func fromCGColor(_ cgcolor: CGColor) -> Skybox {
        return Skybox(value: .color(cgcolor))
    }
}

public struct ShapeResource: @unchecked Sendable {
    let value: RealityKit.ShapeResource?

    public init() {
        self.value = nil
    }

    public func isSome() -> Bool {
        return value != nil
    }

    init(value: RealityKit.ShapeResource?) {
        self.value = value
    }
    
    public static func generateBox(width: Float, height: Float, depth: Float) -> ShapeResource {
        return MainActor.assumeIsolated{
            ShapeResource(value: RealityKit.ShapeResource.generateBox(width: width, height: height, depth: depth))
        }
    }
    
    public static func generateSphere(radius: Float) -> ShapeResource {
        return MainActor.assumeIsolated{
            ShapeResource(value: RealityKit.ShapeResource.generateSphere(radius: radius))
        }
    }
    
    public static func generateCapsule(height: Float, radius: Float) -> ShapeResource {
        return MainActor.assumeIsolated{
            ShapeResource(value: RealityKit.ShapeResource.generateCapsule(height: height, radius: radius))
        }
    }
    
    public static func generateConvex(from points: [Vector3]) -> ShapeResource {
        return MainActor.assumeIsolated{
            let simdPoints = points.map{$0.to_simd()}
            return ShapeResource(value: RealityKit.ShapeResource.generateConvex(from: simdPoints))
        }
    }
    
	// TODO: properly handle async creation of concave shape resources
//    public static func generateMesh(from resource: MeshResource) -> ShapeResource? {
//        guard let resourceValue = resource.value else {
//            return nil
//        }
//        MainActor.assumeIsolated{
//            Bridge.asyncTaskCount += 1
//        var res: ShapeResource? = nil
//        Task{ @MainActor in
//            res = try await ShapeResource(value: RealityKit.ShapeResource.generateStaticMesh(from: resourceValue))
//            Bridge.asyncTaskCount -= 1
//        }
//        return res
//    }
    
    public func offsetBy(translation: Vector3, rotation: Vector4) -> ShapeResource {
        return MainActor.assumeIsolated{
            ShapeResource(value: self.value?.offsetBy(rotation: rotation.to_simd_quat(), translation: translation.to_simd()))
        }
    }
}

public struct LowLevelMesh: @unchecked Sendable {
    let value: RealityKit.LowLevelMesh
    let flags: VertexBufferFlags

    public init?(vertexCount: Int, indexCount: Int, flags: VertexBufferFlags, format: GDRKVertexBufferFormat, isIndex16: Bool, partCount: Int) {
        var layouts = [RealityKit.LowLevelMesh.Layout(bufferIndex: 0, bufferStride: Int(format.vertex_stride))]
        var attributes = [RealityKit.LowLevelMesh.Attribute]()
        
        // LowLevelMeshes always receive decompressed data from the GPU pipeline:
        // positions are float3, normals/tangents are UNORM oct ushort2, UVs are float2.
        attributes += [RealityKit.LowLevelMesh.Attribute(semantic: .position, format: .float3, layoutIndex: 0, offset: Int(format.vertex_offset))]
        
        if flags.contains(.hasNormals) || flags.contains(.hasTangents) {
            let normalLayoutIndex = layouts.count
            layouts += [RealityKit.LowLevelMesh.Layout(bufferIndex: 0, bufferOffset: Int(format.normal_offset), bufferStride: Int(format.normal_tangent_stride))]
            let normalOffset = 0
            attributes += [RealityKit.LowLevelMesh.Attribute(semantic: .uv2, format: .ushort2Normalized, layoutIndex: normalLayoutIndex, offset: normalOffset)]
        
            if flags.contains(.hasTangents) {
                let tangentOffset = Int(format.tangent_offset) - Int(format.normal_offset)
                attributes += [RealityKit.LowLevelMesh.Attribute(semantic: .uv3, format: .ushort2Normalized, layoutIndex: normalLayoutIndex, offset: tangentOffset)]
            }
        }
        
        if flags.contains(.hasColor) || flags.contains(.hasUV1) || flags.contains(.hasUV2) {
            let attributeLayoutIndex = layouts.count
            layouts += [RealityKit.LowLevelMesh.Layout(bufferIndex: 1, bufferStride: Int(format.attribute_stride))]
            
            if flags.contains(.hasColor) {
                attributes += [RealityKit.LowLevelMesh.Attribute(semantic: .color, format: .uchar4Normalized, layoutIndex: attributeLayoutIndex, offset: Int(format.color_offset))]
            }
            
            if flags.contains(.hasUV1) {
                attributes += [RealityKit.LowLevelMesh.Attribute(semantic: .uv0, format: .float2, layoutIndex: attributeLayoutIndex, offset: Int(format.uv1_offset))]
            }

            if flags.contains(.hasUV2) {
                attributes += [RealityKit.LowLevelMesh.Attribute(semantic: .uv1, format: .float2, layoutIndex: attributeLayoutIndex, offset: Int(format.uv2_offset))]
            }
        }

        let indexType = isIndex16 ? MTLIndexType.uint16 : MTLIndexType.uint32
        let descriptor = RealityKit.LowLevelMesh.Descriptor(vertexCapacity: vertexCount,
                                                            vertexAttributes: attributes,
                                                            vertexLayouts: layouts,
                                                            indexCapacity: indexCount,
                                                            indexType: indexType)
        let value = MainActor.assumeIsolated{
            var value: RealityKit.LowLevelMesh? = nil
            do {
                value = try RealityKit.LowLevelMesh(descriptor: descriptor)
                
                let parts = (0 ..< partCount).map{
                    RealityKit.LowLevelMesh.Part(
                        materialIndex: $0,
                        bounds: RealityKit.BoundingBox()
                    )
                }
                
                value?.parts.replaceAll(parts)
            } catch {
                print("Error creating LowLevelMesh: \(error)")
            }
            return value
        }
        if let value = value {
            self.value = value
            self.flags = flags
        } else {
            return nil
        }
    }
    
    public init?(vertices: [Vector3]) {
        var boundsMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for vertex in vertices {
            boundsMin = min(boundsMin, vertex.to_simd())
            boundsMax = max(boundsMax, vertex.to_simd())
        }
        
        let vertexCount = vertices.count / 3
        let layouts = [RealityKit.LowLevelMesh.Layout(bufferIndex: 0, bufferStride: MemoryLayout<Float>.size * 3)]
        let attributes = [RealityKit.LowLevelMesh.Attribute(semantic: .position, format: .float3, offset: 0)]
        let descriptor = RealityKit.LowLevelMesh.Descriptor(vertexCapacity: vertexCount,
                                                            vertexAttributes: attributes,
                                                            vertexLayouts: layouts)
        
        let value = MainActor.assumeIsolated{
            var value: RealityKit.LowLevelMesh? = nil
            do {
                value = try RealityKit.LowLevelMesh(descriptor: descriptor)
                value?.parts.replaceAll([
                    RealityKit.LowLevelMesh.Part(
                        bounds: RealityKit.BoundingBox(min: boundsMin, max: boundsMax)
                    )
                ])
                
                value?.withUnsafeMutableBytes(bufferIndex: 0) { buffer in
                    let floatBuffer = buffer.bindMemory(to: Float.self)
                    for index in 0..<vertexCount {
                        floatBuffer[index * 3] = vertices[index].x
                        floatBuffer[index * 3 + 1] = vertices[index].y
                        floatBuffer[index * 3 + 2] = vertices[index].z
                    }
                }
            } catch {
                print("Error creating LowLevelMesh: \(error)")
            }
            return value
        }
        if let value = value {
            self.value = value
            self.flags = .init(rawValue: 0)
        } else {
            return nil
        }
    }
    
    init(
        coreLowLevelMesh: RealityKit.LowLevelMesh,
        flags: VertexBufferFlags
    ) {
        self.value = coreLowLevelMesh
        self.flags = flags
    }
    
    public func replace(using commandBuffer: any MTLCommandBuffer) -> any MTLBuffer {
        assumeMainActor(commandBuffer){ commandBuffer in
            let buf = self.value.replace(bufferIndex: 0, using: commandBuffer)
            return buf
        }
    }

    public func replaceAttributes(using commandBuffer: any MTLCommandBuffer) -> (any MTLBuffer)? {
        assumeMainActor(commandBuffer){ commandBuffer in
            if self.flags.contains(.hasColor) || self.flags.contains(.hasUV1) || self.flags.contains(.hasUV2) {
                let buf = self.value.replace(bufferIndex: 1, using: commandBuffer)
                return buf
            } else {
                return nil
            }
        }
    }

    public func replaceIndices(using commandBuffer: any MTLCommandBuffer) -> any MTLBuffer {
        return assumeMainActor(commandBuffer){ commandBuffer in
            let buf = self.value.replaceIndices(using: commandBuffer)
            return buf
        }
    }

    public func setBounds(boundsMin: Vector3, boundsMax: Vector3) {
        MainActor.assumeIsolated{
            let bounds = BoundingBox(min: boundsMin.to_simd(), max: boundsMax.to_simd())
            let parts = self.value.parts.map { part in
                var part = part
                part.bounds = bounds
                return part
            }
            self.value.parts.replaceAll(parts)
        }
    }

    public func setIndexCount(indexCount: Int) {
        MainActor.assumeIsolated{
            self.value.parts[0].indexCount = indexCount
        }
    }
    
    public func setIndexCounts(indexCounts: [Int], isIndex16: Bool) {
        var indexOffset = 0
        let indexSize = isIndex16 ? 2 : 4
        MainActor.assumeIsolated{
            for i in self.value.parts.indices {
                self.value.parts[i].indexCount = indexCounts[i]
                self.value.parts[i].indexOffset = indexOffset
                indexOffset += indexSize * indexCounts[i]
            }
        }
    }
}

public struct LowLevelTexture: @unchecked Sendable {
    let value: RealityKit.LowLevelTexture
    
    public init?() {
        self.value = MainActor.assumeIsolated{
            return try! RealityKit.LowLevelTexture(descriptor: RealityKit.LowLevelTexture.Descriptor())
        }
    }
    
    public init?(textureType: MTLTextureType,
                 pixelFormat: MTLPixelFormat,
                 width: Int,
                 height: Int,
                 depth: Int,
                 mipmapLevelCount: Int,
                 arrayLength: Int,
                 textureUsage: UInt, // Can't use MTLTextureUsage here for some reason
                 swizzle: MTLTextureSwizzleChannels
    ) {
        let descriptor = RealityKit.LowLevelTexture.Descriptor(
            textureType: textureType,
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            depth: depth,
            mipmapLevelCount: mipmapLevelCount,
            arrayLength: arrayLength,
            textureUsage: MTLTextureUsage(rawValue: textureUsage),
            swizzle: swizzle
        )
        
        let value = MainActor.assumeIsolated{
            var value: RealityKit.LowLevelTexture? = nil
            do {
                value = try RealityKit.LowLevelTexture(descriptor: descriptor)
            } catch {
                print(error)
            }
            return value
        }
        if let value = value {
            self.value = value
        } else {
            return nil
        }
    }
    
    init(value: RealityKit.LowLevelTexture) {
        self.value = value
    }
    
    public func replace(using commandBuffer: MTLCommandBuffer) -> MTLTexture {
        return assumeMainActor(commandBuffer){ commandBuffer in
            let tex = self.value.replace(using: commandBuffer)
            return tex
        }
    }
}

@available(macOS 26.0, visionOS 26.0, *)
public struct LowLevelInstanceData: @unchecked Sendable {
    let value: RealityKit.LowLevelInstanceData?

    public init() {
        self.value = nil
    }

    public func isSome() -> Bool {
        return value != nil
    }

    public init(instanceCount: Int) {
        self.value = assumeMainActor{
            return try? RealityKit.LowLevelInstanceData(instanceCount: instanceCount)
        }
    }
    
    public func setTransform(at index: Int, to transform: Matrix44) {
        guard let value = self.value else {
            return
        }
        
        value.withMutableTransforms{ transforms in
            transforms[index] = transform.to_simd()
        }
    }
    
    public func setInstanceCount(instanceCount: Int) {
        guard let value = self.value else {
            return
        }
        
        value.instanceCount = instanceCount
    }
}

public struct HoverEffectGroupID: @unchecked Sendable {
    let value = HoverEffectComponent.GroupID()
    
    public init() {}
}

public struct VolumeCameraComponent: Component, Codable {
    public let size: SIMD3<Float>
}

public struct DebugComponent: Component, Codable {
	public var typeName: String
	public var path: String
}

public struct Entity: @unchecked Sendable {
    var value: RealityKit.Entity! = nil

    @MainActor static var didWarnClippingComponentUnavailable = false

    public func id() -> UInt64 {
        MainActor.assumeIsolated{
            self.value.id
        }
    }
    public init() {}
    
    public static func initAndMaterialize() -> Entity {
        MainActor.assumeIsolated {
            var e = Entity()
            e.materialize()
            return e
        }
    }
    
    init(coreValue: RealityKit.Entity) {
        self.value = coreValue
    }
    
    public mutating func materialize() {
        MainActor.assumeIsolated {
            value = RealityKit.Entity()
        }
    }
    
    public mutating func dematerialize() {
        MainActor.assumeIsolated {
            setParent(parent: nil)
            value = nil
        }
    }
    
    public func findEntity(id: UInt64) -> Entity? {
        MainActor.assumeIsolated{
            if let entityValue = self.value.scene?.findEntity(id: id) {
                return Entity(coreValue: entityValue)
            } else {
                return nil
            }
        }
    }

    public func setName(_ name: String) {
        MainActor.assumeIsolated { self.value.name = name }
    }

	public func setDebugInfo(debugTypename: String, path: String) {
        MainActor.assumeIsolated {
			self.value.components.set(DebugComponent(typeName: debugTypename, path: path))
        }
    }

    public func setEnabled(value: Bool) {
        MainActor.assumeIsolated{
            self.value.isEnabled = value
        }
    }
    
    public func setTransform(scale: Vector3, rotation: Vector4, translation: Vector3) {
        MainActor.assumeIsolated{
            self.value.components[Transform.self] =
                Transform(scale: scale.to_simd(),
                          rotation: rotation.to_simd_quat(),
                          translation: translation.to_simd())
        }
    }

    public func setRotation(_ rotation: Vector4) {
        MainActor.assumeIsolated {
            self.value.orientation = rotation.to_simd_quat()
        }
    }

	@MainActor
	static let invalidMaterial: SimpleMaterial = {
		var invalidMaterial = SimpleMaterial(color: .gray, roughness: 1.0, isMetallic: false)
		invalidMaterial.faceCulling = .back
		return invalidMaterial
	}()

    public func setModel(mesh: MeshResource, materials: [SGLMaterial]) {
        MainActor.assumeIsolated{
            let modelMaterials = materials.enumerated().map{ materialIndex, material in
                if material.isSome() {
                    let hasCompressedUVs = mesh.flags.contains(.hasCompressedUVs)

                    var modelMaterialParameters = [(name: String, value: MaterialParameters.Value)]()

                    if hasCompressedUVs {
                        modelMaterialParameters += [(name: "_has_compressed_uvs", value: .bool(hasCompressedUVs))]
                    }
                    
                    var isBrokenMaterial = false
                    if let materialProgram = material.program, materialProgram.isBrokenMaterial {
                        isBrokenMaterial = true
                    }
                    
                    if hasCompressedUVs {
                        modelMaterialParameters += [(name: "_uv_scale", value: .simd4Float(mesh.uvScale))]
                    }
                    
                    if case .bool(let vertexColorUseAsAlbedo) = material.value?.getParameter(name: "_vertex_color_use_as_albedo") {
                        if vertexColorUseAsAlbedo && !mesh.flags.contains(.hasColor) {
                            modelMaterialParameters += [(name: "_vertex_color_use_as_albedo", value: .bool(false))]
                        }
                    }
                    
                    if let materialProgram = material.program, let lowLevelMesh = mesh.value?.lowLevelMesh {
                        var boundsOverride: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil
                        if materialProgram.billboard {
                            let boundsMin = boundsOverride?.min ?? mesh.boundsMin
                            let boundsMax = boundsOverride?.max ?? mesh.boundsMax
                            let boundsExtent = SIMD3<Float>(repeating: 0.5 * distance(boundsMin, boundsMax))
                            let boundsCenter = 0.5 * (boundsMin + boundsMax)
                            boundsOverride = (boundsCenter - boundsExtent, boundsCenter + boundsExtent)
                        }
                        
                        if materialProgram.boundsMultiplier > 1.01 {
                            let boundsMin = boundsOverride?.min ?? mesh.boundsMin
                            let boundsMax = boundsOverride?.max ?? mesh.boundsMax
                            let boundsExtent = 0.5 * materialProgram.boundsMultiplier * (boundsMax - boundsMin)
                            let boundsCenter = 0.5 * (boundsMin + boundsMax)
                            boundsOverride = (boundsCenter - boundsExtent, boundsCenter + boundsExtent)
                        }
                        
                        if var (boundsOverrideMin, boundsOverrideMax) = boundsOverride {
                            boundsOverrideMin = min(boundsOverrideMin, lowLevelMesh.parts[materialIndex].bounds.min)
                            boundsOverrideMax = max(boundsOverrideMax, lowLevelMesh.parts[materialIndex].bounds.max)
                            lowLevelMesh.parts[materialIndex].bounds = BoundingBox(min: boundsOverrideMin, max: boundsOverrideMax)
                        }
                    }
                    
                    return (material, modelMaterialParameters)
                } else {
                    return (SGLMaterial(), [])
                }
            }
            
            let updateComponent = SGLMaterialUpdateComponent(modelMaterials: modelMaterials)
            self.value.components[SGLMaterialUpdateComponent.self] = updateComponent
            
            let materialValues = (0..<materials.count).map{ materialIndex -> any RealityKit.Material in
                return updateComponent.getMaterialForModel(index: materialIndex) ?? Self.invalidMaterial
            }
            
            if var meshValue = mesh.value {
                self.value.components[ModelComponent.self] = ModelComponent(mesh: meshValue, materials: materialValues)
            } else {
                self.value.components[ModelComponent.self] = nil
            }
            
            if let material = materials.first, let materialProgram = material.program, let sortGroup = materialProgram.sortGroup {
                self.value.components[ModelSortGroupComponent.self] =
                    ModelSortGroupComponent(group: sortGroup, order: materialProgram.sortOrder)
            }
        }
    }
    
    public func setPortalModel(mesh: MeshResource) {
        MainActor.assumeIsolated{
            if let meshValue = mesh.value {
                self.value.components[ModelComponent.self] = ModelComponent(mesh: meshValue, materials: [PortalMaterial()])
            } else {
                self.value.components[ModelComponent.self] = nil
            }
        }
    }
    
    @available(macOS 26.0, visionOS 26.0, *)
    public func setInstanceData(instanceData: LowLevelInstanceData) {
        MainActor.assumeIsolated{
            if let instanceDataValue = instanceData.value {
                var meshInstancesComponent = MeshInstancesComponent()
                meshInstancesComponent[partIndex: 0] = .init(data: instanceDataValue)
                self.value.components[MeshInstancesComponent.self] = meshInstancesComponent
            } else {
                self.value.components.remove(MeshInstancesComponent.self)
            }
        }
    }
    
    public func setCollision(shapes: [ShapeResource]) {
        MainActor.assumeIsolated{
            if !shapes.isEmpty {
                let shapeValues = shapes.compactMap{$0.value}
                let collision = CollisionComponent(shapes: shapeValues) // TODO: , isStatic: true?

                
                // collision.filter = CollisionFilter(group: [], mask: [])
                self.value.components.set(collision)
            } else {
                self.value.components.remove(CollisionComponent.self)
            }
        }
    }
    
    public func setIsInputTarget(value: Bool) {
        MainActor.assumeIsolated{
            if value {
                self.value.components.set(InputTargetComponent())
                #if !os(macOS)
                ImmersiveRealityViewState.shared.hasInputTargets = true
                #endif
            } else {
                self.value.components.remove(InputTargetComponent.self)
            }
        }
    }
    
    public mutating func setHoverEffect(groupID: HoverEffectGroupID?, color: GDRKColorRef?, strength: Float, spotlight: Bool) {
        MainActor.assumeIsolated{
            if let groupIDValue = groupID?.value {
                let hoverEffect: HoverEffectComponent.HoverEffect
                if spotlight {
                    // SpotlightHoverEffectStyle's nil-color default produces no
                    // visible spotlight on dark surfaces, so fall back to white
                    // when the user hasn't enabled an explicit color.
                    #if os(macOS)
                    let spotlightColor = color ?? NSColor.white
                    #else
                    let spotlightColor = color ?? UIColor.white
                    #endif
                    hoverEffect = HoverEffectComponent.HoverEffect.spotlight(
                        HoverEffectComponent.SpotlightHoverEffectStyle(color: spotlightColor, strength: strength),
                            groupID: groupIDValue)
                } else {
                    hoverEffect = HoverEffectComponent.HoverEffect.highlight(
                        HoverEffectComponent.HighlightHoverEffectStyle(color: color, strength: strength),
                            groupID: groupIDValue)
                }
                
                self.value.components.set(HoverEffectComponent(hoverEffect))
                for child in self.value.children {
                    child.components.set(HoverEffectComponent(hoverEffect))
                }
            } else {
                self.value.components.remove(HoverEffectComponent.self)
                for child in self.value.children {
                    child.components.remove(HoverEffectComponent.self)
                }
            }
        }
    }
    
    public func setupPerspectiveCamera(near: Float, far: Float, fieldOfViewInDegrees: Float) {
#if os(macOS)
        MainActor.assumeIsolated {
            self.value.components.set(PerspectiveCameraComponent(near: near, far: far, fieldOfViewInDegrees: fieldOfViewInDegrees))
        }
#endif
    }
    
    public func disablePerspectiveCamera() {
#if os(macOS)
        MainActor.assumeIsolated {
            self.value.components.remove(PerspectiveCameraComponent.self)
        }
#endif
    }
    
    public func setupOrthographicCamera(near: Float, far: Float, scale: Float) {
#if os(macOS)
        MainActor.assumeIsolated{
            var cameraComponent = OrthographicCameraComponent()
            cameraComponent.near = near
            cameraComponent.far = far
            cameraComponent.scale = scale
            self.value.components.set(cameraComponent)
        }
#endif
    }
    
    public func disableOrthographicCamera() {
#if os(macOS)
        MainActor.assumeIsolated {
            self.value.components.remove(OrthographicCameraComponent.self)
        }
#endif
    }
    
    public func setVolumeCameraSize(size: Vector3?) {
        MainActor.assumeIsolated{
            if let size = size {
                self.value.components.set(VolumeCameraComponent(size: size.to_simd()))
            } else {
                self.value.components.remove(VolumeCameraComponent.self)
            }
        }
    }
    
    public func addChild(child: Entity) {
        MainActor.assumeIsolated{
            if let hoverEffectComponent = self.value.components[HoverEffectComponent.self] {
                child.value.components.set(hoverEffectComponent)
            } else {
                child.value.components.remove(HoverEffectComponent.self)
            }

            if let portalComponent = self.value.components[PortalComponent.self] {
                child.value.components.set(portalComponent)
            } else {
                child.value.components.remove(PortalComponent.self)
            }
            
            self.value.addChild(child.value!)
        }
    }

    public func removeFromParent() {
        MainActor.assumeIsolated {
            self.value.removeFromParent()
        }
    }

    public func removeChild(child: Entity) {
        MainActor.assumeIsolated{
            self.value.removeChild(child.value!)
        }
    }
    
    public func clearChildren() {
        MainActor.assumeIsolated{ self.value.children.removeAll() }
    }
    
    public func setParent(parent: Entity?) {
        MainActor.assumeIsolated{ self.value.setParent(parent?.value) }
    }

    public func getRawPointer() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self.value!).toOpaque()
    }
    
    public func setDirectionalLight(lightColor: DirectionalLightComponent.Color,
                                    lightIntensity: Float) {
        MainActor.assumeIsolated {
            let lightComponent = DirectionalLightComponent(color: lightColor, intensity: lightIntensity)
            self.value.components.set(lightComponent);
        }
    }
    
    public func setDirectionalLightAutomaticShadow(depthBias: Float, maxDistance: Float) {
        MainActor.assumeIsolated {
            var shadow = DirectionalLightComponent.Shadow(
                shadowProjection: .automatic(maximumDistance: maxDistance),
                depthBias: depthBias,
            )
            self.value.components[DirectionalLightComponent.Shadow.self] = shadow
        }
    }

    public func setDirectionalLightFixedShadow(zNear: Float, zFar: Float,
                                                orthographicScale: Float, depthBias: Float) {
        MainActor.assumeIsolated {
            let shadow = DirectionalLightComponent.Shadow(
                shadowProjection: .fixed(zNear: zNear, zFar: zFar, orthographicScale: orthographicScale),
                depthBias: depthBias
            )
            self.value.components[DirectionalLightComponent.Shadow.self] = shadow
        }
    }
    
    public func disableDirectionalLightShadow() {
        MainActor.assumeIsolated {
            self.value.components.remove(DirectionalLightComponent.Shadow.self)
        }
    }

    public func setSkybox(_ skybox: Skybox) {
        MainActor.assumeIsolated {
            let hasSkybox: Bool = {
                switch skybox.value {
                case .none:
                    return false
                default:
                    return true
                }
            }()
            if !hasSkybox {
                for child in value.children {
                    child.removeFromParent()
                }
            } else {
                var material = UnlitMaterial()
                material.faceCulling = .front
                // Rotating a bit, to match the convention used by IBLs and Godot's convention
                material.textureCoordinateTransform = .init(offset: SIMD2<Float>(x: -0.25, y: 0.0))
                switch skybox.value {
                case .color(let cGColor):
                    #if canImport(AppKit)
                    material.color = .init(tint: .init(cgColor: cGColor)!)
                    #else
                    material.color = .init(tint: .init(cgColor: cGColor))
                    #endif
                case .texture(let textureResource):
                    material.color = .init(texture: .init(textureResource))
                default:
                    break
                }
                
                for child in value.children {
                    child.removeFromParent()
                }
                let child = RealityKit.Entity()
                child.components.set(ModelComponent(
                    mesh: .generateSphere(radius: 1E3),
                    materials: [material]
                ))
                self.value.addChild(child)
            }
        }
    }

    public func setImageBasedLight(_ env: EnvironmentResource, intensityExponent: Float) {
        MainActor.assumeIsolated {
            guard let env = env.value else {
                self.value.components.remove(VirtualEnvironmentProbeComponent.self)
                return
            }

            var iblComp = ImageBasedLightComponent(source: .single(env))
            iblComp.intensityExponent = intensityExponent
            iblComp.inheritsRotation = true
            self.value.components.set(iblComp)
        }
    }

    public func setImageBasedLightReceiver(_ light: Entity?) {
        MainActor.assumeIsolated {
            if let light {
                self.value.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light.value!))
            } else {
                self.value.components.remove(ImageBasedLightReceiverComponent.self)
            }
        }
    }

    public func setEnvironmentLightingWeight(_ weight: Float) {
        MainActor.assumeIsolated {
            self.value.components.set(EnvironmentLightingConfigurationComponent(environmentLightingWeight: weight))
        }
    }

    public func unsetEnvironmentLightingWeight() {
        MainActor.assumeIsolated {
            self.value.components.remove(EnvironmentLightingConfigurationComponent.self)
        }
    }

    public func setPointLight(lightColor: PointLightComponent.Color,
                              lightIntensity: Float,
                              attenuationRadius: Float,
                              attenuationFalloffExponent: Float) {
        MainActor.assumeIsolated {
            var lightComponent = PointLightComponent(color: lightColor, intensity: lightIntensity, attenuationRadius: attenuationRadius, attenuationFalloffExponent: attenuationFalloffExponent)
            self.value.components.set(lightComponent)
        }
    }
    
    public func setSpotLight(lightColor: SpotLightComponent.Color,
                             lightIntensity: Float,
                             innerAngle: Float,
                             outerAngle: Float,
                             attenuationRadius: Float,
                             attenuationFalloffExponent: Float) {
        MainActor.assumeIsolated {
            let lightComponent = SpotLightComponent(color: lightColor,
                                                    intensity: lightIntensity,
                                                    innerAngleInDegrees: innerAngle,
                                                    outerAngleInDegrees: outerAngle,
                                                    attenuationRadius: attenuationRadius,
                                                    attenuationFalloffExponent: attenuationFalloffExponent)
            self.value.components.set(lightComponent)
        }
    }
    
    public func setSpotLightShadow(shadowEnabled: Bool) {
        MainActor.assumeIsolated {
            if (shadowEnabled) {
                self.value.components[SpotLightComponent.Shadow.self] = .init();
            } else {
                self.value.components.remove(SpotLightComponent.Shadow.self)
            }
        }
    }
    
    public func setIsWorld(value: Bool) {
        MainActor.assumeIsolated{
            if value {
                self.value.components.set(WorldComponent())
            } else {
                self.value.components.remove(WorldComponent.self)
            }
        }
    }
    
    public func setPortal(target: Entity?, clippingPlane: Vector4? = nil, crossingPlane: Vector4? = nil) {
        MainActor.assumeIsolated{
            if let targetValue = target?.value {
                let clippingMode: PortalComponent.ClippingMode
                if let clippingPlane = clippingPlane {
                    let clippingPlaneXYZ = SIMD3<Float>(clippingPlane.x, clippingPlane.y, clippingPlane.z)
                    let clippingPlaneNormal = normalize(clippingPlaneXYZ)
                    let clippingPlanePosition = clippingPlaneXYZ * clippingPlane.w
                    clippingMode = .plane(.init(position: clippingPlanePosition, normal: clippingPlaneNormal))
                } else {
                    clippingMode = .disabled
                }
                
                let crossingMode: PortalComponent.CrossingMode
                if let crossingPlane = crossingPlane {
                    let crossingPlaneXYZ = SIMD3<Float>(crossingPlane.x, crossingPlane.y, crossingPlane.z)
                    let crossingPlaneNormal = normalize(crossingPlaneXYZ)
                    let crossingPlanePosition = crossingPlaneXYZ * crossingPlane.w
                    crossingMode = .plane(.init(position: crossingPlanePosition, normal: crossingPlaneNormal))
                } else {
                    crossingMode = .disabled
                }
                
                let portalComponent = PortalComponent(target: targetValue, clippingMode: clippingMode, crossingMode: crossingMode)
                self.value.components.set(portalComponent)
                for child in self.value.children {
                    child.components.set(portalComponent)
                }
            } else {
                self.value.components.remove(PortalComponent.self)
                for child in self.value.children {
                    child.components.remove(PortalComponent.self)
                }
            }
        }
    }
    
    public func setHasPortalCrossing(value: Bool) {
        MainActor.assumeIsolated{
            if value {
                self.value.components.set(PortalCrossingComponent())
                for child in self.value.children {
                    child.components.set(PortalCrossingComponent())
                }
            } else {
                self.value.components.remove(PortalCrossingComponent.self)
                for child in self.value.children {
                    child.components.remove(PortalCrossingComponent.self)
                }
            }
        }
    }

    // ClippingComponent/BoundingBox require macOS/visionOS 27.0, above this plugin's 26.0
    // deployment target, and this is called unconditionally from C++ with no availability
    // checking. Guard at runtime so pre-27.0 devices no-op (unclipped) instead of trapping.
    public func setClippingComponent(boundsMin: Vector3, boundsMax: Vector3, featherEnabled: Bool, featherInset: Vector3, falloff: UInt32) {
        guard #available(macOS 27.0, visionOS 27.0, *) else {
            MainActor.assumeIsolated {
                if !Entity.didWarnClippingComponentUnavailable {
                    Entity.didWarnClippingComponentUnavailable = true
                    warnPrint(msg: "RealityClipping3D requires macOS/visionOS 27.0+; ClippingComponent is unavailable on this OS version, so this node will have no effect.")
                }
            }
            return
        }
        MainActor.assumeIsolated{
            var component = ClippingComponent(bounds: BoundingBox(min: boundsMin.to_simd(), max: boundsMax.to_simd()))
            if featherEnabled {
                let componentFalloff: ClippingComponent.FeatheredEdge.Falloff = falloff == 1 ? .cubic : .linear
                component.featheredEdge = ClippingComponent.FeatheredEdge(symmetricEdgeInset: featherInset.to_simd(), falloff: componentFalloff)
            } else {
                component.featheredEdge = .none
            }
            component.shouldClipChildren = true
            component.shouldClipSelf = false
            self.value.components.set(component)
        }
    }
    
	
	public func writeAsync(urlString: String, delegate: GDRKEntityWriteDelegate) {
		assumeMainActor(delegate) { delegate in
			withBlockingAsyncTaskScope{
				do {
					try await self.value.write(to: URL(fileURLWithPath: urlString))
					print("Dumped reality file to \(urlString)");
				} catch {
					print("Failed to write reality file: \(error)")
				}
				
				delegate.onCompleted();
			}
		}
	}
}

