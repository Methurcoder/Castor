import AppKit
import SwiftUI
import simd

/// Review surface for the automatically proposed skeleton. Select a joint and
/// click the image, or drag an existing marker. User edits are saved with full
/// confidence and are never replaced by cross-view consensus.
public struct JointSelectionEditor: View {
    private let image: NSImage
    @Binding private var pose: ReferencePose
    @State private var selectedJoint: JointKind = .neck

    public init(image: NSImage, pose: Binding<ReferencePose>) {
        self.image = image
        self._pose = pose
    }

    public var body: some View {
        HStack(spacing: 14) {
            GeometryReader { proxy in
                let imageRect = Self.aspectFitRect(imageSize: image.size, in: proxy.size)
                ZStack {
                    Color.black.opacity(0.06).allowsHitTesting(false)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .allowsHitTesting(false)
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("joint-editor")).onEnded { value in
                            guard imageRect.contains(value.location) else { return }
                            pose.setUserPosition(
                                Self.normalized(value.location, in: imageRect),
                                for: selectedJoint
                            )
                        })
                    boneOverlay(in: imageRect)
                    jointMarkers(in: imageRect)
                }
                .coordinateSpace(name: "joint-editor")
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .aspectRatio(max(image.size.width / max(image.size.height, 1), 0.5), contentMode: .fit)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(pose.role.displayName)の関節")
                        .font(.headline)
                    Text("点を選び、画像上をクリックまたはドラッグ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        "可視性",
                        selection: Binding(
                            get: { pose[selectedJoint]?.visibility ?? .unknown },
                            set: { pose.setUserVisibility($0, for: selectedJoint) }
                        )
                    ) {
                        ForEach(JointVisibility.allCases, id: \.self) { visibility in
                            Text(visibility.displayName).tag(visibility)
                        }
                    }
                    .pickerStyle(.menu)

                    if let side = Self.armSide(for: selectedJoint) {
                        HStack(spacing: 6) {
                            Button("腕全体を遮蔽") {
                                for joint in OcclusionTopology.armJoints(side) {
                                    pose.setUserVisibility(.occluded, for: joint)
                                }
                            }
                            Button("可視に戻す") {
                                for joint in OcclusionTopology.armJoints(side) {
                                    pose.setUserVisibility(.visible, for: joint)
                                }
                            }
                        }
                        .font(.caption)
                    }
                    ForEach(JointKind.allCases) { joint in
                        Button {
                            selectedJoint = joint
                        } label: {
                            HStack {
                                Circle()
                                    .fill(color(for: pose[joint]))
                                    .frame(width: 8, height: 8)
                                Text(joint.displayName)
                                Spacer()
                                if selectedJoint == joint {
                                    Image(systemName: "cursorarrow.click")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
                .padding(10)
            }
            .frame(width: 170)
        }
    }

    @ViewBuilder
    private func boneOverlay(in rect: CGRect) -> some View {
        Canvas { context, _ in
            for (from, to) in JointSkeleton.bones {
                guard
                    let a = pose[from]?.position,
                    let b = pose[to]?.position
                else { continue }
                var path = Path()
                path.move(to: Self.viewPoint(a, in: rect))
                path.addLine(to: Self.viewPoint(b, in: rect))
                context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 3)
                let hidden = pose[from]?.visibility != .visible
                    || pose[to]?.visibility != .visible
                context.stroke(
                    path,
                    with: .color(hidden ? .gray.opacity(0.8) : .blue.opacity(0.75)),
                    style: StrokeStyle(
                        lineWidth: 1.3,
                        dash: hidden ? [4, 3] : []
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func jointMarkers(in rect: CGRect) -> some View {
        ForEach(JointKind.allCases) { joint in
            if let observation = pose[joint] {
                let point = Self.viewPoint(observation.position, in: rect)
                Circle()
                    .fill(selectedJoint == joint ? Color.orange : color(for: observation))
                    .stroke(.white, lineWidth: 2)
                    .frame(width: selectedJoint == joint ? 16 : 13, height: selectedJoint == joint ? 16 : 13)
                    .opacity(observation.visibility == .visible ? 1 : 0.55)
                    .position(point)
                    .onTapGesture { selectedJoint = joint }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("joint-editor")).onChanged { value in
                        selectedJoint = joint
                        pose.setUserPosition(Self.normalized(value.location, in: rect), for: joint)
                    })
            }
        }
    }

    private func color(for observation: JointObservation?) -> Color {
        guard let observation else { return .red }
        if observation.visibility == .occluded || observation.visibility == .outOfFrame {
            return .gray
        }
        if observation.visibility == .unknown {
            return .orange
        }
        switch observation.source {
        case .user: return Color.green
        case .vision: return observation.confidence >= 0.5 ? Color.cyan : Color.yellow
        case .crossViewConsensus: return Color.purple
        case .silhouetteTemplate: return Color.yellow
        }
    }

    private static func armSide(for joint: JointKind) -> ArmSide? {
        if OcclusionTopology.armJoints(.left).contains(joint) { return .left }
        if OcclusionTopology.armJoints(.right).contains(joint) { return .right }
        return nil
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

    private static func viewPoint(_ normalized: SIMD2<Float>, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + CGFloat(normalized.x) * rect.width,
            y: rect.minY + CGFloat(normalized.y) * rect.height
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
