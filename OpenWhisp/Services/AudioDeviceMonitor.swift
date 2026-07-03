import Foundation
import CoreAudio

extension Notification.Name {
    /// Posted when the set of audio input devices changes (a mic was plugged
    /// in or unplugged).
    static let openWhispAudioDevicesChanged = Notification.Name("OpenWhispAudioDevicesChanged")
}

/// Listens for CoreAudio device-list changes and republishes them through
/// NotificationCenter, so the Settings microphone picker refreshes itself —
/// CoreAudio can tell us, so there's no manual "Refresh Devices" button
/// (redesign §6.5).
@MainActor
final class AudioDeviceMonitor {
    static let shared = AudioDeviceMonitor()

    private var started = false

    /// Idempotent: installs the CoreAudio listener once.
    func start() {
        guard !started else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { _, _ in
            NotificationCenter.default.post(name: .openWhispAudioDevicesChanged, object: nil)
        }
        started = (status == noErr)
    }
}
