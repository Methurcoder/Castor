import AppKit
import Arils
import SwiftUI
import simd

/// Paints only the compiler's ambiguous ownership band. Green adds the selected
/// arm part, red removes it; strokes are persisted in normalized coordinates.
public struct ArticulationOwnershipEditor: View {
    private let image: NSImage
    private let pose: ReferencePose
    @Binding private var corrections: [ArticulationPartID: [OwnershipBrushStroke]]
    @Binding private var layerOrders: [ArticulationPartID: ArticulationLayerOrder]

    @State private var selectedPart: ArticulationPartID = .leftUpperArm
    @State private var brushMode: OwnershipBrushMode = .add
    @State private var brushRadius: Float = 0.025
    @State private var proposal: ArticulationOwnershipProposal?
    @State private var overlay: NSImage?
    @State private var activePoints: [SIMD2<Float>] = []
    @State private var revision = 0
    @State private var status = "所有マスクを解析中…"

    public init(
        image: NSImage,
        pose: ReferencePose,
        corrections: Binding<[ArticulationPartID: [OwnershipBrushStroke]]>,
        layerOrders: Binding<[ArticulationPartID: ArticulationLayerOrder]>
    ) {
        self.image = image
        self.pose = pose
        self._corrections = corrections
        self._layerOrders = layerOrders
    }

    public var body: some View {
        HStack(spacing: 14) {
            GeometryReader { proxy in
                let imageRect = Self.aspectFitRect(imageSize: image.size, in: proxy.size)
                ZStack {
                    Color.black.opacity(0.06)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .allowsHitTesting(false)
                    if let overlay {
                        Image(nsImage: overlay)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(0.72)
                            .allowsHitTesting(false)
                    }
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(brushGesture(in: imageRect))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .aspectRatio(
                max(image.size.width / max(image.size.height, 1), 0.5),
                contentMode: .fit
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("曖昧域ブラシ")
                    .font(.headline)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("パーツ", selection: $selectedPart) {
                    ForEach(activeParts) { part in
                        Text(part.rawValue).tag(part)
                    }
                }
                Picker("ブラシ", selection: $brushMode) {
                    Text("追加").tag(OwnershipBrushMode.add)
                    Text("除外").tag(OwnershipBrushMode.remove)
                }
                .pickerStyle(.segmented)
                Slider(
                    value: Binding(
                        get: { Double(brushRadius) },
                        set: { brushRadius = Float($0) }
                    ),
                    in: 0.008...0.08
                )

                Picker(
                    "前後",
                    selection: Binding(
                        get: { layerOrders[selectedPart] ?? .inFrontOfBody },
                        set: { layerOrders[selectedPart] = $0 }
                    )
                ) {
                    Text("腕を手前").tag(ArticulationLayerOrder.inFrontOfBody)
                    Text("腕を奥").tag(ArticulationLayerOrder.behindBody)
                }

                Button("選択パーツの最後のストロークを戻す") {
                    guard corrections[selectedPart]?.isEmpty == false else { return }
                    corrections[selectedPart]?.removeLast()
                    revision += 1
                }
                .disabled(corrections[selectedPart]?.isEmpty != false)
                Spacer()
            }
            .frame(width: 220)
        }
        .task(id: revision) {
            if !activeParts.contains(selectedPart), let first = activeParts.first {
                selectedPart = first
            }
            await refreshProposal()
        }
        .onChange(of: selectedPart) {
            revision += 1
        }
    }

    private var activeParts: [ArticulationPartID] {
        ArticulationPartID.allCases.filter { $0.hasVisibleTexture(in: pose) }
    }

    private func brushGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard rect.contains(value.location),
                      let proposal else { return }
                let point = Self.normalized(value.location, in: rect)
                let x = min(
                    proposal.ambiguity.width - 1,
                    max(0, Int(point.x * Float(proposal.ambiguity.width - 1)))
                )
                let y = min(
                    proposal.ambiguity.height - 1,
                    max(0, Int(point.y * Float(proposal.ambiguity.height - 1)))
                )
                guard proposal.ambiguity[x, y] > 0.04 else {
                    status = "紫の曖昧域内だけ修正できます。"
                    return
                }
                if activePoints.last.map({ simd_distance($0, point) > 0.002 }) ?? true {
                    activePoints.append(point)
                }
            }
            .onEnded { _ in
                guard !activePoints.isEmpty else { return }
                corrections[selectedPart, default: []].append(
                    OwnershipBrushStroke(
                        points: activePoints,
                        radius: brushRadius,
                        mode: brushMode
                    )
                )
                activePoints.removeAll(keepingCapacity: true)
                revision += 1
            }
    }

    @MainActor
    private func refreshProposal() async {
        guard let image = Self.cgImage(from: image) else {
            status = "画像を解析できません。"
            return
        }
        do {
            let result = try await ArticulationCompiler().proposeOwnership(
                image: image,
                pose: pose,
                corrections: corrections
            )
            proposal = result
            overlay = Self.overlayImage(
                proposal: result,
                selectedPart: selectedPart
            )
            status = result.activeParts.contains(selectedPart)
                ? "紫が曖昧域です。選択パーツは緑で表示します。"
                : "このパーツは元画像で遮蔽されているため生成しません。"
        } catch {
            status = error.localizedDescription
        }
    }

    private static func overlayImage(
        proposal: ArticulationOwnershipProposal,
        selectedPart: ArticulationPartID
    ) -> NSImage? {
        guard let selected = proposal.masks[selectedPart] else { return nil }
        var bitmap = Bitmap(width: selected.width, height: selected.height)
        for y in 0..<selected.height {
            for x in 0..<selected.width {
                let ownership = min(max(selected[x, y], 0), 1)
                let ambiguity = min(max(proposal.ambiguity[x, y], 0), 1)
                let green = SIMD4<Float>(0.1, 0.9, 0.35, ownership * 0.42)
                let purple = SIMD4<Float>(0.75, 0.15, 1, ambiguity * 0.65)
                let alpha = max(green.w, purple.w)
                guard alpha > 0 else { continue }
                let color = green + purple * (1 - green.w)
                bitmap.setRGBA(
                    x: x,
                    y: y,
                    SIMD4(color.x * alpha, color.y * alpha, color.z * alpha, alpha)
                )
            }
        }
        guard let cgImage = bitmap.cgImage() else { return nil }
        return NSImage(cgImage: cgImage, size: proposalSize(proposal))
    }

    private static func proposalSize(_ proposal: ArticulationOwnershipProposal) -> CGSize {
        CGSize(width: proposal.subjectMask.width, height: proposal.subjectMask.height)
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func aspectFitRect(imageSize: CGSize, in available: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: available)
        }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (available.width - size.width) * 0.5,
            y: (available.height - size.height) * 0.5,
            width: size.width,
            height: size.height
        )
    }

    private static func normalized(_ point: CGPoint, in rect: CGRect) -> SIMD2<Float> {
        guard rect.width > 0, rect.height > 0 else { return SIMD2(0.5, 0.5) }
        return SIMD2(
            Float(min(max((point.x - rect.minX) / rect.width, 0), 1)),
            Float(min(max((point.y - rect.minY) / rect.height, 0), 1))
        )
    }
}
