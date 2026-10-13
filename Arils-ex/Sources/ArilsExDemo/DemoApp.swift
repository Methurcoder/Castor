import AppKit
import ArilsEx
import SwiftUI
import UniformTypeIdentifiers

@main
struct ArilsExDemoApp: App {
    var body: some Scene {
        WindowGroup("Arils-ex 3-view lab") {
            DemoView()
                .frame(minWidth: 980, minHeight: 720)
        }
    }
}

@MainActor
private struct DemoSlot {
    var role: ReferenceRole
    var image: NSImage?
    var cgImage: CGImage?
    var pose: ReferencePose
    var ownershipCorrections: [ArticulationPartID: [OwnershipBrushStroke]] = [:]
    var articulationLayerOrders: [ArticulationPartID: ArticulationLayerOrder] = [:]

    init(role: ReferenceRole) {
        self.role = role
        self.pose = ReferencePose(role: role, fileName: "")
    }
}

@MainActor
private struct DemoView: View {
    private enum EditMode: String, CaseIterable, Identifiable {
        case joints
        case ownership
        var id: String { rawValue }
    }

    @State private var slots = Dictionary(uniqueKeysWithValues: ReferenceRole.allCases.map {
        ($0, DemoSlot(role: $0))
    })
    @State private var selectedRole: ReferenceRole = .front
    @State private var engine: ThreeViewCharacterEngine?
    @State private var viewTurn: Float = 0
    @State private var armBend: Float = 0
    @State private var status = "3枚を読み込んでください。"
    @State private var isBuilding = false
    @State private var editMode: EditMode = .joints

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Arils-ex — 3画像ジョイントリグ")
                .font(.title2.bold())
            Text("正面・左向き・右向きを読み込み、自動提案された関節を必要な箇所だけ直します。画像は外部へ送信しません。")
                .foregroundStyle(.secondary)

            HStack {
                ForEach(ReferenceRole.allCases) { role in
                    Button("\(role.displayName)を選択…") { selectImage(for: role) }
                    if slots[role]?.image != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                Spacer()
                Button("3ビューをBuild") { build() }
                    .disabled(!allImagesLoaded || isBuilding)
            }

            Picker("編集ビュー", selection: $selectedRole) {
                ForEach(ReferenceRole.allCases) { role in
                    Text(role.displayName).tag(role)
                }
            }
            .pickerStyle(.segmented)
            Picker("編集内容", selection: $editMode) {
                Text("関節点").tag(EditMode.joints)
                Text("曖昧域ブラシ").tag(EditMode.ownership)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 18) {
                Group {
                    if let image = slots[selectedRole]?.image {
                        if editMode == .joints {
                            JointSelectionEditor(
                                image: image,
                                pose: poseBinding(for: selectedRole)
                            )
                        } else {
                            ArticulationOwnershipEditor(
                                image: image,
                                pose: slots[selectedRole]?.pose
                                    ?? ReferencePose(role: selectedRole, fileName: ""),
                                corrections: correctionsBinding(for: selectedRole),
                                layerOrders: layerOrdersBinding(for: selectedRole)
                            )
                        }
                    } else {
                        ContentUnavailableView(
                            "\(selectedRole.displayName)画像がありません",
                            systemImage: "photo.badge.plus"
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    if let engine {
                        ThreeViewAvatarView(engine: engine)
                            .aspectRatio(0.72, contentMode: .fit)
                        Slider(value: Binding(
                            get: { Double(viewTurn) },
                            set: {
                                viewTurn = Float($0)
                                engine.viewTurn = viewTurn
                            }
                        ), in: -1...1)
                        Text("向き: \(viewTurn, specifier: "%.2f")")
                            .font(.caption.monospacedDigit())
                        Slider(value: Binding(
                            get: { Double(armBend) },
                            set: {
                                armBend = Float($0)
                                updateArmPose(engine)
                            }
                        ), in: -30...30)
                        Text("腕メッシュ曲げ: \(armBend, specifier: "%.0f")°")
                            .font(.caption.monospacedDigit())
                    } else {
                        ContentUnavailableView("プレビュー未作成", systemImage: "person.crop.rectangle.stack")
                    }
                }
                .frame(width: 300)
            }

            HStack {
                if isBuilding { ProgressView().controlSize(.small) }
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private var allImagesLoaded: Bool {
        ReferenceRole.allCases.allSatisfy { slots[$0]?.cgImage != nil }
    }

    private func poseBinding(for role: ReferenceRole) -> Binding<ReferencePose> {
        Binding(
            get: { slots[role]?.pose ?? ReferencePose(role: role, fileName: "") },
            set: { newValue in
                guard var slot = slots[role] else { return }
                slot.pose = newValue
                slots[role] = slot
            }
        )
    }

    private func correctionsBinding(
        for role: ReferenceRole
    ) -> Binding<[ArticulationPartID: [OwnershipBrushStroke]]> {
        Binding(
            get: { slots[role]?.ownershipCorrections ?? [:] },
            set: { value in
                guard var slot = slots[role] else { return }
                slot.ownershipCorrections = value
                slots[role] = slot
            }
        )
    }

    private func layerOrdersBinding(
        for role: ReferenceRole
    ) -> Binding<[ArticulationPartID: ArticulationLayerOrder]> {
        Binding(
            get: { slots[role]?.articulationLayerOrders ?? [:] },
            set: { value in
                guard var slot = slots[role] else { return }
                slot.articulationLayerOrders = value
                slots[role] = slot
            }
        )
    }

    private func selectImage(for role: ReferenceRole) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            status = "画像をCGImageへ変換できませんでした。"
            return
        }
        var slot = DemoSlot(role: role)
        slot.image = image
        slot.cgImage = cgImage
        slot.pose.fileName = url.lastPathComponent
        slots[role] = slot
        selectedRole = role
        status = "\(url.lastPathComponent) の関節を提案中…"
        Task {
            let proposal = await JointProposalEngine().propose(
                for: cgImage,
                role: role,
                fileName: url.lastPathComponent
            )
            guard var current = slots[role] else { return }
            current.pose = proposal
            slots[role] = current
            status = "\(role.displayName)の提案を作成しました。黄色の点を確認してください。"
        }
    }

    private func build() {
        let inputs = ReferenceRole.allCases.compactMap { role -> ReferenceImageInput? in
            guard let slot = slots[role], let image = slot.cgImage else { return nil }
            return ReferenceImageInput(
                role: role,
                fileName: slot.pose.fileName,
                image: image,
                reviewedPose: slot.pose,
                ownershipCorrections: slot.ownershipCorrections,
                articulationLayerOrders: slot.articulationLayerOrders
            )
        }
        isBuilding = true
        status = "3枚を個別にリギングしています…"
        Task {
            defer { isBuilding = false }
            do {
                let archive = try await ThreeViewRigBuilder().build(from: inputs)
                engine = try ThreeViewCharacterEngine(archive: archive)
                engine?.viewTurn = viewTurn
                if let engine {
                    updateArmPose(engine)
                }
                let symmetry = archive.crossViewArticulation?.frontSymmetry
                    .map { "\($0.segment.rawValue) \(Int($0.score * 100))%" }
                    .joined(separator: " / ")
                let warning = archive.consensus.warnings.isEmpty
                    ? ""
                    : " \(archive.consensus.warnings.count)件の関節警告があります。"
                status = "Build完了。正面の腕対称度: \(symmetry ?? "未計測")。\(warning)"
            } catch {
                status = "Build失敗: \(error.localizedDescription)"
            }
        }
    }

    private func updateArmPose(_ engine: ThreeViewCharacterEngine) {
        engine.articulationPoseParameters = ArticulationPoseParameters(
            jointRotations: [
                .leftElbow: armBend,
                .rightElbow: -armBend,
            ]
        )
    }
}
