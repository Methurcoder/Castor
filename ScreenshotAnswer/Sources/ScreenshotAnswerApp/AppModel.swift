import AppKit
import Foundation
import ScreenshotAnswerCore

@MainActor
final class AppModel: ObservableObject {
    @Published private var statusMessage = LocalizedInterfaceText(
        japanese: "起動中…",
        english: "Starting…"
    )
    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            guard hasChosenInterfaceLanguage else { return }
            UserDefaults.standard.set(interfaceLanguage.rawValue, forKey: Keys.interfaceLanguage)
        }
    }
    @Published private(set) var hasChosenInterfaceLanguage: Bool
    @Published var recognizedText = ""
    @Published var answer = ""
    @Published private(set) var canDescribeRecognizedContent = false
    @Published private(set) var currentImageURL: URL?
    @Published var availableModels: [String] = []
    @Published private(set) var availableModelInfos: [LMStudioModelInfo] = []
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.selectedModel) }
    }
    @Published var speculativeDecodingMode: SpeculativeDecodingMode {
        didSet {
            UserDefaults.standard.set(
                speculativeDecodingMode.rawValue,
                forKey: Keys.speculativeDecodingMode
            )
        }
    }
    @Published var selectedDraftModel: String {
        didSet { UserDefaults.standard.set(selectedDraftModel, forKey: Keys.selectedDraftModel) }
    }
    @Published var monitorsScreenshots: Bool {
        didSet {
            UserDefaults.standard.set(monitorsScreenshots, forKey: Keys.monitorsScreenshots)
            monitorsScreenshots ? startMonitor() : stopMonitor()
        }
    }
    @Published var copiesAnswer: Bool {
        didSet { UserDefaults.standard.set(copiesAnswer, forKey: Keys.copiesAnswer) }
    }
    @Published var showsAnswerPopup: Bool {
        didSet { UserDefaults.standard.set(showsAnswerPopup, forKey: Keys.showsAnswerPopup) }
    }
    @Published var captureStorageMode: CaptureStorageMode {
        didSet {
            UserDefaults.standard.set(captureStorageMode.rawValue, forKey: Keys.captureStorageMode)
        }
    }
    @Published private(set) var customCaptureDirectoryPath: String?
    @Published var systemAudioLanguage: SystemAudioLanguage {
        didSet { UserDefaults.standard.set(systemAudioLanguage.rawValue, forKey: Keys.systemAudioLanguage) }
    }
    @Published var organizesMultipleSpeakers: Bool {
        didSet {
            UserDefaults.standard.set(
                organizesMultipleSpeakers,
                forKey: Keys.organizesMultipleSpeakers
            )
        }
    }
    @Published var audioQuestion = ""
    @Published private(set) var audioTranscript = ""
    @Published private(set) var isListeningToSystemAudio = false
    @Published private(set) var audioElapsedSeconds = 0
    @Published private(set) var isBusy = false

    let screenshotDirectory = ScreenshotLocation.current()

    private let generator: LMStudioAnswerGenerator
    private let pipeline: ScreenshotAnswerPipeline
    private let overlayController = AnswerOverlayWindowController()
    private let recordingOverlayController = RecordingOverlayWindowController()
    private let systemAudioCapture = SystemAudioCaptureCoordinator()
    private var timer: Timer?
    private var systemAudioTimer: Timer?
    private var seenImages = Set<URL>()
    private var pendingImages: [PendingImage] = []
    private let startedAt = Date()
    private var didStart = false

    var status: String { statusMessage.value(for: interfaceLanguage) }

    init() {
        let defaults = UserDefaults.standard
        interfaceLanguage = InterfaceLanguage(
            rawValue: defaults.string(forKey: Keys.interfaceLanguage) ?? ""
        ) ?? .japanese
        hasChosenInterfaceLanguage = defaults.bool(forKey: Keys.hasChosenInterfaceLanguage)
        selectedModel = defaults.string(forKey: Keys.selectedModel) ?? ""
        speculativeDecodingMode = SpeculativeDecodingMode(
            rawValue: defaults.string(forKey: Keys.speculativeDecodingMode) ?? ""
        ) ?? .lmStudioDefault
        selectedDraftModel = defaults.string(forKey: Keys.selectedDraftModel) ?? ""
        monitorsScreenshots = defaults.object(forKey: Keys.monitorsScreenshots) as? Bool ?? true
        copiesAnswer = defaults.object(forKey: Keys.copiesAnswer) as? Bool ?? false
        showsAnswerPopup = defaults.object(forKey: Keys.showsAnswerPopup) as? Bool ?? true
        captureStorageMode = CaptureStorageMode(
            rawValue: defaults.string(forKey: Keys.captureStorageMode) ?? ""
        ) ?? .screenshotFolder
        customCaptureDirectoryPath = defaults.string(forKey: Keys.customCaptureDirectoryPath)
        systemAudioLanguage = SystemAudioLanguage(
            rawValue: defaults.string(forKey: Keys.systemAudioLanguage) ?? ""
        ) ?? .english
        organizesMultipleSpeakers = defaults.object(
            forKey: Keys.organizesMultipleSpeakers
        ) as? Bool ?? true
        generator = try! LMStudioAnswerGenerator()
        pipeline = ScreenshotAnswerPipeline(generator: generator)
        Task { @MainActor [weak self] in self?.start() }
    }

    func chooseInterfaceLanguage(_ language: InterfaceLanguage) {
        interfaceLanguage = language
        hasChosenInterfaceLanguage = true
        UserDefaults.standard.set(language.rawValue, forKey: Keys.interfaceLanguage)
        UserDefaults.standard.set(true, forKey: Keys.hasChosenInterfaceLanguage)
    }

    private func setStatus(_ japanese: String, _ english: String) {
        statusMessage = LocalizedInterfaceText(japanese: japanese, english: english)
    }

    private func setFailureStatus(
        japanesePrefix: String,
        englishPrefix: String,
        error: Error
    ) {
        statusMessage = LocalizedInterfaceText(
            japanese: "\(japanesePrefix): \(error.localizedDescription)",
            english: "\(englishPrefix): \(InterfaceLanguage.english.errorDescription(for: error))"
        )
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        seedSeenImages()
        Task {
            await refreshModels()
            if monitorsScreenshots { startMonitor() }
        }
    }

    func refreshModels() async {
        setStatus("LM Studioモデルを確認中…", "Checking LM Studio models…")
        do {
            let modelInfos = try await generator.availableModelInfos()
            availableModelInfos = modelInfos
            availableModels = modelInfos.map(\.key)
            if selectedModel.isEmpty || !availableModels.contains(selectedModel) {
                selectedModel = availableModels.first ?? ""
            }
            normalizeDraftModelSelection()
            if availableModels.isEmpty {
                let error = ScreenshotAnswerError.noLMStudioModel
                statusMessage = LocalizedInterfaceText(
                    japanese: error.localizedDescription,
                    english: InterfaceLanguage.english.errorDescription(for: error)
                )
            } else {
                setStatus("スクリーンショットを待っています", "Waiting for a screenshot")
            }
        } catch {
            availableModels = []
            availableModelInfos = []
            statusMessage = LocalizedInterfaceText(
                japanese: error.localizedDescription,
                english: InterfaceLanguage.english.errorDescription(for: error)
            )
        }
    }

    func captureSelection() {
        guard !isBusy else { return }
        guard let pendingImage = nextCapture() else { return }
        let imageURL = pendingImage.url
        setStatus("範囲を選択してください…", "Select an area…")
        hideWindowsForCapture()

        Task {
            // MenuBarExtraのパネルが画面から完全に退避してから
            // 範囲選択を始め、パネルの下もドラッグできるようにする。
            try? await Task.sleep(nanoseconds: 180_000_000)
            let captured = await Self.captureSelection(to: imageURL)
            guard captured else {
                setStatus("撮影をキャンセルしました", "Capture canceled")
                return
            }
            enqueue(imageURL, deleteAfterProcessing: pendingImage.deleteAfterProcessing)
        }
    }

    func chooseCustomCaptureDirectory() {
        let panel = NSOpenPanel()
        panel.title = interfaceLanguage.text("範囲撮影の保存先を選択", "Choose Capture Folder")
        panel.prompt = interfaceLanguage.text("選択", "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let customCaptureDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: customCaptureDirectoryPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customCaptureDirectoryPath = url.path
        captureStorageMode = .customFolder
        UserDefaults.standard.set(url.path, forKey: Keys.customCaptureDirectoryPath)
    }

    var customCaptureDirectoryDisplayName: String {
        guard let customCaptureDirectoryPath else {
            return interfaceLanguage.text("フォルダが未選択です", "No folder selected")
        }
        return URL(fileURLWithPath: customCaptureDirectoryPath).lastPathComponent
    }

    private func hideWindowsForCapture() {
        overlayController.dismissImmediately()
        for window in NSApp.windows where window.isVisible {
            window.orderOut(nil)
        }
    }

    func copyAnswer() {
        guard !answer.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(answer, forType: .string) {
            setStatus("回答をコピーしました", "Answer copied")
        }
    }

    func describeRecognizedContent() {
        guard !isBusy,
              currentImageURL != nil
                || !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selectedModel.isEmpty else { return }

        let text = recognizedText
        let imageURL = currentImageURL
        let model = selectedModel
        let options = generationOptions
        isBusy = true
        canDescribeRecognizedContent = false
        setStatus("内容を説明中…", "Explaining the content…")

        Task {
            do {
                let generated: String
                if let imageURL {
                    do {
                        generated = try await generator.describeImage(
                            imageURL: imageURL,
                            recognizedText: text,
                            model: model,
                            options: options
                        )
                    } catch ScreenshotAnswerError.imageModelRequired
                                where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        generated = try await generator.describe(
                            recognizedText: text,
                            model: model,
                            options: options
                        )
                    }
                } else {
                    generated = try await generator.describe(
                        recognizedText: text,
                        model: model,
                        options: options
                    )
                }
                answer = AnswerResponseClassifier.displayText(generated)
                setStatus("内容を説明しました", "Content explained")
                if copiesAnswer { copyAnswer() }
                if showsAnswerPopup {
                    overlayController.show(
                        answer: answer,
                        recognizedText: text.isEmpty
                            ? interfaceLanguage.text(
                                "画像（文字は検出されませんでした）",
                                "Image (no text was detected)"
                            )
                            : text,
                        language: interfaceLanguage,
                        onCopy: { [weak self] in self?.copyAnswer() }
                    )
                }
            } catch {
                setFailureStatus(
                    japanesePrefix: "説明できませんでした",
                    englishPrefix: "Could not explain the content",
                    error: error
                )
                if showsAnswerPopup {
                    overlayController.showFailure(
                        interfaceLanguage.errorDescription(for: error),
                        language: interfaceLanguage
                    )
                }
            }
            isBusy = false
            processNextIfNeeded()
        }
    }

    func openScreenshotDirectory() {
        if captureStorageMode == .customFolder,
           let customCaptureDirectoryPath {
            NSWorkspace.shared.open(URL(
                fileURLWithPath: customCaptureDirectoryPath,
                isDirectory: true
            ))
        } else {
            NSWorkspace.shared.open(screenshotDirectory)
        }
    }

    func scanNow() {
        scanForNewScreenshots()
    }

    var systemAudioElapsedText: String {
        String(format: "%d:%02d / 1:30", audioElapsedSeconds / 60, audioElapsedSeconds % 60)
    }

    var supportsSystemAudioListening: Bool {
        systemAudioCapture.isSupported
    }

    func startSystemAudioListening() {
        guard !isBusy, !isListeningToSystemAudio else { return }
        isBusy = true
        audioTranscript = ""
        audioElapsedSeconds = 0
        setStatus("音声認識モデルを準備中…", "Preparing the speech recognition model…")
        let language = systemAudioLanguage

        Task {
            do {
                try await systemAudioCapture.start(
                    language: language,
                    onTranscript: { [weak self] transcript in
                        Task { @MainActor in
                            guard let self else { return }
                            self.audioTranscript = transcript
                            self.recordingOverlayController.update(transcript: transcript)
                        }
                    }
                )
                isListeningToSystemAudio = true
                isBusy = false
                setStatus("🔴 システム音声を聞いています", "🔴 Listening to system audio")
                startSystemAudioTimer()
                hideWindowsForCapture()
                recordingOverlayController.show(
                    elapsedText: systemAudioElapsedText,
                    language: language.label(for: interfaceLanguage),
                    interfaceLanguage: interfaceLanguage,
                    question: audioQuestion,
                    transcript: audioTranscript,
                    organizesMultipleSpeakers: organizesMultipleSpeakers,
                    onStop: { [weak self] in self?.stopSystemAudioAndAnswer() }
                )
            } catch {
                isBusy = false
                setFailureStatus(
                    japanesePrefix: "音声を取得できません",
                    englishPrefix: "Could not capture audio",
                    error: error
                )
            }
        }
    }

    func stopSystemAudioAndAnswer() {
        guard isListeningToSystemAudio, !isBusy else { return }
        recordingOverlayController.dismiss()
        isListeningToSystemAudio = false
        isBusy = true
        stopSystemAudioTimer()
        setStatus("音声を文字起こし中…", "Transcribing audio…")

        Task {
            do {
                let transcript = try await systemAudioCapture.stop()
                audioTranscript = transcript
                try await generateAudioAnswer()
            } catch {
                setFailureStatus(
                    japanesePrefix: "音声を処理できません",
                    englishPrefix: "Could not process audio",
                    error: error
                )
                if showsAnswerPopup {
                    overlayController.showFailure(
                        interfaceLanguage.errorDescription(for: error),
                        language: interfaceLanguage
                    )
                }
            }
            isBusy = false
            processNextIfNeeded()
        }
    }

    func answerAboutCapturedAudio() {
        guard !isBusy,
              !audioTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selectedModel.isEmpty else { return }
        isBusy = true
        Task {
            do {
                try await generateAudioAnswer()
            } catch {
                setFailureStatus(
                    japanesePrefix: "音声について回答できません",
                    englishPrefix: "Could not answer about the audio",
                    error: error
                )
                if showsAnswerPopup {
                    overlayController.showFailure(
                        interfaceLanguage.errorDescription(for: error),
                        language: interfaceLanguage
                    )
                }
            }
            isBusy = false
            processNextIfNeeded()
        }
    }

    private func generateAudioAnswer() async throws {
        guard !selectedModel.isEmpty else {
            throw ScreenshotAnswerError.noLMStudioModel
        }
        setStatus("音声の内容を考え中…", "Thinking about the audio…")
        let screenshotContext = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = try await generator.answerAboutAudio(
            transcript: audioTranscript,
            screenshotText: screenshotContext.isEmpty ? nil : screenshotContext,
            userQuestion: audioQuestion,
            organizeMultipleSpeakers: organizesMultipleSpeakers,
            model: selectedModel,
            options: generationOptions
        )
        answer = AnswerResponseClassifier.displayText(generated)
        canDescribeRecognizedContent = false
        setStatus("音声の内容へ回答しました", "Answered about the audio")
        if copiesAnswer { copyAnswer() }
        if showsAnswerPopup {
            overlayController.show(
                answer: answer,
                recognizedText: interfaceLanguage.text(
                    "音声文字起こし: \(audioTranscript)",
                    "Audio transcript: \(audioTranscript)"
                ),
                language: interfaceLanguage,
                onCopy: { [weak self] in self?.copyAnswer() }
            )
        }
    }

    private func startSystemAudioTimer() {
        stopSystemAudioTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListeningToSystemAudio else { return }
                self.audioElapsedSeconds += 1
                self.recordingOverlayController.update(
                    elapsedText: self.systemAudioElapsedText
                )
                if self.audioElapsedSeconds >= 90 {
                    self.stopSystemAudioAndAnswer()
                }
            }
        }
        systemAudioTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSystemAudioTimer() {
        systemAudioTimer?.invalidate()
        systemAudioTimer = nil
    }

    private func startMonitor() {
        guard didStart, timer == nil else { return }
        setStatus("スクリーンショットを待っています", "Waiting for a screenshot")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanForNewScreenshots() }
        }
        scanForNewScreenshots()
    }

    private func stopMonitor() {
        timer?.invalidate()
        timer = nil
        if didStart { setStatus("自動監視は停止中です", "Automatic monitoring is off") }
    }

    private func seedSeenImages() {
        seenImages.formUnion(candidateImages())
    }

    private func scanForNewScreenshots() {
        let newImages = candidateImages()
            .filter { !seenImages.contains($0) }
            .filter { modificationDate(of: $0) >= startedAt.addingTimeInterval(-1) }
            .sorted { modificationDate(of: $0) < modificationDate(of: $1) }

        for image in newImages {
            enqueue(image)
        }
    }

    private func candidateImages() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: screenshotDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter(ScreenshotFileClassifier.isLikelyScreenshot)
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func enqueue(_ imageURL: URL, deleteAfterProcessing: Bool = false) {
        guard !seenImages.contains(imageURL) else { return }
        seenImages.insert(imageURL)
        pendingImages.append(PendingImage(
            url: imageURL,
            deleteAfterProcessing: deleteAfterProcessing
        ))
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isBusy, !pendingImages.isEmpty else { return }
        guard !selectedModel.isEmpty else {
            let error = ScreenshotAnswerError.noLMStudioModel
            statusMessage = LocalizedInterfaceText(
                japanese: error.localizedDescription,
                english: InterfaceLanguage.english.errorDescription(for: error)
            )
            removeTemporaryPendingImages()
            return
        }

        let pendingImage = pendingImages.removeFirst()
        let imageURL = pendingImage.url
        let model = selectedModel
        let options = generationOptions
        isBusy = true
        setStatus("文字を認識中…", "Recognizing text…")
        recognizedText = ""
        answer = ""
        canDescribeRecognizedContent = false
        currentImageURL = imageURL

        Task {
            defer {
                if pendingImage.deleteAfterProcessing {
                    try? FileManager.default.removeItem(at: imageURL)
                    seenImages.remove(imageURL)
                    if currentImageURL == imageURL { currentImageURL = nil }
                }
                isBusy = false
                processNextIfNeeded()
            }
            do {
                let result = try await pipeline.process(
                    imageURL: imageURL,
                    model: model,
                    options: options
                )
                recognizedText = result.recognizedText
                var resolvedAnswer = result.answer
                if result.offersContentExplanation {
                    if availableModelInfos.isEmpty,
                       let modelInfos = try? await generator.availableModelInfos() {
                        availableModelInfos = modelInfos
                        availableModels = modelInfos.map(\.key)
                    }
                    if let visionModel = LMStudioVisionModelSelector.closestVisionModel(
                        to: model,
                        among: availableModelInfos
                    ) {
                        setStatus("画像の内容を自動説明中…", "Automatically explaining the image…")
                        resolvedAnswer = try await generator.describeImage(
                            imageURL: imageURL,
                            recognizedText: result.recognizedText,
                            model: visionModel.key,
                            options: LMStudioGenerationOptions()
                        )
                        setStatus("画像の内容を説明しました", "Image explained")
                    } else {
                        resolvedAnswer = interfaceLanguage.text(
                            "OCR内に質問がなく、Visionモデルがなかったため回答を停止しました。",
                            "No question was found in the OCR text, and no vision model was available, so answering was stopped."
                        )
                        setStatus("Visionモデルがないため停止しました", "Stopped because no vision model is available")
                    }
                } else {
                    setStatus("回答を生成しました", "Answer generated")
                }
                answer = AnswerResponseClassifier.displayText(resolvedAnswer)
                canDescribeRecognizedContent = false
                if copiesAnswer { copyAnswer() }
                if showsAnswerPopup {
                    overlayController.show(
                        answer: answer,
                        recognizedText: result.recognizedText.isEmpty
                            ? interfaceLanguage.text(
                                "画像（文字は検出されませんでした）",
                                "Image (no text was detected)"
                            )
                            : result.recognizedText,
                        language: interfaceLanguage,
                        onCopy: { [weak self] in self?.copyAnswer() }
                    )
                }
            } catch {
                setFailureStatus(
                    japanesePrefix: "処理できませんでした",
                    englishPrefix: "Could not process the screenshot",
                    error: error
                )
                if showsAnswerPopup {
                    overlayController.showFailure(
                        interfaceLanguage.errorDescription(for: error),
                        language: interfaceLanguage
                    )
                }
            }
        }
    }

    private func nextCapture() -> PendingImage? {
        let directory: URL
        let deleteAfterProcessing: Bool
        switch captureStorageMode {
        case .screenshotFolder:
            directory = screenshotDirectory
            deleteAfterProcessing = false
        case .customFolder:
            guard let customCaptureDirectoryPath else {
                setStatus("保存先フォルダを選択してください", "Choose a capture folder first")
                return nil
            }
            directory = URL(fileURLWithPath: customCaptureDirectoryPath, isDirectory: true)
            deleteAfterProcessing = false
        case .temporary:
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScreenshotAnswer-Captures", isDirectory: true)
            deleteAfterProcessing = true
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            setFailureStatus(
                japanesePrefix: "撮影の保存先を準備できません",
                englishPrefix: "Could not prepare the capture folder",
                error: error
            )
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "Screenshot Answer \(formatter.string(from: Date()))"
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("png")
            suffix += 1
        }
        return PendingImage(url: candidate, deleteAfterProcessing: deleteAfterProcessing)
    }

    private func removeTemporaryPendingImages() {
        for pendingImage in pendingImages where pendingImage.deleteAfterProcessing {
            try? FileManager.default.removeItem(at: pendingImage.url)
            seenImages.remove(pendingImage.url)
        }
        pendingImages.removeAll()
    }

    var availableDraftModels: [String] {
        availableModels.filter { $0 != selectedModel }
    }

    var generationOptions: LMStudioGenerationOptions {
        guard speculativeDecodingMode == .draftModel else {
            return LMStudioGenerationOptions()
        }
        return LMStudioGenerationOptions(draftModel: selectedDraftModel)
    }

    private func normalizeDraftModelSelection() {
        let candidates = availableDraftModels
        if !candidates.contains(selectedDraftModel) {
            selectedDraftModel = candidates.first ?? ""
        }
        if candidates.isEmpty {
            speculativeDecodingMode = .lmStudioDefault
        }
    }

    nonisolated private static func captureSelection(to imageURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-i", "-s", "-t", "png", imageURL.path]
                do {
                    try capture.run()
                    capture.waitUntilExit()
                    continuation.resume(returning:
                        capture.terminationStatus == 0
                        && FileManager.default.fileExists(atPath: imageURL.path)
                    )
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

private enum Keys {
    static let interfaceLanguage = "ScreenshotAnswer.interfaceLanguage"
    static let hasChosenInterfaceLanguage = "ScreenshotAnswer.hasChosenInterfaceLanguage"
    static let selectedModel = "ScreenshotAnswer.selectedModel"
    static let speculativeDecodingMode = "ScreenshotAnswer.speculativeDecodingMode"
    static let selectedDraftModel = "ScreenshotAnswer.selectedDraftModel"
    static let monitorsScreenshots = "ScreenshotAnswer.monitorsScreenshots"
    static let copiesAnswer = "ScreenshotAnswer.copiesAnswer"
    static let showsAnswerPopup = "ScreenshotAnswer.showsAnswerPopup"
    static let captureStorageMode = "ScreenshotAnswer.captureStorageMode"
    static let customCaptureDirectoryPath = "ScreenshotAnswer.customCaptureDirectoryPath"
    static let systemAudioLanguage = "ScreenshotAnswer.systemAudioLanguage"
    static let organizesMultipleSpeakers = "ScreenshotAnswer.organizesMultipleSpeakers"
}

private struct PendingImage {
    let url: URL
    let deleteAfterProcessing: Bool
}

enum SpeculativeDecodingMode: String, CaseIterable, Identifiable {
    case lmStudioDefault
    case draftModel

    var id: String { rawValue }

    func label(for language: InterfaceLanguage) -> String {
        switch self {
        case .lmStudioDefault:
            language.text("LM Studio側の設定", "LM Studio settings")
        case .draftModel:
            language.text("Draft Modelを指定", "Specify a Draft Model")
        }
    }
}
