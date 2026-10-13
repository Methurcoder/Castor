import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Observation

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String

    var isBuiltInMicrophone: Bool {
        id == "BuiltInMicrophoneDevice"
            || name.localizedCaseInsensitiveContains("MacBook")
    }
}

enum AudioInputDeviceStore {
    private static let selectedDeviceKey = "Pomegranate.AudioInput.DeviceUID"

    static var selectedDeviceUID: String {
        get {
            let devices = availableDevices()
            if let saved = UserDefaults.standard.string(forKey: selectedDeviceKey),
               devices.contains(where: { $0.id == saved }) {
                return saved
            }
            return devices.first(where: \.isBuiltInMicrophone)?.id
                ?? devices.first?.id
                ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: selectedDeviceKey)
        }
    }

    static func availableDevices() -> [AudioInputDevice] {
        audioCaptureDevices()
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { lhs, rhs in
                if lhs.isBuiltInMicrophone != rhs.isBuiltInMicrophone {
                    return lhs.isBuiltInMicrophone
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func captureDevice(uid: String? = nil) -> AVCaptureDevice? {
        let selectedUID = uid ?? selectedDeviceUID
        return audioCaptureDevices()
            .first(where: { $0.uniqueID == selectedUID })
            ?? AVCaptureDevice.default(for: .audio)
    }

    private static func audioCaptureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func applySelectedDevice(to audioEngine: AVAudioEngine) throws {
        let uid = selectedDeviceUID
        guard !uid.isEmpty, let deviceID = audioDeviceID(forUID: uid) else {
            return
        }
        try audioEngine.inputNode.auAudioUnit.setDeviceID(deviceID)
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafePointer(to: &deviceUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                UnsafeRawPointer(uidPointer),
                &deviceIDSize,
                &deviceID
            )
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }
}

@MainActor
@Observable
final class AudioInputSettings {
    private(set) var devices: [AudioInputDevice] = []
    var selectedDeviceUID: String {
        didSet {
            AudioInputDeviceStore.selectedDeviceUID = selectedDeviceUID
        }
    }

    init() {
        devices = AudioInputDeviceStore.availableDevices()
        selectedDeviceUID = AudioInputDeviceStore.selectedDeviceUID
        if !selectedDeviceUID.isEmpty {
            AudioInputDeviceStore.selectedDeviceUID = selectedDeviceUID
        }
    }

    var selectedDeviceName: String {
        devices.first(where: { $0.id == selectedDeviceUID })?.name
            ?? "System default"
    }

    func refresh() {
        devices = AudioInputDeviceStore.availableDevices()
        if !devices.contains(where: { $0.id == selectedDeviceUID }) {
            selectedDeviceUID = AudioInputDeviceStore.selectedDeviceUID
        }
    }
}

extension Notification.Name {
    static let castorSpeechCaptureWillStart = Notification.Name(
        "Pomegranate.SpeechCaptureWillStart"
    )
    static let castorSpeechCaptureDidStop = Notification.Name(
        "Pomegranate.SpeechCaptureDidStop"
    )
}
