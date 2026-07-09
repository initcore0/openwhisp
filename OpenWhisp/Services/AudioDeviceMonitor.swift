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

    /// The property we observe: the system object's device list. Stored once so
    /// `stop()` removes the listener against the *identical* address it was
    /// added with (CoreAudio matches add/remove by address + queue + block).
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The exact block registered with CoreAudio. Removal requires the *same*
    /// block reference passed at add time, so we hold onto it until `stop()`.
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Idempotent: installs the CoreAudio listener once.
    func start() {
        guard listenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            NotificationCenter.default.post(name: .openWhispAudioDevicesChanged, object: nil)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        // Only remember the block if CoreAudio actually registered it, so a
        // failed add doesn't leave us trying to remove a listener that isn't
        // installed.
        if status == noErr {
            listenerBlock = block
        }
    }

    /// Symmetric teardown: removes the listener installed by `start()` using the
    /// identical block, address, and queue. Safe to call when not started.
    func stop() {
        guard let block = listenerBlock else { return }

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
    }

    deinit {
        // `deinit` is nonisolated; the listener block and address are only
        // touched here after the object is being torn down, so remove the
        // CoreAudio listener directly to guarantee symmetric teardown.
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
        }
    }
}
