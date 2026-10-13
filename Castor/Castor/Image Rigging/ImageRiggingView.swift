import AppKit
import Arils
import SwiftUI
import UniformTypeIdentifiers
import CastorCore

struct ImageRiggingView: View {
    private static let qualityReferenceHelp = "Recommended: use a second full-body reference showing the same character turned about 60° to the left or right (a three-quarter view). Keep the pose, expression, framing, and scale as close to the front image as possible."

    let core: HesitateCore
    let trilobite: TrilobiteEngine
    let palette: CastorPalette
    let animationsPaused: Bool

    @State private var image: NSImage?
    @State private var document: RigDocument?
    @State private var selectedPartID: RigPart.ID?
    @State private var isRigImporterPresented = false
    @State private var isVoiceSelectionPresented = false
    @State private var isImageDropTargeted = false
    @State private var isImageAreaActive = false
    @State private var isRigApplied = false
    @State private var statusText = "Import an illustration to create a starter rig."
    @State private var arilsEngine: CharacterEngine?
    @State private var qualityEngine: QualityCharacterEngine?
    @State private var arilsPreviewMode: ArilsPreviewMode = .standard
    @State private var isArilsPreviewOn = false
    @State private var isArilsRigging = false
    @State private var isQualityAutoTurnOn = true
    /// Decoded source + analysis/full-resolution masks reused across candidate
    /// selection, face review, and Build for the current front image.
    @State private var arilsPreparedInput: PreparedRiggingInput?
    /// Changes whenever the front image changes. Async rigging work captures
    /// this value so an older image can never publish into the new flow.
    @State private var arilsImageGeneration = UUID()
    @State private var arilsCandidates: [RiggingSubjectCandidate] = []
    @State private var isArilsCandidateSelectionPresented = false
    @State private var isFaceAlignmentPresented = false
    @State private var faceLayoutProposal: FaceLayoutProposal?
    @State private var pendingArilsCandidate: RiggingSubjectCandidate?
    @State private var arilsFaceLayout: FaceLayout?
    /// The candidate (if any) used to build the current Standard Arils rig
    /// from `image`, reused so the Quality front view separates the same
    /// character out of a multi-subject image.
    @State private var arilsSelectedCandidate: RiggingSubjectCandidate?
    @State private var isQualitySideImporterPresented = false
    @State private var isQualityAssessmentPresented = false
    @State private var qualityAssessment: QualityPairAssessment?
    @State private var qualitySideFileName = "side reference"
    @State private var qualitySideImage: NSImage?
    /// Prepared token for the current Quality side reference.
    @State private var qualitySidePreparedInput: PreparedRiggingInput?
    /// Changes whenever the Quality side reference changes (or is cleared by
    /// a new front image).
    @State private var qualitySideImageGeneration = UUID()
    @State private var qualitySideDirection: QualitySideDirection = .right
    /// The candidate (if any) the user picked to separate the character out
    /// of a multi-subject side reference image.
    @State private var qualitySideCandidate: RiggingSubjectCandidate?
    @State private var qualitySideCandidates: [RiggingSubjectCandidate] = []
    @State private var isQualitySideCandidateSelectionPresented = false
    @State private var qualitySideFaceLayoutProposal: FaceLayoutProposal?
    @State private var qualitySideFaceLayout: FaceLayout?
    @State private var isQualitySideFaceAlignmentPresented = false
    /// Candidates found in the multi-subject front image when Quality is
    /// started directly (no Standard build picked one yet). Selection lands
    /// in `arilsSelectedCandidate`, shared with the Standard flow because
    /// both describe the same front image.
    @State private var qualityFrontCandidates: [RiggingSubjectCandidate] = []
    @State private var isQualityFrontCandidateSelectionPresented = false
    @AppStorage(ManualRiggingSettingsStore.enabledKey)
    private var isManualRiggingEnabled = ManualRiggingSettingsStore.defaultEnabled

    var body: some View {
        HStack(spacing: 18) {
            editorPanel
            if isManualRiggingEnabled {
                inspectorPanel
            }
        }
        .frame(maxWidth: 980, maxHeight: 620)
        .fileImporter(isPresented: $isRigImporterPresented, allowedContentTypes: [.json]) { result in
            importRig(result)
        }
        .fileImporter(isPresented: $isQualitySideImporterPresented, allowedContentTypes: [.image]) { result in
            importQualitySide(result)
        }
        .sheet(isPresented: $isVoiceSelectionPresented) {
            VoiceSelectionView(
                characterName: document?.imageName ?? "Imported character",
                palette: palette,
                refreshPetOnApply: false,
                onDismiss: {
                    isVoiceSelectionPresented = false
                }
            )
        }
        .sheet(isPresented: $isArilsCandidateSelectionPresented) {
            ArilsCandidateSelectionSheet(image: image, candidates: arilsCandidates) { candidate in
                isArilsCandidateSelectionPresented = false
                buildArilsPreview(selecting: candidate)
            }
        }
        .sheet(isPresented: $isFaceAlignmentPresented) {
            if let image, let proposal = faceLayoutProposal {
                ArilsFaceAlignmentSheet(
                    image: image,
                    proposal: proposal,
                    initialLayout: arilsFaceLayout,
                    build: { correctedLayout in
                        isFaceAlignmentPresented = false
                        arilsFaceLayout = correctedLayout
                        buildConfirmedArilsPreview(
                            selecting: pendingArilsCandidate,
                            faceLayout: correctedLayout
                        )
                    },
                    cancel: {
                        isFaceAlignmentPresented = false
                        pendingArilsCandidate = nil
                        statusText = "Arils face alignment was cancelled."
                    }
                )
            }
        }
        .sheet(isPresented: $isQualityFrontCandidateSelectionPresented) {
            ArilsCandidateSelectionSheet(image: image, candidates: qualityFrontCandidates) { candidate in
                isQualityFrontCandidateSelectionPresented = false
                arilsSelectedCandidate = candidate
                continueQualityFlowAfterFrontCandidateSelection()
            }
        }
        .sheet(isPresented: $isQualitySideCandidateSelectionPresented) {
            ArilsCandidateSelectionSheet(image: qualitySideImage, candidates: qualitySideCandidates) { candidate in
                isQualitySideCandidateSelectionPresented = false
                qualitySideCandidate = candidate
                continueQualityAssessmentAfterSideCandidateSelection()
            }
        }
        .sheet(isPresented: $isQualitySideFaceAlignmentPresented) {
            if let sideImage = qualitySideImage,
               let proposal = qualitySideFaceLayoutProposal {
                ArilsFaceAlignmentSheet(
                    image: sideImage,
                    proposal: proposal,
                    initialLayout: qualitySideFaceLayout,
                    build: { correctedLayout in
                        isQualitySideFaceAlignmentPresented = false
                        qualitySideFaceLayout = correctedLayout
                        buildQualityPreview()
                    },
                    cancel: {
                        isQualitySideFaceAlignmentPresented = false
                        statusText = "Quality side alignment was cancelled."
                    }
                )
            }
        }
        .sheet(isPresented: $isQualityAssessmentPresented) {
            QualityPairAssessmentSheet(
                assessment: qualityAssessment,
                sideFileName: qualitySideFileName,
                sideDirection: $qualitySideDirection,
                useQuality: beginQualitySideAlignment
            ) {
                isQualityAssessmentPresented = false
            }
        }
    }

    private var editorPanel: some View {
        VStack(spacing: 12) {
            ZStack {
                if isArilsPreviewOn, arilsPreviewMode.isQuality, let qualityEngine {
                    VStack(spacing: 8) {
                        QualityAvatarView(engine: qualityEngine)
                        HStack(spacing: 8) {
                            Toggle("Auto", isOn: $isQualityAutoTurnOn)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                                .help(
                                    arilsPreviewMode == .quality3D
                                        ? "視線ターゲット(ホバー)に合わせて左右・上下を自動で向く"
                                        : "視線ターゲット(ホバー)に合わせて左右を自動で向く"
                                )
                                .onChange(of: isQualityAutoTurnOn) { _, isOn in
                                    qualityEngine.automaticTurn = isOn
                                }
                            VStack(spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("左右")
                                        .frame(width: 28, alignment: .trailing)
                                    Slider(
                                        value: Binding(
                                            get: { Double(qualityEngine.viewTurn) },
                                            set: { qualityEngine.viewTurn = Float($0) }
                                        ),
                                        in: -1...1
                                    )
                                }
                                if arilsPreviewMode == .quality3D {
                                    HStack(spacing: 6) {
                                        Text("上下")
                                            .frame(width: 28, alignment: .trailing)
                                        Slider(
                                            value: Binding(
                                                get: { Double(qualityEngine.viewPitch) },
                                                set: { qualityEngine.viewPitch = Float($0) }
                                            ),
                                            in: -1...1
                                        )
                                    }
                                }
                            }
                            .font(.caption)
                            .frame(maxWidth: 180)
                            .disabled(isQualityAutoTurnOn)
                        }
                        .padding(.bottom, 6)
                    }
                    .padding(16)
                } else if isArilsPreviewOn, let arilsEngine {
                    // Arils runs its own display loop; the classic preview
                    // stack (image + overlay + renderer) is fully replaced.
                    AvatarView(engine: arilsEngine)
                        .padding(16)
                } else if let image, let document, isManualRiggingEnabled {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(isRigApplied ? 0.38 : 0.82)
                        if isRigApplied {
                            MotionParameterTimeline(
                                core: core,
                                trilobite: trilobite,
                                isPaused: animationsPaused
                            ) { parameters, _ in
                                RiggedCharacterRenderer(
                                    image: image,
                                    document: document,
                                    parameters: isImageAreaActive ? .neutral : parameters
                                )
                                .opacity(isImageAreaActive ? 0.72 : 0.96)
                            }
                        }
                        if !isRigApplied {
                            PartSelectionOverlay(document: documentBinding, selectedPartID: $selectedPartID)
                        }
                    }
                    .padding(16)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(isArilsRigging ? 0.5 : 0.82)
                        .overlay {
                            if isArilsRigging {
                                ProgressView()
                            }
                        }
                        .padding(16)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 42))
                        Text("Image Rigging")
                            .font(.title2.weight(.semibold))
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 520)
            .castorGlassSurface(
                palette: palette,
                borderColor: isImageDropTargeted ? palette.meterFill : nil,
                borderWidth: isImageDropTargeted ? 2 : 1
            )
            .contentShape(Rectangle())
            .onHover { isHovering in
                isImageAreaActive = isHovering
            }
            .onDrop(
                of: [.fileURL, .image],
                isTargeted: $isImageDropTargeted,
                perform: handleImageDrop
            )

            if !isManualRiggingEnabled, image != nil {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 10) {
                Button {
                    openImagePanel()
                } label: {
                    Label("Import Image", systemImage: "photo")
                }

                if isManualRiggingEnabled {
                    Button {
                        isRigImporterPresented = true
                    } label: {
                        Label("Load JSON", systemImage: "doc")
                    }

                    Button {
                        saveRig()
                    } label: {
                        Label("Save JSON", systemImage: "square.and.arrow.down")
                    }
                    .disabled(document == nil)

                    Button {
                        isRigApplied.toggle()
                        statusText = isRigApplied ? "Rig applied." : "Editing ranges."
                    } label: {
                        Label(isRigApplied ? "Edit Ranges" : "Apply Rig", systemImage: isRigApplied ? "slider.horizontal.3" : "play.fill")
                    }
                    .disabled(document == nil)
                }

                Button {
                    toggleArilsPreview()
                } label: {
                    if isArilsRigging {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Arils", systemImage: isArilsPreviewOn ? "wand.and.stars.inverse" : "wand.and.stars")
                    }
                }
                .disabled(image == nil || isArilsRigging || (isArilsPreviewOn && !isManualRiggingEnabled))
                .help(isArilsPreviewOn
                    ? "Back to the classic rig preview"
                    : "Auto-rig with the Arils engine and preview (hover: gaze, drag the head: pet)")

                Button {
                    pendingArilsCandidate = arilsSelectedCandidate
                    isFaceAlignmentPresented = true
                } label: {
                    Label("Adjust Face", systemImage: "face.dashed")
                }
                .disabled(image == nil || faceLayoutProposal == nil || isArilsRigging)
                .help("Review and correct the head, eye, and mouth positions")

                Button {
                    beginQualitySideAlignment()
                } label: {
                    Label("Adjust Side", systemImage: "person.crop.rectangle.badge.plus")
                }
                .disabled(qualitySideImage == nil || isArilsRigging)
                .help("Review the head, eye, mouth, and neck markers in the Quality side reference")

                Button {
                    isQualitySideImporterPresented = true
                } label: {
                    Label("Add Quality View", systemImage: "rectangle.on.rectangle")
                }
                .disabled(image == nil || isArilsRigging)
                .help(Self.qualityReferenceHelp)

                Picker("Arils mode", selection: $arilsPreviewMode) {
                    Text("Standard").tag(ArilsPreviewMode.standard)
                    Text("2D Quality")
                        .help(Self.qualityReferenceHelp)
                        .tag(ArilsPreviewMode.quality2D)
                    Text("3D Quality")
                        .help(Self.qualityReferenceHelp)
                        .tag(ArilsPreviewMode.quality3D)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 310)
                // The segmented picker is backed by one native control, so
                // keep the same help on the control as a reliable fallback in
                // addition to the per-Quality segment annotations above.
                .help(Self.qualityReferenceHelp)
                .onChange(of: arilsPreviewMode) { _, mode in
                    selectArilsPreviewMode(mode)
                }

                Button {
                    isVoiceSelectionPresented = true
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .disabled(image == nil || document == nil)
                .help("Choose the imported character's voice and personality")

                Button {
                    savePet()
                } label: {
                    Label("Save Pet", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.meterFill)
                .disabled(!canSavePet)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .castorGlassSurface(
                palette: palette,
                isElevated: false
            )
        }
    }

    private var inspectorPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rig Parts")
                .font(.headline)

            if let document {
                Picker("Part", selection: selectedPartBinding(document: document)) {
                    ForEach(document.parts) { part in
                        Text(part.kind.label).tag(Optional(part.id))
                    }
                }
                .labelsHidden()

                if let selectedPart {
                    partInspector(selectedPart)
                }

                Divider()

                Text("Layers are cut from the selected image at render time. JSON stores rectangles, shapes, anchors, and ordering.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No rig document yet.")
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()

            Text(statusText)
                .font(.caption.monospaced())
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .castorGlassSurface(palette: palette)
    }

    private func partInspector(_ part: RigPart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(part.kind.label)
                .font(.title3.weight(.semibold))

            Picker("Shape", selection: selectedShapeBinding(for: part.id)) {
                ForEach(RigPartShape.allCases) { shape in
                    Text(shape.rawValue).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading) {
                Text("Anchor X")
                Slider(value: selectedAnchorBinding(for: part.id, axis: .x), in: 0...1)
                Text("Anchor Y")
                Slider(value: selectedAnchorBinding(for: part.id, axis: .y), in: 0...1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("rect x \(part.normalizedRect.minX, format: .number.precision(.fractionLength(2)))")
                Text("rect y \(part.normalizedRect.minY, format: .number.precision(.fractionLength(2)))")
                Text("size \(part.normalizedRect.width, format: .number.precision(.fractionLength(2))) x \(part.normalizedRect.height, format: .number.precision(.fractionLength(2)))")
            }
            .font(.caption.monospaced())
            .foregroundStyle(palette.secondaryText)
        }
    }

    private var documentBinding: Binding<RigDocument> {
        Binding(
            get: { document ?? RigDocument.starter(imageName: nil, imageSize: CGSize(width: 1, height: 1)) },
            set: { document = $0 }
        )
    }

    private var selectedPart: RigPart? {
        guard let selectedPartID else {
            return document?.parts.first
        }
        return document?.parts.first(where: { $0.id == selectedPartID })
    }

    private func selectedPartBinding(document: RigDocument) -> Binding<RigPart.ID?> {
        Binding(
            get: { selectedPartID ?? document.parts.first?.id },
            set: { selectedPartID = $0 }
        )
    }

    private func selectedShapeBinding(for id: RigPart.ID) -> Binding<RigPartShape> {
        Binding(
            get: { selectedPart?.shape ?? .rectangle },
            set: { newShape in
                updatePart(id) { part in
                    part.shape = newShape
                }
            }
        )
    }

    private enum AnchorAxis {
        case x
        case y
    }

    private func selectedAnchorBinding(for id: RigPart.ID, axis: AnchorAxis) -> Binding<Double> {
        Binding(
            get: {
                guard let part = document?.parts.first(where: { $0.id == id }) else {
                    return 0.5
                }
                return axis == .x ? part.anchorPoint.x : part.anchorPoint.y
            },
            set: { value in
                updatePart(id) { part in
                    if axis == .x {
                        part.anchorPoint.x = value
                    } else {
                        part.anchorPoint.y = value
                    }
                }
            }
        )
    }

    private func updatePart(_ id: RigPart.ID, _ update: (inout RigPart) -> Void) {
        guard var current = document, let index = current.parts.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&current.parts[index])
        document = current
        isRigApplied = false
    }

    private func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        importImage(url)
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                guard let data,
                      let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? else {
                    Task { @MainActor in
                        statusText = "Image drop failed: \(error?.localizedDescription ?? "No file URL.")"
                    }
                    return
                }

                Task { @MainActor in
                    importImage(url)
                }
            }
            return true
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                guard let data, let droppedImage = NSImage(data: data) else {
                    Task { @MainActor in
                        statusText = "Image drop failed: \(error?.localizedDescription ?? "No image data.")"
                    }
                    return
                }

                Task { @MainActor in
                    importImageData(droppedImage, imageName: nil)
                }
            }
            return true
        }

        statusText = "Drop a PNG, JPEG, or other image file."
        return false
    }

    private func importImage(_ url: URL) {
        do {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            guard let importedImage = NSImage(data: data) else {
                statusText = "Could not read that image."
                return
            }

            importImageData(importedImage, imageName: url.lastPathComponent)
        } catch {
            statusText = "Image import failed: \(error.localizedDescription)"
        }
    }

    private func importImageData(_ importedImage: NSImage, imageName: String?) {
        arilsImageGeneration = UUID()
        qualitySideImageGeneration = UUID()
        image = importedImage
        document = RigDocument.starter(imageName: imageName, imageSize: importedImage.size)
        selectedPartID = document?.parts.first(where: { $0.kind == .head })?.id
        isRigApplied = false
        // A new image invalidates any previously built Arils rig.
        arilsEngine = nil
        qualityEngine = nil
        arilsPreviewMode = .standard
        isArilsPreviewOn = false
        isArilsRigging = false
        arilsPreparedInput = nil
        arilsCandidates = []
        arilsSelectedCandidate = nil
        arilsFaceLayout = nil
        faceLayoutProposal = nil
        pendingArilsCandidate = nil
        qualityAssessment = nil
        qualitySideImage = nil
        qualitySidePreparedInput = nil
        qualitySideCandidate = nil
        qualitySideCandidates = []
        qualityFrontCandidates = []
        isArilsCandidateSelectionPresented = false
        isFaceAlignmentPresented = false
        isQualityAssessmentPresented = false
        isQualityFrontCandidateSelectionPresented = false
        isQualitySideCandidateSelectionPresented = false
        isQualitySideFaceAlignmentPresented = false
        isQualityAutoTurnOn = true
        if isManualRiggingEnabled {
            statusText = "Starter rig created."
        } else {
            // Without the manual editor, Arils is the only way to rig, so start it right away.
            toggleArilsPreview()
        }
    }

    private func toggleArilsPreview() {
        if isArilsPreviewOn {
            isArilsPreviewOn = false
            statusText = "Back to the classic rig preview."
            return
        }
        if arilsEngine != nil {
            isArilsPreviewOn = true
            statusText = "Arils preview. Save Pet keeps this engine."
            return
        }
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusText = "Import an image before building an Arils rig."
            return
        }
        let frontGeneration = arilsImageGeneration
        isArilsRigging = true
        statusText = "Looking for separate characters…"
        Task { @MainActor in
            do {
                let pipeline = ArilsRiggingPipelines.make()
                let prepared = try await preparedFrontInput(
                    for: cgImage,
                    generation: frontGeneration,
                    using: pipeline
                )
                guard frontGeneration == arilsImageGeneration else { return }
                let candidates = pipeline.subjectCandidates(from: prepared)
                if candidates.count > 1 {
                    arilsCandidates = candidates
                    statusText = "Choose the character to animate."
                    isArilsCandidateSelectionPresented = true
                    isArilsRigging = false
                } else {
                    isArilsRigging = false
                    buildArilsPreview()
                }
            } catch {
                guard frontGeneration == arilsImageGeneration else { return }
                isArilsRigging = false
                statusText = arilsFailureStatus(error)
            }
        }
    }

    private func buildArilsPreview(selecting candidate: RiggingSubjectCandidate? = nil) {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusText = "Import an image before building an Arils rig."
            return
        }
        let frontGeneration = arilsImageGeneration
        // Remembered so a later Quality build separates the same character
        // out of this (possibly multi-subject) front image.
        arilsSelectedCandidate = candidate
        pendingArilsCandidate = candidate
        isArilsRigging = true
        statusText = candidate == nil ? "Finding the face for review…" : "Finding the selected character's face…"
        Task { @MainActor in
            defer {
                if frontGeneration == arilsImageGeneration {
                    isArilsRigging = false
                }
            }
            do {
                let pipeline = ArilsRiggingPipelines.make()
                let prepared = try await preparedFrontInput(
                    for: cgImage,
                    generation: frontGeneration,
                    using: pipeline
                )
                guard frontGeneration == arilsImageGeneration else { return }
                let proposal = try await pipeline.faceLayoutProposal(
                    from: prepared,
                    selecting: candidate
                )
                guard frontGeneration == arilsImageGeneration else { return }
                faceLayoutProposal = proposal
                isFaceAlignmentPresented = true
                statusText = proposal.review.requiresReview
                    ? "Face detection is uncertain. Check and correct the markers."
                    : "Check the face markers before rigging."
            } catch {
                guard frontGeneration == arilsImageGeneration else { return }
                statusText = arilsFailureStatus(error)
            }
        }
    }

    private func arilsFailureStatus(_ error: Error) -> String {
        guard !isManualRiggingEnabled else {
            return "Arils rigging failed: \(error)"
        }
        return "Arils rigging failed: \(error). Try Adjust Face, or enable Manual rigging in Settings › General › Advanced."
    }

    private var canSavePet: Bool {
        ManualRiggingSettingsStore.canSavePet(
            hasImage: image != nil,
            hasDocument: document != nil,
            hasArilsRig: arilsEngine != nil || qualityEngine != nil,
            manualRiggingEnabled: isManualRiggingEnabled
        )
    }

    private func buildConfirmedArilsPreview(
        selecting candidate: RiggingSubjectCandidate?,
        faceLayout: FaceLayout
    ) {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusText = "Import an image before building an Arils rig."
            return
        }
        let frontGeneration = arilsImageGeneration
        arilsSelectedCandidate = candidate
        isArilsRigging = true
        statusText = LaMaInpaintingSettingsStore.isEnabled
            ? "Building Arils and applying LaMa underpaint…"
            : "Building Arils from the confirmed face layout…"
        Task { @MainActor in
            defer {
                if frontGeneration == arilsImageGeneration {
                    isArilsRigging = false
                }
            }
            do {
                let (pipeline, laMaClient) = makeArchiveRiggingPipeline()
                let prepared = try await preparedFrontInput(
                    for: cgImage,
                    generation: frontGeneration,
                    using: pipeline
                )
                guard frontGeneration == arilsImageGeneration else { return }
                let avatar = try await pipeline.makeAvatar(
                    from: prepared,
                    selecting: candidate,
                    faceLayout: faceLayout
                )
                guard frontGeneration == arilsImageGeneration else { return }
                arilsEngine = CharacterEngine(avatar: avatar)
                arilsPreviewMode = .standard
                isArilsPreviewOn = true
                pendingArilsCandidate = nil
                // Candidate discovery and face review are complete. The built
                // avatar owns its textures, so release the decoded source and
                // full-resolution masks rather than pinning them in the view.
                arilsPreparedInput = nil
                statusText = completedRiggingStatus(
                    base: "Arils preview. Save Pet keeps the corrected face alignment.",
                    laMaClient: laMaClient
                )
            } catch {
                guard frontGeneration == arilsImageGeneration else { return }
                statusText = arilsFailureStatus(error)
            }
        }
    }

    private func importQualitySide(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                statusText = "Could not access the side reference image."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let sideImage = NSImage(contentsOf: url),
                  let frontImage = image,
                  let frontCG = frontImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let sideCG = sideImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                statusText = "Could not read the front/profile image pair."
                return
            }
            qualitySideFileName = url.lastPathComponent
            qualitySideImageGeneration = UUID()
            qualitySideImage = sideImage
            qualitySidePreparedInput = nil
            // A freshly imported side image invalidates any candidate chosen
            // for the previous one. The front image is unchanged, so any
            // front candidate already picked (Standard build or an earlier
            // Quality run) stays valid.
            qualitySideCandidate = nil
            qualitySideCandidates = []
            qualitySideFaceLayoutProposal = nil
            qualitySideFaceLayout = nil
            qualityFrontCandidates = []
            isQualityAssessmentPresented = false
            isQualityFrontCandidateSelectionPresented = false
            isQualitySideCandidateSelectionPresented = false
            isQualitySideFaceAlignmentPresented = false
            let frontGeneration = arilsImageGeneration
            let sideGeneration = qualitySideImageGeneration
            isArilsRigging = true
            statusText = "Looking for separate characters in the reference pair…"
            Task { @MainActor in
                do {
                    // Quality can start without a Standard build, so the
                    // front image may not have a chosen candidate yet.
                    if arilsSelectedCandidate == nil {
                        let pipeline = ArilsRiggingPipelines.make()
                        let prepared = try await preparedFrontInput(
                            for: frontCG,
                            generation: frontGeneration,
                            using: pipeline
                        )
                        guard generationsAreCurrent(
                            front: frontGeneration,
                            side: sideGeneration
                        ) else { return }
                        let frontCandidates = pipeline.subjectCandidates(from: prepared)
                        if frontCandidates.count > 1 {
                            isArilsRigging = false
                            qualityFrontCandidates = frontCandidates
                            statusText = "Choose the character in the front image."
                            isQualityFrontCandidateSelectionPresented = true
                            return
                        }
                    }
                    await checkQualitySideCandidates(
                        sideCG: sideCG,
                        frontGeneration: frontGeneration,
                        sideGeneration: sideGeneration
                    )
                } catch {
                    guard generationsAreCurrent(
                        front: frontGeneration,
                        side: sideGeneration
                    ) else { return }
                    isArilsRigging = false
                    statusText = "2D Quality check failed: \(error)"
                }
            }
        } catch {
            statusText = "2D Quality image import failed: \(error.localizedDescription)"
        }
    }

    /// Continues the Quality flow (side-candidate check, then assessment)
    /// after the user picked the character in the multi-subject front image.
    private func continueQualityFlowAfterFrontCandidateSelection() {
        guard let sideImage = qualitySideImage,
              let sideCG = sideImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusText = "Could not read the front/profile image pair."
            return
        }
        let frontGeneration = arilsImageGeneration
        let sideGeneration = qualitySideImageGeneration
        isArilsRigging = true
        Task { @MainActor in
            await checkQualitySideCandidates(
                sideCG: sideCG,
                frontGeneration: frontGeneration,
                sideGeneration: sideGeneration
            )
        }
    }

    /// Enumerates separable characters in the side reference: presents the
    /// selection sheet when there are several, otherwise proceeds straight
    /// to the pair assessment. Assumes `isArilsRigging` is already `true`
    /// and clears it (directly or via `runQualityAssessment`) when done.
    private func checkQualitySideCandidates(
        sideCG: CGImage,
        frontGeneration: UUID,
        sideGeneration: UUID
    ) async {
        guard generationsAreCurrent(
            front: frontGeneration,
            side: sideGeneration
        ) else { return }
        do {
            let pipeline = ArilsRiggingPipelines.make()
            let prepared = try await preparedQualitySideInput(
                for: sideCG,
                generation: sideGeneration,
                using: pipeline
            )
            guard generationsAreCurrent(
                front: frontGeneration,
                side: sideGeneration
            ) else { return }
            let candidates = pipeline.subjectCandidates(from: prepared)
            if candidates.count > 1 {
                isArilsRigging = false
                qualitySideCandidates = candidates
                statusText = "Choose the character in the side reference."
                isQualitySideCandidateSelectionPresented = true
            } else {
                await runQualityAssessment(
                    frontGeneration: frontGeneration,
                    sideGeneration: sideGeneration
                )
            }
        } catch {
            guard generationsAreCurrent(
                front: frontGeneration,
                side: sideGeneration
            ) else { return }
            isArilsRigging = false
            statusText = "2D Quality check failed: \(error)"
        }
    }

    /// Re-enters the Quality assessment flow after the user picked a
    /// candidate from the side-reference multi-subject sheet.
    private func continueQualityAssessmentAfterSideCandidateSelection() {
        let frontGeneration = arilsImageGeneration
        let sideGeneration = qualitySideImageGeneration
        isArilsRigging = true
        Task { @MainActor in
            await runQualityAssessment(
                frontGeneration: frontGeneration,
                sideGeneration: sideGeneration
            )
        }
    }

    /// Runs `assessQualityPair` using the current `image`/`qualitySideImage`
    /// and the selected front/side candidates. Assumes `isArilsRigging` is
    /// already `true` and clears it when done.
    private func runQualityAssessment(
        frontGeneration: UUID,
        sideGeneration: UUID
    ) async {
        guard generationsAreCurrent(
            front: frontGeneration,
            side: sideGeneration
        ) else { return }
        defer {
            if generationsAreCurrent(
                front: frontGeneration,
                side: sideGeneration
            ) {
                isArilsRigging = false
            }
        }
        guard let frontImage = image,
              let sideImage = qualitySideImage,
              let frontCG = frontImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let sideCG = sideImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusText = "Could not read the front/profile image pair."
            return
        }
        statusText = "Checking the 2D Quality reference pair…"
        do {
            let pipeline = ArilsRiggingPipelines.make()
            let preparedFront = try await preparedFrontInput(
                for: frontCG,
                generation: frontGeneration,
                using: pipeline
            )
            guard generationsAreCurrent(
                front: frontGeneration,
                side: sideGeneration
            ) else { return }
            let preparedSide = try await preparedQualitySideInput(
                for: sideCG,
                generation: sideGeneration,
                using: pipeline
            )
            guard generationsAreCurrent(
                front: frontGeneration,
                side: sideGeneration
            ) else { return }
            let assessment = try await pipeline.assessQualityPair(
                front: preparedFront,
                side: preparedSide,
                sideFileName: qualitySideFileName,
                frontCandidate: arilsSelectedCandidate,
                sideCandidate: qualitySideCandidate
            )
            guard generationsAreCurrent(
                front: frontGeneration,
                side: sideGeneration
            ) else { return }
            qualityAssessment = assessment
            isQualityAssessmentPresented = true
            statusText = assessment.warnings.isEmpty
                ? "2D Quality references look usable."
                : "2D Quality needs review before use."
        } catch {
            guard generationsAreCurrent(
                front: frontGeneration,
                side: sideGeneration
            ) else { return }
            statusText = "2D Quality check failed: \(error)"
        }
    }

    private func buildQualityPreview() {
        guard let frontImage = image,
              let sideImage = qualitySideImage,
              let frontCG = frontImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let sideCG = sideImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusText = "Choose both front and side images before building 2D Quality."
            return
        }
        let frontGeneration = arilsImageGeneration
        let sideGeneration = qualitySideImageGeneration
        isQualityAssessmentPresented = false
        isArilsRigging = true
        statusText = LaMaInpaintingSettingsStore.isEnabled
            ? "Building Arils-2D-Quality and applying LaMa underpaint…"
            : "Building Arils-2D-Quality…"
        Task { @MainActor in
            defer {
                if generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) {
                    isArilsRigging = false
                }
            }
            do {
                let (pipeline, laMaClient) = makeArchiveRiggingPipeline()
                let preparedFront = try await preparedFrontInput(
                    for: frontCG,
                    generation: frontGeneration,
                    using: pipeline
                )
                guard generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) else { return }
                let preparedSide = try await preparedQualitySideInput(
                    for: sideCG,
                    generation: sideGeneration,
                    using: pipeline
                )
                guard generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) else { return }
                let archive = try await pipeline.makeQualityArchive(
                    front: preparedFront,
                    side: preparedSide,
                    sideDirection: qualitySideDirection,
                    sideFileName: qualitySideFileName,
                    frontCandidate: arilsSelectedCandidate,
                    sideCandidate: qualitySideCandidate,
                    frontFaceLayout: arilsFaceLayout,
                    sideFaceLayout: qualitySideFaceLayout
                )
                guard generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) else { return }
                let engine = try QualityCharacterEngine(archive: archive)
                engine.automaticTurn = isQualityAutoTurnOn
                qualityEngine = engine
                arilsPreviewMode = .quality3D
                qualityEngine?.hybrid3DEnabled = true
                isArilsPreviewOn = true
                // The archive/engine now owns all rendered textures. Release
                // both heavyweight preparation tokens after the successful
                // front+side Build.
                arilsPreparedInput = nil
                qualitySidePreparedInput = nil
                let baseStatus = archive.assessment.warnings.isEmpty
                    ? "Arils-2D-Quality preview is ready."
                    : "Arils-2D-Quality preview is ready with reference warnings."
                statusText = completedRiggingStatus(base: baseStatus, laMaClient: laMaClient)
            } catch {
                guard generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) else { return }
                statusText = "Arils-2D-Quality build failed: \(error)"
            }
        }
    }

    /// Quality used to expose manual correction only for the frontal image,
    /// even though the pipeline already accepted `sideFaceLayout`. A profile
    /// or three-quarter face is the more failure-prone estimate, so review it
    /// explicitly before the archive is built.
    private func beginQualitySideAlignment() {
        isQualityAssessmentPresented = false
        guard let sideImage = qualitySideImage,
              let sideCG = sideImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusText = "Choose a side reference before adjusting its face alignment."
            return
        }
        let frontGeneration = arilsImageGeneration
        let sideGeneration = qualitySideImageGeneration
        if qualitySideFaceLayoutProposal != nil {
            // When invoked from the assessment sheet, let that presentation
            // dismiss before opening the cached alignment sheet. Presenting
            // both in the same run-loop turn can make AppKit ignore the second.
            Task { @MainActor in
                await Task.yield()
                guard generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) else { return }
                isQualitySideFaceAlignmentPresented = true
            }
            return
        }
        isArilsRigging = true
        statusText = "Detecting face markers in the Quality side reference…"
        Task { @MainActor in
            defer {
                if generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) {
                    isArilsRigging = false
                }
            }
            do {
                let pipeline = ArilsRiggingPipelines.make()
                let prepared = try await preparedQualitySideInput(
                    for: sideCG,
                    generation: sideGeneration,
                    using: pipeline
                )
                guard generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) else { return }
                let proposal = try await pipeline.faceLayoutProposal(
                    from: prepared,
                    selecting: qualitySideCandidate
                )
                guard generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) else { return }
                qualitySideFaceLayoutProposal = proposal
                isQualitySideFaceAlignmentPresented = true
                statusText = proposal.review.requiresReview
                    ? "Side-face detection is uncertain. Correct the markers before Build."
                    : "Check the side-reference markers before Build."
            } catch {
                guard generationsAreCurrent(
                    front: frontGeneration,
                    side: sideGeneration
                ) else { return }
                // A true profile may be outside the front-biased estimator's
                // domain. Do not dead-end the Quality flow: present a clearly
                // uncertain template that the user must place manually.
                qualitySideFaceLayoutProposal = fallbackSideFaceProposal(
                    imageSize: CGSize(width: sideCG.width, height: sideCG.height)
                )
                isQualitySideFaceAlignmentPresented = true
                statusText = "Side-face detection failed. Place the template markers manually before Build."
            }
        }
    }

    private func fallbackSideFaceProposal(imageSize: CGSize) -> FaceLayoutProposal {
        let normalized = qualitySideCandidate?.normalizedBounds
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let subject = CGRect(
            x: normalized.minX * imageSize.width,
            y: normalized.minY * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
        let headWidth = subject.width * 0.72
        let headHeight = min(subject.height * 0.48, headWidth * 1.15)
        let head = CGRect(
            x: subject.midX - headWidth * 0.5,
            y: subject.minY,
            width: headWidth,
            height: headHeight
        )
        let layout = FaceLayout(
            headRect: head,
            eyeLeftRect: CGRect(
                x: head.minX + head.width * 0.23,
                y: head.minY + head.height * 0.48,
                width: head.width * 0.17,
                height: head.height * 0.10
            ),
            eyeRightRect: CGRect(
                x: head.minX + head.width * 0.60,
                y: head.minY + head.height * 0.48,
                width: head.width * 0.17,
                height: head.height * 0.10
            ),
            mouthRect: CGRect(
                x: head.minX + head.width * 0.42,
                y: head.minY + head.height * 0.76,
                width: head.width * 0.16,
                height: head.height * 0.08
            ),
            confidence: 0.05
        )
        return FaceLayoutProposal(
            layout: layout,
            review: FaceLayoutReview(
                confidence: 0.05,
                issues: [.lowEstimatorConfidence]
            )
        )
    }

    @MainActor
    private func preparedFrontInput(
        for image: CGImage,
        generation: UUID,
        using pipeline: AutoRigPipeline
    ) async throws -> PreparedRiggingInput {
        guard generation == arilsImageGeneration else {
            throw CancellationError()
        }
        if let arilsPreparedInput {
            return arilsPreparedInput
        }
        let prepared = try await pipeline.prepare(image: image)
        guard generation == arilsImageGeneration else {
            throw CancellationError()
        }
        arilsPreparedInput = prepared
        return prepared
    }

    @MainActor
    private func preparedQualitySideInput(
        for image: CGImage,
        generation: UUID,
        using pipeline: AutoRigPipeline
    ) async throws -> PreparedRiggingInput {
        guard generation == qualitySideImageGeneration else {
            throw CancellationError()
        }
        if let qualitySidePreparedInput {
            return qualitySidePreparedInput
        }
        let prepared = try await pipeline.prepare(image: image)
        guard generation == qualitySideImageGeneration else {
            throw CancellationError()
        }
        qualitySidePreparedInput = prepared
        return prepared
    }

    @MainActor
    private func generationsAreCurrent(front: UUID, side: UUID) -> Bool {
        front == arilsImageGeneration && side == qualitySideImageGeneration
    }

    /// LaMa is archive-build-only and opt-in. Candidate discovery and face
    /// review stay deterministic and never wait for the optional service.
    private func makeArchiveRiggingPipeline() -> (AutoRigPipeline, LaMaInpaintingClient?) {
        guard LaMaInpaintingSettingsStore.isEnabled else {
            return (ArilsRiggingPipelines.make(), nil)
        }
        let client = LaMaInpaintingClient()
        return (ArilsRiggingPipelines.make(occlusionInpainter: client), client)
    }

    private func completedRiggingStatus(
        base: String,
        laMaClient: LaMaInpaintingClient?
    ) -> String {
        guard let report = laMaClient?.report, report.attempts > 0 else { return base }
        if report.usedFallback {
            let reason = report.lastFailure.map { " (\($0))" } ?? ""
            return "\(base) LaMa was unavailable for \(report.failures) view(s), so standard repair was used\(reason)."
        }
        return "\(base) LaMa underpaint was applied."
    }

    private func selectArilsPreviewMode(_ mode: ArilsPreviewMode) {
        switch mode {
        case .standard:
            guard arilsEngine != nil else {
                isArilsPreviewOn = false
                statusText = "Build a Standard Arils rig first."
                return
            }
            isArilsPreviewOn = true
        case .quality2D, .quality3D:
            guard qualityEngine != nil else {
                arilsPreviewMode = .standard
                statusText = "Build a 2D Quality pair first."
                return
            }
            qualityEngine?.hybrid3DEnabled = mode == .quality3D
            isArilsPreviewOn = true
            statusText = mode == .quality3D
                ? "3D Quality: depth turn + profile crossfade."
                : "2D Quality: front/profile crossfade."
        }
    }

    private func importRig(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                statusText = "Could not access the selected JSON."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: url)
            document = try RigDocument.decodeJSON(data)
            selectedPartID = document?.parts.first?.id
            isRigApplied = false
            statusText = "Loaded rig JSON. Re-import the matching image if needed."
        } catch {
            statusText = "JSON load failed: \(error.localizedDescription)"
        }
    }

    private func saveRig() {
        guard let document else {
            return
        }

        do {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "CastorRig.json"
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            try document.encodedJSON().write(to: url)
            statusText = "Saved \(url.lastPathComponent)."
        } catch {
            statusText = "JSON save failed: \(error.localizedDescription)"
        }
    }

    private func savePet() {
        guard canSavePet, let image, let document else {
            return
        }

        do {
            // The pet ships with whatever Arils rigs were built for this image:
            // the two-view Quality archive when available (the pet prefers it),
            // the standard archive as fallback, and always the classic
            // RiggedCharacterRenderer document for old-path compatibility.
            let arilsArchiveData = try arilsEngine?.archiveData()
            let qualityArchiveData = try qualityEngine?.archive.data()
            try PetCharacterStore.save(
                image: image,
                document: document,
                arilsArchiveData: arilsArchiveData,
                qualityArchiveData: qualityArchiveData
            )
            isRigApplied = true
            if qualityArchiveData != nil {
                statusText = "Pet saved with the Arils Quality engine (front + side). Double-click a screen edge to call it."
            } else if arilsArchiveData != nil {
                statusText = "Pet saved with the Arils engine. Double-click a screen edge to call it."
            } else {
                statusText = "Pet saved. Double-click a screen edge to call it."
            }
            CastorPetController.shared.showPet()
        } catch {
            statusText = "Pet save failed: \(error.localizedDescription)"
        }
    }
}

private struct ArilsFaceAlignmentSheet: View {
    private enum Feature: String, CaseIterable, Identifiable {
        case head = "Head / neck"
        case leftEye = "Left eye"
        case rightEye = "Right eye"
        case mouth = "Mouth"

        var id: Self { self }
        var color: Color {
            switch self {
            case .head: .cyan
            case .leftEye: .green
            case .rightEye: .blue
            case .mouth: .pink
            }
        }
    }

    let image: NSImage
    let proposal: FaceLayoutProposal
    let build: (FaceLayout) -> Void
    let cancel: () -> Void

    private let pixelSize: CGSize
    @State private var layout: FaceLayout
    @State private var automaticSourceID: String
    @State private var selectedFeature: Feature = .head
    @State private var aiCoordinator = ArilsAIAdjustmentCoordinator()
    @State private var aiTask: Task<Void, Never>?
    @State private var aiProposal: ArilsAIAdjustmentProposal?
    @State private var layoutBeforeAI: FaceLayout?
    @State private var aiError: String?
    @State private var isExternalSendConfirmationPresented = false

    init(
        image: NSImage,
        proposal: FaceLayoutProposal,
        initialLayout: FaceLayout?,
        build: @escaping (FaceLayout) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.image = image
        self.proposal = proposal
        self.build = build
        self.cancel = cancel
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            pixelSize = image.size
        }
        _layout = State(initialValue: initialLayout ?? proposal.layout)
        _automaticSourceID = State(initialValue: proposal.sourceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check face alignment")
                .font(.title2.weight(.semibold))
            Text("Drag each marker on the image. Use the sliders to correct its size. The cyan bottom edge is the neck cut used to move the head.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 18) {
                GeometryReader { geometry in
                    let transform = FaceAspectFitTransform(imageSize: pixelSize, canvasSize: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: transform.contentRect.width, height: transform.contentRect.height)
                            .position(x: transform.contentRect.midX, y: transform.contentRect.midY)

                        ForEach(Feature.allCases) { feature in
                            FaceAlignmentMarker(
                                rect: rectBinding(for: feature),
                                imageBounds: CGRect(origin: .zero, size: pixelSize),
                                transform: transform,
                                color: feature.color,
                                isSelected: selectedFeature == feature,
                                label: feature.rawValue,
                                select: { selectedFeature = feature }
                            )
                        }
                    }
                    .clipped()
                }
                .frame(minWidth: 500, minHeight: 500)
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Marker", selection: $selectedFeature) {
                            ForEach(Feature.allCases) { feature in
                                Text(feature.rawValue).tag(feature)
                            }
                        }

                        if automaticChoices.count > 1 {
                            Picker("Detection candidate", selection: $automaticSourceID) {
                                ForEach(automaticChoices) { candidate in
                                    Text(candidate.sourceLabel).tag(candidate.id)
                                }
                            }
                            .onChange(of: automaticSourceID) {
                                selectAutomaticCandidate()
                            }

                            Text("Candidates are reviewed independently. Switching does not build or save anything.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        coordinateSlider("X", component: .x)
                        coordinateSlider("Y", component: .y)
                        coordinateSlider("Width", component: .width)
                        coordinateSlider("Height", component: .height)

                        Divider()
                        Label(
                            "Automatic confidence: \(Int((selectedAutomaticChoice.review.confidence * 100).rounded()))%",
                            systemImage: selectedAutomaticChoice.review.requiresReview
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(selectedAutomaticChoice.review.requiresReview ? .orange : .green)

                        Text("Estimated by: \(selectedAutomaticChoice.sourceLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if AnimeFaceLandmarksSettingsStore.landmarkModelWasMissing(
                            enabled: AnimeFaceLandmarksSettingsStore.isEnabled,
                            candidateSources: automaticChoices.map(\.sourceLabel)
                        ) {
                            Label {
                                Text(AnimeFaceLandmarksSettingsStore.modelsAreInstalled
                                     ? "The anime landmark model found no face in this image, so the built-in estimator placed the markers."
                                     : "The anime landmark model is not included in this build, so the built-in estimator placed the markers.")
                            } icon: {
                                Image(systemName: "info.circle")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if selectedAutomaticChoice.review.issues.isEmpty {
                            Text("No geometric warning was found. Visual confirmation is still recommended.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(selectedAutomaticChoice.review.issues, id: \.self) { issue in
                                Text("• \(message(for: issue))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("The head box is a search area. Arils follows the nearby subject silhouette and facial markers to build a soft curved head/neck mask.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()
                        aiAdjustmentControls

                        Button("Reset to automatic") {
                            resetToAutomatic()
                        }
                    }
                }
                .frame(width: 300)
            }

            HStack {
                if !layoutIsValid {
                    Label("Put both eyes and the mouth inside the head, with the mouth below the eyes.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") {
                    stopAIWork()
                    cancel()
                }
                Button(aiProposal == nil ? "Build with this alignment" : "Approve AI alignment and build") {
                    stopAIWork()
                    build(layout)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!layoutIsValid)
            }
        }
        .padding(24)
        .frame(width: 900, height: 700)
        .alert(
            "Send image to \(aiSettings.provider.label)?",
            isPresented: $isExternalSendConfirmationPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Send image") { startAISuggestion() }
        } message: {
            Text("A temporary copy of this image and its current marker coordinates will be sent through the configured localhost \(aiSettings.provider.label) connection. The returned proposal will still require your approval.")
        }
        .onDisappear { stopAIWork() }
    }

    @ViewBuilder
    private var aiAdjustmentControls: some View {
        let settings = aiSettings

        Label("AI alignment suggestion", systemImage: "wand.and.stars")
            .font(.callout.weight(.semibold))

        Text("Reviewer: \(settings.provider.label). The suggestion only moves the markers in this preview; it cannot build or save the rig.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if aiCoordinator.isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(aiCoordinator.status.isEmpty ? "Reviewing alignment..." : aiCoordinator.status)
                    .font(.caption)
            }
        }

        if let approval = aiCoordinator.pendingApproval {
            VStack(alignment: .leading, spacing: 8) {
                Label(approval.title, systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
                Text(approval.detail)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("Decline") { aiCoordinator.resolvePendingApproval(approved: false) }
                    Button("Allow once") { aiCoordinator.resolvePendingApproval(approved: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }

        if let aiProposal {
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    "\(aiProposal.provider.label) confidence: \(Int((aiProposal.confidence * 100).rounded()))%",
                    systemImage: "eye.circle.fill"
                )
                .font(.caption.weight(.semibold))
                if !aiProposal.explanation.isEmpty {
                    Text(aiProposal.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Review the overlaid markers, adjust them if needed, then use the approval-and-build button below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }

        if let aiError {
            Label(aiError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack {
            Button(aiProposal == nil ? "Suggest with AI" : "Ask AI again") {
                requestAISuggestion()
            }
            .disabled(aiCoordinator.isWorking)

            if aiProposal != nil {
                Button("Revert AI suggestion") { revertAISuggestion() }
                    .buttonStyle(.plain)
            }
        }
    }

    private var aiSettings: ArilsAISettings {
        ArilsAISettingsStore.current
    }

    private var automaticChoices: [FaceLayoutAlternative] {
        [
            FaceLayoutAlternative(
                id: proposal.sourceID,
                sourceLabel: proposal.sourceLabel,
                layout: proposal.layout,
                review: proposal.review
            )
        ] + proposal.alternatives
    }

    private var selectedAutomaticChoice: FaceLayoutAlternative {
        automaticChoices.first { $0.id == automaticSourceID } ?? automaticChoices[0]
    }

    private func requestAISuggestion() {
        if aiSettings.provider.isExternal {
            isExternalSendConfirmationPresented = true
        } else {
            startAISuggestion()
        }
    }

    private func startAISuggestion() {
        stopAIWork()
        let currentLayout = layout
        let provider = aiSettings.provider
        layoutBeforeAI = currentLayout
        aiProposal = nil
        aiError = nil
        aiTask = Task { @MainActor in
            do {
                let suggestion = try await aiCoordinator.suggest(
                    image: image,
                    currentLayout: currentLayout,
                    review: selectedAutomaticChoice.review,
                    provider: provider
                )
                try Task.checkCancellation()
                layout = suggestion.layout
                aiProposal = suggestion
            } catch is CancellationError {
                // Closing the sheet or starting another request intentionally cancels this review.
            } catch {
                aiError = error.localizedDescription
            }
        }
    }

    private func revertAISuggestion() {
        if let layoutBeforeAI {
            layout = layoutBeforeAI
        }
        layoutBeforeAI = nil
        aiProposal = nil
        aiError = nil
    }

    private func resetToAutomatic() {
        stopAIWork()
        layout = selectedAutomaticChoice.layout
        layoutBeforeAI = nil
        aiProposal = nil
        aiError = nil
    }

    private func selectAutomaticCandidate() {
        stopAIWork()
        layout = selectedAutomaticChoice.layout
        layoutBeforeAI = nil
        aiProposal = nil
        aiError = nil
    }

    private func stopAIWork() {
        aiTask?.cancel()
        aiTask = nil
        aiCoordinator.cancel()
    }

    private enum RectComponent { case x, y, width, height }

    private func coordinateSlider(_ label: String, component: RectComponent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
            Slider(value: normalizedBinding(component), in: 0...1)
        }
    }

    private func normalizedBinding(_ component: RectComponent) -> Binding<Double> {
        Binding(
            get: {
                let rect = rect(for: selectedFeature)
                return switch component {
                case .x: Double(rect.minX / max(1, pixelSize.width))
                case .y: Double(rect.minY / max(1, pixelSize.height))
                case .width: Double(rect.width / max(1, pixelSize.width))
                case .height: Double(rect.height / max(1, pixelSize.height))
                }
            },
            set: { value in
                var rect = rect(for: selectedFeature)
                switch component {
                case .x: rect.origin.x = value * pixelSize.width
                case .y: rect.origin.y = value * pixelSize.height
                case .width: rect.size.width = max(2, value * pixelSize.width)
                case .height: rect.size.height = max(2, value * pixelSize.height)
                }
                setRect(rect.clamped(to: CGRect(origin: .zero, size: pixelSize)), for: selectedFeature)
            }
        )
    }

    private func rectBinding(for feature: Feature) -> Binding<CGRect> {
        Binding(
            get: { rect(for: feature) },
            set: { setRect($0, for: feature) }
        )
    }

    private func rect(for feature: Feature) -> CGRect {
        switch feature {
        case .head: layout.headRect
        case .leftEye: layout.eyeLeftRect
        case .rightEye: layout.eyeRightRect
        case .mouth: layout.mouthRect
        }
    }

    private func setRect(_ rect: CGRect, for feature: Feature) {
        switch feature {
        case .head: layout.headRect = rect
        case .leftEye: layout.eyeLeftRect = rect
        case .rightEye: layout.eyeRightRect = rect
        case .mouth: layout.mouthRect = rect
        }
    }

    private var layoutIsValid: Bool {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let rects = [layout.headRect, layout.eyeLeftRect, layout.eyeRightRect, layout.mouthRect]
        guard rects.allSatisfy({ $0.isFinitePositive && bounds.contains($0) }) else { return false }
        let head = layout.headRect
        let leftCenter = CGPoint(x: layout.eyeLeftRect.midX, y: layout.eyeLeftRect.midY)
        let rightCenter = CGPoint(x: layout.eyeRightRect.midX, y: layout.eyeRightRect.midY)
        let mouthCenter = CGPoint(x: layout.mouthRect.midX, y: layout.mouthRect.midY)
        return head.contains(leftCenter)
            && head.contains(rightCenter)
            && head.contains(mouthCenter)
            && leftCenter.x < rightCenter.x
            && mouthCenter.y > (leftCenter.y + rightCenter.y) / 2
    }

    private func message(for issue: FaceLayoutReviewIssue) -> String {
        switch issue {
        case .lowEstimatorConfidence: "Facial features were weak in the source image."
        case .headExtendsTooLow: "The detected head may extend into the torso."
        case .headIsTooLarge: "Hair or clothing may have been included in the head."
        case .eyesOutsideHead: "One or both eyes are outside the detected head."
        case .eyesMisaligned: "The eyes have an unusual vertical offset."
        case .eyesTooCloseOrFar: "The eye spacing looks unusual for this head."
        case .mouthOutsideHead: "The mouth is outside the detected head."
        case .mouthNotBelowEyes: "The mouth was not found below the eyes."
        case .mouthFarFromFaceAxis: "The mouth is far from the center between the eyes."
        }
    }
}

private struct FaceAspectFitTransform {
    let imageSize: CGSize
    let canvasSize: CGSize

    var contentRect: CGRect {
        let scale = min(
            canvasSize.width / max(1, imageSize.width),
            canvasSize.height / max(1, imageSize.height)
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvasSize.width - size.width) / 2,
            y: (canvasSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func displayRect(for imageRect: CGRect) -> CGRect {
        let content = contentRect
        return CGRect(
            x: content.minX + imageRect.minX / max(1, imageSize.width) * content.width,
            y: content.minY + imageRect.minY / max(1, imageSize.height) * content.height,
            width: imageRect.width / max(1, imageSize.width) * content.width,
            height: imageRect.height / max(1, imageSize.height) * content.height
        )
    }
}

private struct FaceAlignmentMarker: View {
    @Binding var rect: CGRect
    let imageBounds: CGRect
    let transform: FaceAspectFitTransform
    let color: Color
    let isSelected: Bool
    let label: String
    let select: () -> Void

    @State private var dragStart: CGRect?

    var body: some View {
        let displayRect = transform.displayRect(for: rect)
        RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(isSelected ? 0.20 : 0.09))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color, lineWidth: isSelected ? 3 : 2))
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .background(color.opacity(0.85), in: Capsule())
                    .offset(y: -16)
            }
            .frame(width: max(12, displayRect.width), height: max(12, displayRect.height))
            .position(x: displayRect.midX, y: displayRect.midY)
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        select()
                        let start = dragStart ?? rect
                        if dragStart == nil { dragStart = rect }
                        let content = transform.contentRect
                        var moved = start
                        moved.origin.x += value.translation.width / max(1, content.width) * imageBounds.width
                        moved.origin.y += value.translation.height / max(1, content.height) * imageBounds.height
                        rect = moved.clamped(to: imageBounds)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityLabel(label)
    }
}

private extension CGRect {
    var isFinitePositive: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width >= 2 && height >= 2
    }

    func clamped(to bounds: CGRect) -> CGRect {
        var result = standardized
        result.size.width = min(max(2, result.width), bounds.width)
        result.size.height = min(max(2, result.height), bounds.height)
        result.origin.x = min(max(bounds.minX, result.minX), bounds.maxX - result.width)
        result.origin.y = min(max(bounds.minY, result.minY), bounds.maxY - result.height)
        return result
    }
}

private struct ArilsCandidateSelectionSheet: View {
    let image: NSImage?
    let candidates: [RiggingSubjectCandidate]
    let select: (RiggingSubjectCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the character to animate")
                .font(.title3.weight(.semibold))
            Text("Only disconnected foreground regions can be separated. The characters you do not choose will become transparent.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let image {
                GeometryReader { geometry in
                    let imageSize = image.size
                    let scale = min(geometry.size.width / max(1, imageSize.width), geometry.size.height / max(1, imageSize.height))
                    let contentSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                    let origin = CGPoint(
                        x: (geometry.size.width - contentSize.width) / 2,
                        y: (geometry.size.height - contentSize.height) / 2
                    )
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: contentSize.width, height: contentSize.height)
                            .position(x: origin.x + contentSize.width / 2, y: origin.y + contentSize.height / 2)
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            let bounds = candidate.normalizedBounds
                            Button { select(candidate) } label: {
                                Text("\(index + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .padding(6)
                                    .background(Color.accentColor.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                            .frame(width: max(28, bounds.width * contentSize.width), height: max(28, bounds.height * contentSize.height))
                            .position(
                                x: origin.x + (bounds.minX + bounds.width / 2) * contentSize.width,
                                y: origin.y + (bounds.minY + bounds.height / 2) * contentSize.height
                            )
                        }
                    }
                }
                .frame(height: 420)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

private struct QualityPairAssessmentSheet: View {
    let assessment: QualityPairAssessment?
    let sideFileName: String
    @Binding var sideDirection: QualitySideDirection
    let useQuality: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Arils-2D-Quality reference check")
                .font(.title3.weight(.semibold))
            Text("正面画像と横向き画像を比較した事前確認です。確率は画像の色・シルエット・顔推定に基づく目安で、人物の同一性を断定するものではありません。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let assessment {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("同一人物らしさ")
                        Text(percent(assessment.sameCharacterConfidence))
                    }
                    GridRow {
                        Text("顔の読み取り信頼度")
                        Text(percent(assessment.faceReadabilityConfidence))
                    }
                }
                .font(.callout)

                if assessment.warnings.isEmpty {
                    Label("現時点で大きな警告はありません。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(assessment.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                Text("評価結果を取得できませんでした。")
                    .foregroundStyle(.secondary)
            }

            Text("横向き参照: \(sideFileName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("横向きの方向", selection: $sideDirection) {
                Text("Right").tag(QualitySideDirection.right)
                Text("Left").tag(QualitySideDirection.left)
            }
            HStack {
                Spacer()
                Button("Review side alignment", action: useQuality)
                    .buttonStyle(.borderedProminent)
                Button("Close", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func percent(_ value: Float) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }
}

private enum ArilsPreviewMode: Hashable {
    case standard
    case quality2D
    case quality3D

    var isQuality: Bool {
        self == .quality2D || self == .quality3D
    }
}
