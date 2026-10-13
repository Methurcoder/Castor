import CoreGraphics
import Foundation
import Metal
import MetalKit
import simd

import ArilsCore
import ArilsRig

/// Abstraction over the drawing backend so the Metal implementation can be
/// replaced (SpriteKit, a software rasterizer for tests, ...) without touching
/// the engine. Implementations receive resolved parameters, not motion state.
@MainActor
public protocol AvatarRendering: AnyObject {
    func draw(
        parameters: [ParameterID: Float],
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawable: CAMetalDrawable,
        drawableSize: CGSize
    )
}

/// Metal mesh renderer: a ring of dynamic vertex buffers per part, deformed on
/// the CPU each frame (a few hundred vertices — microseconds), drawn
/// back-to-front with premultiplied alpha.
///
/// The GPU never sees motion state; it just draws whatever geometry the
/// `DeformationEvaluator` produced, which keeps the whole visual result
/// testable CPU-side.
@MainActor
public final class MetalAvatarRenderer: AvatarRendering {
    public enum RendererError: Error {
        case deviceUnavailable
        case libraryUnavailable
        case textureCreationFailed(partID: String)
        case imageExportFailed
    }

    private struct PartResources {
        let partID: String
        let vertexBuffers: [MTLBuffer]
        let indexBuffer: MTLBuffer
        let indexCount: Int
        let vertexCount: Int
        let uvs: [SIMD2<Float>]
        let texture: MTLTexture
        let opacity: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let colorPixelFormat: MTLPixelFormat
    private var exportColor: MTLTexture?
    private var exportDepth: MTLTexture?
    private let legacyPipelineState: MTLRenderPipelineState
    private let opaquePipelineState: MTLRenderPipelineState
    private let featherPipelineState: MTLRenderPipelineState
    private let opaqueDepthState: MTLDepthStencilState
    private let featherDepthState: MTLDepthStencilState
    private let evaluator: DeformationEvaluator3D
    private var parts: [PartResources] = []
    private let imageSize: SIMD2<Float>
    private let projection: RenderProjectionContract
    private let usesDepth: Bool
    private static let maximumFramesInFlight = 3
    private let inFlightSemaphore = DispatchSemaphore(value: maximumFramesInFlight)
    private var frameIndex = 0

    public init(device: MTLDevice, avatar: RiggedAvatar, colorPixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.colorPixelFormat = colorPixelFormat
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.deviceUnavailable
        }
        self.commandQueue = queue
        self.evaluator = DeformationEvaluator3D(rig: avatar.rig)
        self.imageSize = SIMD2(Float(avatar.rig.imageWidth), Float(avatar.rig.imageHeight))
        self.projection = RenderProjectionContract(
            imageWidth: avatar.rig.imageWidth,
            imageHeight: avatar.rig.imageHeight
        )
        self.usesDepth = avatar.rig.parts.contains { $0.mesh.depths.contains { abs($0) > 0.0001 } }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        } catch {
            throw RendererError.libraryUnavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "arils_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "arils_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        // Premultiplied-alpha over.
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = .depth32Float
        self.legacyPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "arils_fragment_opaque")
        self.opaquePipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "arils_fragment_feather")
        self.featherPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        let opaqueDepth = MTLDepthStencilDescriptor()
        opaqueDepth.depthCompareFunction = .lessEqual
        opaqueDepth.isDepthWriteEnabled = true
        guard let opaqueState = device.makeDepthStencilState(descriptor: opaqueDepth) else {
            throw RendererError.deviceUnavailable
        }
        self.opaqueDepthState = opaqueState
        let featherDepth = MTLDepthStencilDescriptor()
        featherDepth.depthCompareFunction = .lessEqual
        featherDepth.isDepthWriteEnabled = false
        guard let featherState = device.makeDepthStencilState(descriptor: featherDepth) else {
            throw RendererError.deviceUnavailable
        }
        self.featherDepthState = featherState

        for part in avatar.rig.partsInDrawOrder {
            guard let cgImage = avatar.textures[part.id] else { continue }
            // Normalize through Bitmap (premultiplied RGBA8) instead of
            // MTKTextureLoader: archived textures come back from PNG with
            // *straight* alpha, and feeding that into the premultiplied blend
            // makes every feathered edge glow white. Drawing through a
            // premultiplied CGContext converts any input correctly.
            guard let texture = Self.makeTexture(device: device, image: cgImage) else {
                throw RendererError.textureCreationFailed(partID: part.id)
            }

            let vertexCount = part.mesh.vertexCount
            var vertexBuffers: [MTLBuffer] = []
            if vertexCount > 0 {
                vertexBuffers.reserveCapacity(Self.maximumFramesInFlight)
                for _ in 0..<Self.maximumFramesInFlight {
                    guard let buffer = device.makeBuffer(
                        length: vertexCount * MemoryLayout<GPUVertex>.stride,
                        options: .storageModeShared
                    ) else {
                        vertexBuffers.removeAll()
                        break
                    }
                    vertexBuffers.append(buffer)
                }
            }
            guard vertexBuffers.count == Self.maximumFramesInFlight,
                  let indexBuffer = device.makeBuffer(
                      bytes: part.mesh.indices,
                      length: part.mesh.indices.count * MemoryLayout<UInt32>.stride,
                      options: .storageModeShared
                  ) else {
                continue
            }
            parts.append(PartResources(
                partID: part.id,
                vertexBuffers: vertexBuffers,
                indexBuffer: indexBuffer,
                indexCount: part.mesh.indices.count,
                vertexCount: vertexCount,
                uvs: part.mesh.uvs,
                texture: texture,
                opacity: part.opacity
            ))
        }
    }

    /// CGImage → premultiplied RGBA8 texture (gamma-encoded values as-is; we
    /// blend in gamma space like every conventional 2D compositor).
    private static func makeTexture(device: MTLDevice, image: CGImage) -> MTLTexture? {
        guard let bitmap = Bitmap(image: image), bitmap.width > 0, bitmap.height > 0 else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: bitmap.width,
            height: bitmap.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bitmap.pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bitmap.width * 4
            )
        }
        return texture
    }

    private struct GPUVertex {
        var position: SIMD4<Float>
        var uv: SIMD2<Float>
        var padding: SIMD2<Float> = .zero
    }

    private struct Uniforms {
        var scale: SIMD2<Float>
        var offset: SIMD2<Float>
        var opacity: Float
        var cameraDistance: Float
        var depthRange: Float
        var zBias: Float
        var minimumCameraDenominator: Float
        var opaqueAlphaThreshold: Float
        var minimumVisibleAlpha: Float
    }

    public func draw(
        parameters: [ParameterID: Float],
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawable: CAMetalDrawable,
        drawableSize: CGSize
    ) {
        _ = submit(parameters: parameters, renderPassDescriptor: renderPassDescriptor,
                   drawable: drawable, drawableSize: drawableSize)
    }

    /// Renders just the avatar into a readable texture using the same deformation,
    /// projection and depth/alpha passes as the live view. Never captures the screen.
    public func renderImage(parameters: [ParameterID: Float], size: CGSize) throws -> CGImage {
        guard colorPixelFormat == .bgra8Unorm,
              size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1, size.width <= 4096, size.height <= 4096 else {
            throw RendererError.imageExportFailed
        }
        let width = Int(size.width.rounded(.up)), height = Int(size.height.rounded(.up))
        if exportColor?.width != width || exportColor?.height != height {
            let color = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorPixelFormat, width: width, height: height, mipmapped: false)
            color.storageMode = device.hasUnifiedMemory ? .shared : .managed
            color.usage = .renderTarget
            let depth = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            depth.storageMode = .private
            depth.usage = .renderTarget
            exportColor = device.makeTexture(descriptor: color)
            exportDepth = device.makeTexture(descriptor: depth)
        }
        guard let color = exportColor, let depth = exportDepth else { throw RendererError.imageExportFailed }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let command = submit(parameters: parameters, renderPassDescriptor: pass,
                                   drawable: nil, drawableSize: CGSize(width: width, height: height)) else {
            throw RendererError.imageExportFailed
        }
        command.waitUntilCompleted()
        guard command.status == .completed else { throw RendererError.imageExportFailed }
        if color.storageMode == .managed {
            // Dedicated-memory GPUs keep separate GPU/CPU copies. Synchronize the
            // rendered slice before getBytes reads the CPU copy.
            guard let synchronization = commandQueue.makeCommandBuffer(),
                  let blit = synchronization.makeBlitCommandEncoder() else {
                throw RendererError.imageExportFailed
            }
            blit.synchronize(texture: color, slice: 0, level: 0)
            blit.endEncoding()
            synchronization.commit()
            synchronization.waitUntilCompleted()
            guard synchronization.status == .completed else { throw RendererError.imageExportFailed }
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            color.getBytes(buffer.baseAddress!, bytesPerRow: width * 4,
                           from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                      .union(.byteOrder32Little), provider: provider, decode: nil,
                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw RendererError.imageExportFailed
        }
        return image
    }

    private func submit(
        parameters: [ParameterID: Float],
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawable: CAMetalDrawable?,
        drawableSize: CGSize
    ) -> MTLCommandBuffer? {
        guard drawableSize.width > 1, drawableSize.height > 1,
              imageSize.x > 0, imageSize.y > 0 else { return nil }

        let deformed = evaluator.evaluate(parameters: parameters)
        inFlightSemaphore.wait()
        let bufferIndex = frameIndex
        frameIndex = (frameIndex + 1) % Self.maximumFramesInFlight
        var submitted = false
        defer {
            if !submitted {
                inFlightSemaphore.signal()
            }
        }

        // Upload deformed geometry.
        for part in parts {
            guard let vertices = deformed[part.partID], vertices.count == part.vertexCount else {
                continue
            }
            let destination = part.vertexBuffers[bufferIndex].contents()
                .assumingMemoryBound(to: GPUVertex.self)
            for index in 0..<part.vertexCount {
                destination[index] = GPUVertex(
                    position: SIMD4(vertices[index].x, vertices[index].y, vertices[index].z, 1),
                    uv: part.uvs[index]
                )
            }
        }

        // Aspect-fit the image into the drawable using the same projection
        // contract as the CPU build-time validator.
        let aspectFit = projection.aspectFit(
            drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }
        // Draw-order bias in depth units. Its job is to let the intended
        // layer order (body < head < mouth < eyes) win wherever two parts
        // sample nearly the same surface. The body's coarse grid and the
        // head's finer grid interpolate the shared depth map differently by
        // up to a few dozen pixels near the neck, so a per-step bias worth
        // ~3% of the image (0.008 * depthRange) absorbs that mismatch —
        // without it the head's feathered chin edge loses the depth test
        // against the body's collar fill and vanishes into a dark seam line.
        // Occlusion *within* a part (nose vs cheek during a turn) uses one
        // shared bias and is unaffected.
        func draw(
            _ part: PartResources,
            drawOrderIndex: Int,
            pipeline: MTLRenderPipelineState,
            depth: MTLDepthStencilState
        ) {
            var uniforms = Uniforms(
                scale: aspectFit.scale,
                offset: aspectFit.offset,
                opacity: part.opacity,
                cameraDistance: projection.cameraDistance,
                depthRange: projection.depthRange,
                zBias: projection.zBias(forDrawOrderIndex: drawOrderIndex),
                minimumCameraDenominator: RenderProjectionContract.minimumCameraDenominator,
                opaqueAlphaThreshold: RenderProjectionContract.opaqueAlphaThreshold,
                minimumVisibleAlpha: RenderProjectionContract.minimumVisibleAlpha
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depth)
            encoder.setVertexBuffer(part.vertexBuffers[bufferIndex], offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(part.texture, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: part.indexCount,
                indexType: .uint32,
                indexBuffer: part.indexBuffer,
                indexBufferOffset: 0
            )
        }
        // Legacy flat rigs retain their exact painter-order blend. Depth rigs
        // use cutout+feather so transparent texels never occlude lower layers.
        if usesDepth {
            for (index, part) in parts.enumerated() {
                draw(
                    part,
                    drawOrderIndex: index,
                    pipeline: opaquePipelineState,
                    depth: opaqueDepthState
                )
            }
            for (index, part) in parts.enumerated() {
                draw(
                    part,
                    drawOrderIndex: index,
                    pipeline: featherPipelineState,
                    depth: featherDepthState
                )
            }
        } else {
            for (index, part) in parts.enumerated() {
                draw(
                    part,
                    drawOrderIndex: index,
                    pipeline: legacyPipelineState,
                    depth: featherDepthState
                )
            }
        }
        encoder.endEncoding()
        if let drawable { commandBuffer.present(drawable) }
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
        submitted = true
        commandBuffer.commit()
        return commandBuffer
    }
}
