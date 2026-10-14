import AVFoundation
import Foundation
import Observation
import Vision
import CastorCore

@Observable
final class TrilobiteEngine {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "Pomegranate.trilobite.session")
    private let videoQueue = DispatchQueue(label: "Pomegranate.trilobite.video")
    private let audioQueue = DispatchQueue(label: "Pomegranate.trilobite.audio")
    private let videoDelegate = TrilobiteVideoDelegate()
    private let audioDelegate = TrilobiteAudioDelegate()
    private let notificationCenter: NotificationCenter
    private var speechCaptureObservers: [NSObjectProtocol] = []

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var lastFaceAnalysis = Date.distantPast
    private var latestFaceAnalysisID = 0
    private var smoothedAudioLevel = 0.0
    private var smoothedFaceAnalysisDurationMilliseconds = 0.0
    private(set) var conversationAudioCaptureActive = false

    private(set) var snapshot = TrilobiteInputSnapshot.inactive
    var isMicrophoneGuidancePresented = false
    private let defaults: UserDefaults
    private static let microphoneEnabledKey = "Castor.Input.Microphone.Enabled"
    private static let microphoneSetupKey = "Castor.Input.Microphone.FirstRunCompleted"
    private var microphoneStartupApplied = false

    init(notificationCenter: NotificationCenter = .default, defaults: UserDefaults = .standard) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        videoDelegate.onSample = { [weak self] sampleBuffer in
            self?.processVideo(sampleBuffer)
        }
        audioDelegate.onSample = { [weak self] sampleBuffer in
            self?.processAudio(sampleBuffer)
        }
        speechCaptureObservers = [
            notificationCenter.addObserver(
                forName: .castorSpeechCaptureWillStart,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setConversationAudioCaptureActive(true)
            },
            notificationCenter.addObserver(
                forName: .castorSpeechCaptureDidStop,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setConversationAudioCaptureActive(false)
            },
        ]
        refreshPermissions()
    }

    deinit {
        for observer in speechCaptureObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    func setCameraEnabled(_ isEnabled: Bool) {
        snapshot.cameraEnabled = isEnabled
        guard isEnabled else {
            configureSession()
            clearFace()
            return
        }

        requestCameraPermission()
    }

    func setMicrophoneEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Self.microphoneEnabledKey)
        snapshot.microphoneEnabled = isEnabled
        guard isEnabled else {
            configureSession()
            updateAudioLevel(0)
            return
        }

        requestMicrophonePermission()
    }

    /// Ask once after the first window appears, never in init or test construction.
    /// Subsequent launches honor the user's stored off/on choice.
    func beginFirstRunMicrophoneSetup() {
        guard !microphoneStartupApplied else { return }
        microphoneStartupApplied=true
        let stored=defaults.object(forKey:Self.microphoneEnabledKey).map { _ in defaults.bool(forKey:Self.microphoneEnabledKey) }
        let action=MicrophoneStartupPolicy.action(firstRunCompleted:defaults.bool(forKey:Self.microphoneSetupKey),storedEnabled:stored)
        defaults.set(true,forKey:Self.microphoneSetupKey)
        if action == .enable {setMicrophoneEnabled(true)}
    }

    func setAudioInputDevice(uid: String) {
        AudioInputDeviceStore.selectedDeviceUID = uid
        configureSession()
    }

    func setConversationAudioCaptureActive(_ isActive: Bool) {
        guard conversationAudioCaptureActive != isActive else {
            return
        }
        conversationAudioCaptureActive = isActive
        if isActive {
            updateAudioLevel(0)
        }
        configureSession()
    }

    func refreshAuthorizationState() {
        refreshPermissions()
        if snapshot.cameraPermission != .granted {
            snapshot.cameraEnabled = false
            clearFace()
        }
        if snapshot.microphonePermission != .granted {
            snapshot.microphoneEnabled = false
            updateAudioLevel(0)
        }
        configureSession()
    }

    private func refreshPermissions() {
        snapshot.cameraPermission = permissionState(for: AVCaptureDevice.authorizationStatus(for: .video))
        snapshot.microphonePermission = permissionState(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else {
                    return
                }

                Task { @MainActor [self] in
                    self.refreshPermissions()
                    if !granted {
                        self.snapshot.cameraEnabled = false
                        self.clearFace()
                    }
                    self.configureSession()
                }
            }
        } else {
            refreshPermissions()
            if snapshot.cameraPermission != .granted {
                snapshot.cameraEnabled = false
                clearFace()
            }
            configureSession()
        }
    }

    private func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else {
                    return
                }

                Task { @MainActor [self] in
                    self.refreshPermissions()
                    if !granted {
                        self.snapshot.microphoneEnabled = false
                        self.defaults.set(false, forKey: Self.microphoneEnabledKey)
                        self.isMicrophoneGuidancePresented = true
                        self.updateAudioLevel(0)
                    }
                    self.configureSession()
                }
            }
        } else {
            refreshPermissions()
            if snapshot.microphonePermission != .granted {
                snapshot.microphoneEnabled = false
                defaults.set(false, forKey: Self.microphoneEnabledKey)
                isMicrophoneGuidancePresented = true
                updateAudioLevel(0)
            }
            configureSession()
        }
    }

    private func configureSession() {
        let wantsCamera = snapshot.cameraEnabled && snapshot.cameraPermission == .granted
        let wantsMicrophone = snapshot.microphoneEnabled
            && snapshot.microphonePermission == .granted
            && !conversationAudioCaptureActive
        let videoDelegate = videoDelegate
        let audioDelegate = audioDelegate
        let videoQueue = videoQueue
        let audioQueue = audioQueue

        sessionQueue.async { [session] in
            session.beginConfiguration()
            session.sessionPreset = .medium
            removeExistingInputsAndOutputs(from: session)

            if wantsCamera,
               let camera = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: camera),
               session.canAddInput(input) {
                session.addInput(input)
            }

            if wantsCamera {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(videoDelegate, queue: videoQueue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
            }

            if wantsMicrophone,
               let microphone = AudioInputDeviceStore.captureDevice(),
               let input = try? AVCaptureDeviceInput(device: microphone),
               session.canAddInput(input) {
                session.addInput(input)
            }

            if wantsMicrophone {
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(audioDelegate, queue: audioQueue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
            }

            session.commitConfiguration()

            if wantsCamera || wantsMicrophone {
                if !session.isRunning {
                    session.startRunning()
                }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()
        let analysisInterval = 1 / TrilobiteFaceMetrics.targetAnalysisHertz
        guard now.timeIntervalSince(lastFaceAnalysis) >= analysisInterval else {
            return
        }
        lastFaceAnalysis = now
        latestFaceAnalysisID += 1
        let analysisID = latestFaceAnalysisID

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            Task { @MainActor in
                self.clearFace(analysisID: analysisID)
            }
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let request = VNDetectFaceLandmarksRequest { [weak self] request, _ in
            let durationMilliseconds = (
                ProcessInfo.processInfo.systemUptime - startedAt
            ) * 1_000
            Task { @MainActor in
                self?.handleFaceResults(
                    request.results as? [VNFaceObservation],
                    analysisID: analysisID,
                    durationMilliseconds: durationMilliseconds
                )
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            let durationMilliseconds = (
                ProcessInfo.processInfo.systemUptime - startedAt
            ) * 1_000
            Task { @MainActor in
                self.recordFaceAnalysisDuration(durationMilliseconds)
                self.clearFace(analysisID: analysisID)
            }
        }
    }

    private func handleFaceResults(
        _ faces: [VNFaceObservation]?,
        analysisID: Int,
        durationMilliseconds: Double
    ) {
        guard analysisID == latestFaceAnalysisID else {
            return
        }
        recordFaceAnalysisDuration(durationMilliseconds)

        guard let face = faces?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
            clearFace(analysisID: analysisID)
            return
        }

        let box = face.boundingBox
        let centerX = box.midX
        let centerY = box.midY
        snapshot.faceDetected = true
        snapshot.faceBoundingBox = box
        snapshot.faceArea = box.width * box.height
        snapshot.gazeX = (centerX - 0.5) * 28
        snapshot.gazeY = (0.5 - centerY) * 18
        snapshot.faceYawDegrees = Self.degrees(face.yaw)
        snapshot.facePitchDegrees = Self.degrees(face.pitch)
        snapshot.faceRollDegrees = Self.degrees(face.roll)
        snapshot.leftEyeAspectRatio = Self.aspectRatio(face.landmarks?.leftEye)
        snapshot.rightEyeAspectRatio = Self.aspectRatio(face.landmarks?.rightEye)
        snapshot.mouthAspectRatio = Self.aspectRatio(face.landmarks?.outerLips)
        snapshot.faceTrackingConfidence = Double(face.confidence)
        snapshot.faceLandmarksAvailable = face.landmarks != nil
        snapshot.updatedAt = .now
    }

    private static func degrees(_ radians: NSNumber?) -> Double {
        guard let radians else {
            return 0
        }
        let value = radians.doubleValue
        return value.isFinite ? value * 180 / .pi : 0
    }

    private static func aspectRatio(_ region: VNFaceLandmarkRegion2D?) -> Double {
        guard let region, region.pointCount >= 2 else {
            return 0
        }
        return TrilobiteFaceMetrics.aspectRatio(points: region.normalizedPoints)
    }

    private func recordFaceAnalysisDuration(_ durationMilliseconds: Double) {
        guard durationMilliseconds.isFinite, durationMilliseconds >= 0 else {
            return
        }
        if smoothedFaceAnalysisDurationMilliseconds == 0 {
            smoothedFaceAnalysisDurationMilliseconds = durationMilliseconds
        } else {
            smoothedFaceAnalysisDurationMilliseconds =
                smoothedFaceAnalysisDurationMilliseconds * 0.8
                + durationMilliseconds * 0.2
        }
        snapshot.faceAnalysisDurationMilliseconds =
            smoothedFaceAnalysisDurationMilliseconds
    }

    private func clearFace(analysisID: Int? = nil) {
        if let analysisID, analysisID != latestFaceAnalysisID {
            return
        }

        snapshot.faceDetected = false
        snapshot.faceBoundingBox = nil
        snapshot.faceArea = 0
        snapshot.gazeX = 0
        snapshot.gazeY = 0
        snapshot.faceYawDegrees = 0
        snapshot.facePitchDegrees = 0
        snapshot.faceRollDegrees = 0
        snapshot.leftEyeAspectRatio = 0
        snapshot.rightEyeAspectRatio = 0
        snapshot.mouthAspectRatio = 0
        snapshot.faceTrackingConfidence = 0
        snapshot.faceLandmarksAvailable = false
        snapshot.updatedAt = .now
    }

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else {
            return
        }

        var bytes = [UInt8](repeating: 0, count: length)
        let status = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: &bytes)
        guard status == kCMBlockBufferNoErr else {
            return
        }

        let level = audioLevel(from: bytes, sampleBuffer: sampleBuffer)
        Task { @MainActor in
            self.updateAudioLevel(level)
        }
    }

    private func audioLevel(from bytes: [UInt8], sampleBuffer: CMSampleBuffer) -> Double {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return int16AudioLevel(from: bytes)
        }

        let isFloat = (description.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        if isFloat {
            return float32AudioLevel(from: bytes)
        }

        return int16AudioLevel(from: bytes)
    }

    private func float32AudioLevel(from bytes: [UInt8]) -> Double {
        bytes.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float32.self)
            guard !samples.isEmpty else {
                return 0
            }

            let sum = samples.reduce(0.0) { result, sample in
                result + Double(sample * sample)
            }
            return min(1, sqrt(sum / Double(samples.count)) * 4.5)
        }
    }

    private func int16AudioLevel(from bytes: [UInt8]) -> Double {
        bytes.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else {
                return 0
            }

            let sum = samples.reduce(0.0) { result, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return result + normalized * normalized
            }
            return min(1, sqrt(sum / Double(samples.count)) * 5.5)
        }
    }

    private func updateAudioLevel(_ level: Double) {
        smoothedAudioLevel = smoothedAudioLevel * 0.72 + level * 0.28
        snapshot.audioLevel = smoothedAudioLevel
        snapshot.updatedAt = .now
    }

    private func permissionState(for status: AVAuthorizationStatus) -> TrilobitePermissionState {
        switch status {
        case .authorized:
            .granted
        case .denied, .restricted:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }
}

private func removeExistingInputsAndOutputs(from session: AVCaptureSession) {
    for input in session.inputs {
        session.removeInput(input)
    }

    for output in session.outputs {
        session.removeOutput(output)
    }
}

private final class TrilobiteVideoDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated(unsafe) var onSample: ((CMSampleBuffer) -> Void)?

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample?(sampleBuffer)
    }
}

private final class TrilobiteAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated(unsafe) var onSample: ((CMSampleBuffer) -> Void)?

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample?(sampleBuffer)
    }
}
