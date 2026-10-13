import AppKit
import Arils
import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import simd

/// Transparent, mouse-pass-through mesh surface used above or below the
/// independently animated Arils body view.
final class ArticulationMetalView: MTKView {
    private var articulationRenderer: ArticulationMetalRenderer?
    private var parameters = ArticulationPoseParameters()
    private var partOpacities: [ArticulationPartID: Float] = [:]

    var rendererIsAvailable: Bool { articulationRenderer != nil }
    private(set) var rendererErrorDescription: String?

    init(rig: ArticulationRigArchive) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        wantsLayer = true
        layer?.isOpaque = false
        if let device {
            do {
                articulationRenderer = try ArticulationMetalRenderer(
                    device: device,
                    rig: rig,
                    colorPixelFormat: colorPixelFormat
                )
            } catch {
                rendererErrorDescription = String(describing: error)
            }
        } else {
            rendererErrorDescription = "Metal device unavailable"
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ArticulationMetalView does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(
        parameters: ArticulationPoseParameters,
        opacities: [ArticulationPartID: Float]
    ) {
        self.parameters = parameters
        self.partOpacities = opacities.mapValues {
            $0.isFinite ? min(max($0, 0), 1) : 0
        }
        isHidden = !self.partOpacities.values.contains { $0 > 0.001 }
        if !isHidden {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let articulationRenderer,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable else { return }
        articulationRenderer.draw(
            parameters: parameters,
            opacities: partOpacities,
            renderPassDescriptor: descriptor,
            drawable: drawable,
            drawableSize: drawableSize
        )
    }
}

/// The compiler already stores the repaired full-resolution image and a mask
/// of the pixels removed into articulated parts. This view draws only that
/// repaired patch over the normal Arils view, hiding the original static arm
/// before the mesh copies are composited around the body.
final class ArticulationUnderpaintPatchView: NSImageView {
    init?(rig: ArticulationRigArchive) {
        guard let patch = Self.makePatch(rig: rig) else { return nil }
        super.init(frame: .zero)
        image = NSImage(
            cgImage: patch,
            size: NSSize(width: rig.imageWidth, height: rig.imageHeight)
        )
        imageScaling = .scaleAxesIndependently
        imageAlignment = .alignCenter
        wantsLayer = true
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func makePatch(rig: ArticulationRigArchive) -> CGImage? {
        guard let baseImage = image(from: rig.baseTexturePNG),
              let maskImage = image(from: rig.unknownUnderpaintMaskPNG),
              let base = Bitmap(image: baseImage),
              let mask = Bitmap(image: maskImage),
              base.width == mask.width,
              base.height == mask.height else { return nil }
        var patch = Bitmap(width: base.width, height: base.height)
        for y in 0..<base.height {
            for x in 0..<base.width {
                let weight = min(max(mask.rgba(x: x, y: y).x, 0), 1)
                patch.setRGBA(x: x, y: y, base.rgba(x: x, y: y) * weight)
            }
        }
        return patch.cgImage()
    }

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

@MainActor
private final class ArticulationMetalRenderer {
    private enum RendererError: Error {
        case commandQueueUnavailable
        case shaderUnavailable(String)
    }

    private struct GPUVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    private struct Uniforms {
        var scale: SIMD2<Float>
        var offset: SIMD2<Float>
        var opacity: SIMD4<Float>
    }

    private struct PartResources {
        var id: ArticulationPartID
        var vertexBuffer: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
        var vertexCount: Int
        var uvs: [SIMD2<Float>]
        var texture: MTLTexture
    }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let evaluator: ArticulationEvaluator
    private let imageSize: SIMD2<Float>
    private var parts: [PartResources] = []

    init(
        device: MTLDevice,
        rig: ArticulationRigArchive,
        colorPixelFormat: MTLPixelFormat
    ) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue
        self.evaluator = ArticulationEvaluator(rig: rig)
        self.imageSize = SIMD2(Float(rig.imageWidth), Float(rig.imageHeight))

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shader, options: nil)
        } catch {
            throw RendererError.shaderUnavailable(error.localizedDescription)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "arils_ex_articulation_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "arils_ex_articulation_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        for part in rig.parts.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            guard let image = Self.image(from: part.texturePNG),
                  let texture = Self.texture(device: device, image: image),
                  let vertexBuffer = device.makeBuffer(
                    length: part.mesh.vertexCount * MemoryLayout<GPUVertex>.stride,
                    options: .storageModeShared
                  ),
                  let indexBuffer = device.makeBuffer(
                    bytes: part.mesh.indices,
                    length: part.mesh.indices.count * MemoryLayout<UInt32>.stride,
                    options: .storageModeShared
                  ) else { continue }
            parts.append(PartResources(
                id: part.id,
                vertexBuffer: vertexBuffer,
                indexBuffer: indexBuffer,
                indexCount: part.mesh.indices.count,
                vertexCount: part.mesh.vertexCount,
                uvs: part.mesh.uvs,
                texture: texture
            ))
        }
    }

    func draw(
        parameters: ArticulationPoseParameters,
        opacities: [ArticulationPartID: Float],
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawable: CAMetalDrawable,
        drawableSize: CGSize
    ) {
        guard drawableSize.width > 1,
              drawableSize.height > 1,
              imageSize.x > 0,
              imageSize.y > 0 else { return }
        let evaluated = evaluator.evaluate(parameters: parameters)
        for part in parts {
            guard let positions = evaluated[part.id],
                  positions.count == part.vertexCount,
                  part.uvs.count == part.vertexCount else { continue }
            let destination = part.vertexBuffer.contents().assumingMemoryBound(to: GPUVertex.self)
            for index in 0..<part.vertexCount {
                destination[index] = GPUVertex(
                    position: positions[index],
                    uv: part.uvs[index]
                )
            }
        }

        let drawableWidth = Float(drawableSize.width)
        let drawableHeight = Float(drawableSize.height)
        let fit = min(drawableWidth / imageSize.x, drawableHeight / imageSize.y)
        let scale = SIMD2(2 * fit / drawableWidth, -2 * fit / drawableHeight)
        let offset = SIMD2(
            -imageSize.x * 0.5 * scale.x,
            -imageSize.y * 0.5 * scale.y
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
              ) else { return }
        encoder.setRenderPipelineState(pipeline)
        for part in parts {
            let opacity = opacities[part.id] ?? 0
            guard opacity > 0.001 else { continue }
            var uniforms = Uniforms(
                scale: scale,
                offset: offset,
                opacity: SIMD4(opacity, 0, 0, 0)
            )
            encoder.setVertexBuffer(part.vertexBuffer, offset: 0, index: 0)
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
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func texture(device: MTLDevice, image: CGImage) -> MTLTexture? {
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
        bitmap.pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bitmap.width * 4
            )
        }
        return texture
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex {
        float2 position;
        float2 uv;
    };

    struct Uniforms {
        float2 scale;
        float2 offset;
        float4 opacity;
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    vertex Varyings arils_ex_articulation_vertex(
        uint vertexID [[vertex_id]],
        const device Vertex *vertices [[buffer(0)]],
        constant Uniforms &uniforms [[buffer(1)]]) {
        Varyings out;
        Vertex packed = vertices[vertexID];
        out.position = float4(packed.position * uniforms.scale + uniforms.offset, 0, 1);
        out.uv = packed.uv;
        return out;
    }

    fragment float4 arils_ex_articulation_fragment(
        Varyings in [[stage_in]],
        texture2d<float> texture [[texture(0)]],
        constant Uniforms &uniforms [[buffer(1)]]) {
        constexpr sampler linearSampler(
            mag_filter::linear,
            min_filter::linear,
            s_address::clamp_to_zero,
            t_address::clamp_to_zero
        );
        return texture.sample(linearSampler, in.uv) * uniforms.opacity.x;
    }
    """
}
