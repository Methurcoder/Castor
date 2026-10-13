import Arils
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

public enum ArticulationCompilerError: Error, LocalizedError {
    case imageUnreadable
    case subjectNotFound
    case requiredJointMissing(JointKind)
    case emptyPart(ArticulationPartID)
    case textureEncodingFailed
    case integrityRejected(RigIntegrityMetrics)

    public var errorDescription: String? {
        switch self {
        case .imageUnreadable:
            "画像を読み込めません。"
        case .subjectNotFound:
            "関節パーツ用の被写体マスクを作れません。"
        case let .requiredJointMissing(joint):
            "\(joint.displayName)がないため関節パーツを作れません。"
        case let .emptyPart(part):
            "\(part.rawValue)の所有画素がありません。"
        case .textureEncodingFailed:
            "関節テクスチャをPNGへ変換できません。"
        case let .integrityRejected(metrics):
            "仮想曲げ検査に失敗しました（反転 \(metrics.meshInversionCount)、穴 \(metrics.holeArea)、ゴースト \(metrics.ghostArea)、未知面 \(metrics.unknownExposure)）。"
        }
    }
}

public struct ArticulationOwnershipProposal: Sendable {
    public var subjectMask: FloatPlane
    public var masks: [ArticulationPartID: FloatPlane]
    public var ambiguity: FloatPlane
    public var activeParts: Set<ArticulationPartID>

    public init(
        subjectMask: FloatPlane,
        masks: [ArticulationPartID: FloatPlane],
        ambiguity: FloatPlane,
        activeParts: Set<ArticulationPartID>? = nil
    ) {
        self.subjectMask = subjectMask
        self.masks = masks
        self.ambiguity = ambiguity
        self.activeParts = activeParts ?? Set(masks.keys)
    }
}

/// Build-time arm-part compiler. Runtime consumes only the archived meshes,
/// PNGs and two-bone weights; segmentation and inpainting are never repeated.
public struct ArticulationCompiler: Sendable {
    public var maskProviders: [any SubjectMaskProviding]
    public var occlusionInpainter: (any OcclusionInpaintingProviding)?
    public var integrityThresholds: RigIntegrityThresholds

    public init(
        maskProviders: [any SubjectMaskProviding] = [
            AlphaSubjectMaskProvider(),
            VisionSubjectMaskProvider(),
            BorderBackgroundSubjectMaskProvider(),
        ],
        occlusionInpainter: (any OcclusionInpaintingProviding)? = nil,
        integrityThresholds: RigIntegrityThresholds = RigIntegrityThresholds(
            maximumMeshInversionCount: 0,
            maximumHoleArea: 0.03,
            maximumGhostArea: 0.10,
            maximumUnknownExposure: 0.08
        )
    ) {
        self.maskProviders = maskProviders
        self.occlusionInpainter = occlusionInpainter
        self.integrityThresholds = integrityThresholds
    }

    public func proposeOwnership(
        image: CGImage,
        pose: ReferencePose,
        subjectMask suppliedSubjectMask: FloatPlane? = nil,
        corrections: [ArticulationPartID: [OwnershipBrushStroke]] = [:]
    ) async throws -> ArticulationOwnershipProposal {
        guard let source = Bitmap(image: image) else {
            throw ArticulationCompilerError.imageUnreadable
        }
        let subjectMask: FloatPlane
        if let suppliedSubjectMask {
            subjectMask = suppliedSubjectMask.resized(
                width: source.width,
                height: source.height
            )
        } else {
            subjectMask = try await extractionMask(image: image, source: source)
        }
        let activeParts = Set(ArticulationPartID.allCases.filter {
            $0.hasVisibleTexture(in: pose)
        })
        return try ownershipProposal(
            pose: pose,
            subjectMask: subjectMask,
            imageWidth: source.width,
            imageHeight: source.height,
            activeParts: activeParts,
            corrections: corrections
        )
    }

    /// Resolves the same full-resolution foreground evidence used by the
    /// compiler. Pose admission calls this once and passes the plane back into
    /// `compile`, avoiding the old fully-opaque-alpha visibility shortcut.
    public func subjectMask(for image: CGImage) async throws -> FloatPlane {
        guard let source = Bitmap(image: image) else {
            throw ArticulationCompilerError.imageUnreadable
        }
        return try await extractionMask(image: image, source: source)
    }

    public func compile(
        image: CGImage,
        pose: ReferencePose,
        subjectMask suppliedSubjectMask: FloatPlane? = nil,
        corrections: [ArticulationPartID: [OwnershipBrushStroke]] = [:],
        layerOrders: [ArticulationPartID: ArticulationLayerOrder] = [:]
    ) async throws -> ArticulationRigArchive {
        guard let source = Bitmap(image: image) else {
            throw ArticulationCompilerError.imageUnreadable
        }
        let proposal = try await proposeOwnership(
            image: image,
            pose: pose,
            subjectMask: suppliedSubjectMask,
            corrections: corrections
        )
        let underpaint = await makeUnderpaint(
            source: source,
            subjectMask: proposal.subjectMask,
            partMasks: proposal.masks
        )
        let unknownMask = unionMask(
            proposal.masks.values,
            width: source.width,
            height: source.height
        )

        var parts: [ArticulatedPartArchive] = []
        var partAlpha: [String: FloatPlane] = [:]
        for partID in ArticulationPartID.allCases where proposal.activeParts.contains(partID) {
            guard let mask = proposal.masks[partID],
                  let rect = bounds(of: mask, threshold: 0.03) else {
                throw ArticulationCompilerError.emptyPart(partID)
            }
            let texture = extractedTexture(source: source, mask: mask, rect: rect)
            let mesh = DeformableMesh.grid(rect: rect, columns: 6, rows: 10)
            let weights = try vertexWeights(
                partID: partID,
                mesh: mesh,
                pose: pose,
                imageWidth: source.width,
                imageHeight: source.height
            )
            guard let texturePNG = pngData(texture.cgImage()) else {
                throw ArticulationCompilerError.textureEncodingFailed
            }
            parts.append(ArticulatedPartArchive(
                id: partID,
                rect: rect,
                mesh: mesh,
                weights: weights,
                texturePNG: texturePNG,
                layerOrder: layerOrders[partID] ?? .inFrontOfBody
            ))
            partAlpha[partID.rawValue] = texture.alphaPlane()
        }

        guard let basePNG = pngData(underpaint.cgImage()),
              let unknownPNG = pngData(maskBitmap(unknownMask).cgImage()) else {
            throw ArticulationCompilerError.textureEncodingFailed
        }
        var archive = ArticulationRigArchive(
            imageWidth: source.width,
            imageHeight: source.height,
            restPose: pose,
            baseTexturePNG: basePNG,
            unknownUnderpaintMaskPNG: unknownPNG,
            parts: parts,
            omittedParts: Dictionary(uniqueKeysWithValues: ArticulationPartID.allCases.compactMap {
                guard !proposal.activeParts.contains($0) else { return nil }
                return ($0, omissionReason(for: $0, pose: pose))
            }),
            corrections: corrections,
            integrityMetrics: RigIntegrityMetrics(),
            integrityAccepted: false
        )
        let metrics = integrityMetrics(
            archive: archive,
            baseAlpha: underpaint.alphaPlane(),
            partAlpha: partAlpha,
            unknownMask: unknownMask
        )
        archive.integrityMetrics = metrics
        let disposition = integrityThresholds.validationPolicy.disposition(for: metrics)
        archive.integrityDisposition = disposition
        archive.integrityAccepted = disposition == .accepted
        guard disposition != .rejected else {
            throw ArticulationCompilerError.integrityRejected(metrics)
        }
        return archive
    }

    private func ownershipProposal(
        pose: ReferencePose,
        subjectMask: FloatPlane,
        imageWidth: Int,
        imageHeight: Int,
        activeParts: Set<ArticulationPartID>,
        corrections: [ArticulationPartID: [OwnershipBrushStroke]]
    ) throws -> ArticulationOwnershipProposal {
        let shoulderSpan = try jointDistance(
            .leftShoulder,
            .rightShoulder,
            pose: pose,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let baseRadius = max(3, shoulderSpan * 0.18)
        var raw: [ArticulationPartID: FloatPlane] = [:]
        var ambiguity = FloatPlane(width: subjectMask.width, height: subjectMask.height)

        for partID in ArticulationPartID.allCases where activeParts.contains(partID) {
            let bone = boneID(for: partID)
            let joints = bone.joints
            let start = try imagePoint(
                joints.start,
                pose: pose,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
            let end = try imagePoint(
                joints.end,
                pose: pose,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
            let radiusScale: Float = partID == .leftForearm || partID == .rightForearm
                ? 0.82
                : 1
            let field = PartOwnershipField(
                start: start,
                end: end,
                startRadius: baseRadius * radiusScale,
                endRadius: baseRadius * radiusScale * 0.78,
                feather: max(1.5, baseRadius * 0.22)
            )
            var raster = field.rasterized(
                subjectMask: subjectMask,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
            apply(
                corrections[partID] ?? [],
                to: &raster.weights,
                subjectMask: subjectMask
            )
            for index in ambiguity.values.indices {
                ambiguity.values[index] = max(
                    ambiguity.values[index],
                    raster.ambiguity.values[index]
                )
            }
            raw[partID] = raster.weights
        }

        var resolved = Dictionary(
            uniqueKeysWithValues: activeParts.map {
                ($0, FloatPlane(width: subjectMask.width, height: subjectMask.height))
            }
        )
        for index in subjectMask.values.indices {
            let ranked = activeParts
                .map { ($0, raw[$0]?.values[index] ?? 0) }
                .sorted { $0.1 > $1.1 }
            let total = ranked.reduce(Float.zero) { $0 + $1.1 }
            guard total > 0.001 else { continue }
            let coverage = min(1, total)
            for (partID, value) in ranked where value > 0 {
                resolved[partID]?.values[index] = value / total * coverage
            }
            if ranked.count > 1, ranked[0].1 > 0.08, ranked[1].1 > 0.08 {
                let separation = ranked[0].1 - ranked[1].1
                ambiguity.values[index] = max(
                    ambiguity.values[index],
                    1 - min(max(separation / 0.35, 0), 1)
                )
            }
        }
        return ArticulationOwnershipProposal(
            subjectMask: subjectMask,
            masks: resolved,
            ambiguity: ambiguity,
            activeParts: activeParts
        )
    }

    private func omissionReason(
        for partID: ArticulationPartID,
        pose: ReferencePose
    ) -> JointVisibility {
        let endpoints = partID.joints
        let values = [pose[endpoints.start]?.visibility, pose[endpoints.end]?.visibility]
        if values.contains(.outOfFrame) { return .outOfFrame }
        if values.contains(.occluded) { return .occluded }
        return .unknown
    }

    private func extractionMask(image: CGImage, source: Bitmap) async throws -> FloatPlane {
        let analysis = source.downscaled(maxDimension: 256)
        let context = AnalysisContext(
            originalImage: image,
            analysis: analysis,
            originalBitmap: source
        )
        for provider in maskProviders {
            guard let masks = await provider.masks(for: context) else { continue }
            return masks.extraction.resized(
                width: source.width,
                height: source.height
            )
        }
        throw ArticulationCompilerError.subjectNotFound
    }

    private func makeUnderpaint(
        source: Bitmap,
        subjectMask: FloatPlane,
        partMasks: [ArticulationPartID: FloatPlane]
    ) async -> Bitmap {
        let unknown = unionMask(
            partMasks.values,
            width: source.width,
            height: source.height
        )
        var result = source
        if let occlusionInpainter,
           let sourceImage = source.cgImage(),
           let maskImage = maskBitmap(unknown).cgImage(),
           let generated = try? await occlusionInpainter.inpaint(
               OcclusionInpaintingRequest(
                   sourceImage: sourceImage,
                   maskImage: maskImage
               )
           ),
           let generatedBitmap = Bitmap(image: generated),
           generatedBitmap.width == source.width,
           generatedBitmap.height == source.height {
            for y in 0..<source.height {
                for x in 0..<source.width {
                    let weight = unknown[x, y]
                    guard weight > 0 else { continue }
                    let original = result.rgba(x: x, y: y)
                    let replacement = generatedBitmap.rgba(x: x, y: y)
                    result.setRGBA(
                        x: x,
                        y: y,
                        original + (replacement - original) * weight
                    )
                }
            }
        } else if let region = bounds(of: unknown, threshold: 0.03) {
            let originX = Int(region.minX)
            let originY = Int(region.minY)
            HoleFiller.fillHole(in: &result, region: region) { localX, localY in
                unknown[originX + localX, originY + localY] > 0.12
            }
        }

        // Preserve the authoritative subject silhouette regardless of whether
        // the optional inpainting backend returned an opaque RGB image.
        for y in 0..<source.height {
            for x in 0..<source.width {
                let alpha = min(max(subjectMask[x, y], 0), 1)
                let color = result.rgba(x: x, y: y)
                guard color.w > 0.001 else {
                    result.setRGBA(x: x, y: y, .zero)
                    continue
                }
                let unpremultiplied = SIMD3(color.x, color.y, color.z) / color.w
                result.setRGBA(
                    x: x,
                    y: y,
                    SIMD4(
                        unpremultiplied.x * alpha,
                        unpremultiplied.y * alpha,
                        unpremultiplied.z * alpha,
                        alpha
                    )
                )
            }
        }
        return result
    }

    private func integrityMetrics(
        archive: ArticulationRigArchive,
        baseAlpha: FloatPlane,
        partAlpha: [String: FloatPlane],
        unknownMask: FloatPlane
    ) -> RigIntegrityMetrics {
        let imageRect = CGRect(
            x: 0,
            y: 0,
            width: archive.imageWidth,
            height: archive.imageHeight
        )
        let base = AvatarPart(
            id: "base",
            kind: .body,
            rect: imageRect,
            zOrder: 0,
            mesh: .grid(rect: imageRect, columns: 1, rows: 1)
        )
        let limbParts = archive.parts.map { part in
            AvatarPart(
                id: part.id.rawValue,
                kind: .accessory,
                rect: part.rect,
                zOrder: part.layerOrder.zOrder,
                mesh: part.mesh
            )
        }
        let rig = AvatarRig(
            imageWidth: archive.imageWidth,
            imageHeight: archive.imageHeight,
            parts: [base] + limbParts,
            parameters: []
        )
        let evaluator = ArticulationEvaluator(rig: archive)
        let rest = evaluator.evaluate(parameters: ArticulationPoseParameters())
        let bent = evaluator.evaluate(parameters: ArticulationPoseParameters(
            jointRotations: [
                .leftElbow: 25,
                .rightElbow: -25,
            ]
        ))
        var reference: [String: [SIMD2<Float>]] = ["base": base.mesh.vertices]
        var evaluated: [String: [SIMD2<Float>]] = ["base": base.mesh.vertices]
        for part in archive.parts {
            reference[part.id.rawValue] = rest[part.id]
            evaluated[part.id.rawValue] = bent[part.id]
        }
        var alpha = partAlpha
        alpha["base"] = baseAlpha
        return RigIntegrityMetrics.measure(
            rig: rig,
            evaluatedVertices: evaluated,
            referenceVertices: reference,
            alphaCoverageByPartID: alpha,
            unknownCoverageByPartID: ["base": unknownMask]
        )
    }

    private func vertexWeights(
        partID: ArticulationPartID,
        mesh: DeformableMesh,
        pose: ReferencePose,
        imageWidth: Int,
        imageHeight: Int
    ) throws -> [LBSVertexWeight] {
        let primary = boneID(for: partID)
        let secondary: ArticulationBoneID
        switch partID {
        case .leftUpperArm:
            secondary = .leftForearm
        case .rightUpperArm:
            secondary = .rightForearm
        case .leftForearm:
            secondary = .leftUpperArm
        case .rightForearm:
            secondary = .rightUpperArm
        }
        let joints = primary.joints
        let start = try imagePoint(
            joints.start,
            pose: pose,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let end = try imagePoint(
            joints.end,
            pose: pose,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let secondaryJoints = secondary.joints
        let secondaryStart = try imagePoint(
            secondaryJoints.start,
            pose: pose,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let secondaryEnd = try imagePoint(
            secondaryJoints.end,
            pose: pose,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let falloff = max(2, simd_distance(start, end) * 0.18)
        return mesh.vertices.map { vertex in
            let primaryDistance = distance(vertex, toSegmentFrom: start, to: end)
            let secondaryDistance = distance(
                vertex,
                toSegmentFrom: secondaryStart,
                to: secondaryEnd
            )
            let primaryInfluence = exp(-primaryDistance / falloff)
            let secondaryInfluence = exp(-secondaryDistance / falloff)
            let blend = min(
                0.5,
                secondaryInfluence / max(0.0001, primaryInfluence + secondaryInfluence)
            )
            return LBSVertexWeight(
                primaryBone: primary,
                secondaryBone: secondary,
                secondaryWeight: blend
            )
        }
    }

    private func distance(
        _ point: SIMD2<Float>,
        toSegmentFrom start: SIMD2<Float>,
        to end: SIMD2<Float>
    ) -> Float {
        let axis = end - start
        let lengthSquared = simd_length_squared(axis)
        guard lengthSquared > 1e-8 else { return simd_distance(point, start) }
        let t = min(max(simd_dot(point - start, axis) / lengthSquared, 0), 1)
        return simd_distance(point, start + axis * t)
    }

    private func extractedTexture(
        source: Bitmap,
        mask: FloatPlane,
        rect: CGRect
    ) -> Bitmap {
        var texture = source.cropped(to: rect)
        let originX = max(0, Int(rect.minX))
        let originY = max(0, Int(rect.minY))
        for y in 0..<texture.height {
            for x in 0..<texture.width {
                texture.scaleAlpha(
                    x: x,
                    y: y,
                    by: min(max(mask[originX + x, originY + y], 0), 1)
                )
            }
        }
        return texture
    }

    private func apply(
        _ strokes: [OwnershipBrushStroke],
        to mask: inout FloatPlane,
        subjectMask: FloatPlane
    ) {
        guard mask.width > 0, mask.height > 0 else { return }
        for stroke in strokes where !stroke.points.isEmpty {
            let radiusPixels = stroke.radius * Float(max(mask.width, mask.height))
            for y in 0..<mask.height {
                for x in 0..<mask.width {
                    let point = SIMD2(Float(x), Float(y))
                    let distance = strokeDistance(
                        point,
                        stroke: stroke,
                        width: mask.width,
                        height: mask.height
                    )
                    guard distance <= radiusPixels else { continue }
                    let weight = 1 - Interpolation.smoothstep(
                        radiusPixels * 0.65,
                        radiusPixels,
                        distance
                    )
                    switch stroke.mode {
                    case .add:
                        mask[x, y] = max(mask[x, y], weight * subjectMask[x, y])
                    case .remove:
                        mask[x, y] *= 1 - weight
                    }
                }
            }
        }
    }

    private func strokeDistance(
        _ point: SIMD2<Float>,
        stroke: OwnershipBrushStroke,
        width: Int,
        height: Int
    ) -> Float {
        let points = stroke.points.map {
            $0 * SIMD2(Float(max(1, width - 1)), Float(max(1, height - 1)))
        }
        guard var previous = points.first else { return .greatestFiniteMagnitude }
        var best = simd_distance(point, previous)
        for current in points.dropFirst() {
            let edge = current - previous
            let lengthSquared = simd_length_squared(edge)
            let t = lengthSquared > 1e-8
                ? min(max(simd_dot(point - previous, edge) / lengthSquared, 0), 1)
                : 0
            best = min(best, simd_distance(point, previous + edge * t))
            previous = current
        }
        return best
    }

    private func boneID(for partID: ArticulationPartID) -> ArticulationBoneID {
        switch partID {
        case .leftUpperArm: .leftUpperArm
        case .leftForearm: .leftForearm
        case .rightUpperArm: .rightUpperArm
        case .rightForearm: .rightForearm
        }
    }

    private func jointDistance(
        _ first: JointKind,
        _ second: JointKind,
        pose: ReferencePose,
        imageWidth: Int,
        imageHeight: Int
    ) throws -> Float {
        simd_distance(
            try imagePoint(
                first,
                pose: pose,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            ),
            try imagePoint(
                second,
                pose: pose,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
        )
    }

    private func imagePoint(
        _ joint: JointKind,
        pose: ReferencePose,
        imageWidth: Int,
        imageHeight: Int
    ) throws -> SIMD2<Float> {
        guard let observation = pose[joint] else {
            throw ArticulationCompilerError.requiredJointMissing(joint)
        }
        return observation.position * SIMD2(Float(imageWidth), Float(imageHeight))
    }

    private func unionMask<S: Sequence>(
        _ masks: S,
        width: Int,
        height: Int
    ) -> FloatPlane where S.Element == FloatPlane {
        var result = FloatPlane(width: width, height: height)
        for mask in masks {
            for index in result.values.indices where index < mask.values.count {
                result.values[index] = min(1, result.values[index] + mask.values[index])
            }
        }
        return result
    }

    private func bounds(of mask: FloatPlane, threshold: Float) -> CGRect? {
        var minX = mask.width
        var minY = mask.height
        var maxX = -1
        var maxY = -1
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask[x, y] > threshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    private func maskBitmap(_ mask: FloatPlane) -> Bitmap {
        var bitmap = Bitmap(width: mask.width, height: mask.height)
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let value = min(max(mask[x, y], 0), 1)
                bitmap.setRGBA(x: x, y: y, SIMD4(value, value, value, 1))
            }
        }
        return bitmap
    }

    private func pngData(_ image: CGImage?) -> Data? {
        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
