import Foundation
import AVFoundation
import CoreAudio

/// CoreAudio glue for routing dictation capture to a chosen input device.
///
/// This is the ONE place that turns a stored `microphoneID` (a device UID) into a
/// live capture on that device. Three capture stacks need it and used to each
/// re-implement pieces of it (or skip it entirely — the streaming engines never
/// applied the selection at all, which is why a non-default mic was silently
/// ignored):
///
/// - `AudioRecorder` (legacy whisper.cpp file/chunk path): AVAudioEngine streaming
///   sets the device per-engine; the AVAudioRecorder file path captures the default
///   only, so it swaps + restores the system default.
/// - `AppleSpeechEngine`: sets the device on its own AVAudioEngine input node.
/// - `WhisperKitStreamingEngine`: WhisperKit 1.0.0's `AudioStreamTranscriber` owns
///   the mic and exposes no per-engine device seam, so it swaps + restores the
///   system default around stream start (capture-and-restore).
///
/// `AudioInputRoutingPolicy` (in OpenWhispCore) holds the pure decision logic;
/// this holds the platform calls it can't.
enum AudioInputRouter {

    // MARK: Resolution

    /// Resolve a stored `microphoneID` UID to a live CoreAudio input device, or nil
    /// if no connected input matches. Empty UID resolves to nil (there is no device
    /// to resolve — the caller treats empty as "system default", not "unresolved").
    static func resolve(uid: String) -> AudioDevice? {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AudioDevice.byID(trimmed)
    }

    /// True iff a non-empty pinned UID resolves to a connected input device.
    static func canResolve(uid: String) -> Bool {
        resolve(uid: uid) != nil
    }

    // MARK: Per-engine application (no global mutation)

    /// Pin `device` as the input for a specific `AVAudioEngine` by setting its input
    /// node's audio unit device. Must be called BEFORE `engine.start()`. Does not
    /// touch the system default. Returns true on success.
    ///
    /// Mirrors WhisperKit's own `assignAudioInput`
    /// (`kAudioOutputUnitProperty_CurrentDevice`), routed through AudioUnit's
    /// higher-level `setDeviceID` so failures throw rather than returning an OSStatus.
    @discardableResult
    static func apply(_ device: AudioDevice, to engine: AVAudioEngine) -> Bool {
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(device.deviceID)
            return true
        } catch {
            NSLog("[AudioInputRouter] setDeviceID failed for '%@': %@",
                  device.name, error.localizedDescription)
            return false
        }
    }

    // MARK: System default (capture-and-restore)

    /// Address for the system default input device property.
    private static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// The current system default input device, or nil on error.
    static func currentDefaultInput() -> AudioDeviceID? {
        var address = defaultInputAddress()
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            UInt32(kAudioObjectSystemObject), &address, 0, nil, &size, &devID)
        return status == noErr ? devID : nil
    }

    /// Set the system default input device. Returns true on success.
    @discardableResult
    static func setDefaultInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = defaultInputAddress()
        var devID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            UInt32(kAudioObjectSystemObject), &address, 0, nil, size, &devID)
        return status == noErr
    }

    /// A live swap of the system default input device that remembers the previous
    /// default so it can be restored. Used by capture stacks that can only record
    /// the system default (AVAudioRecorder) or that own the mic through a dependency
    /// with no per-engine device seam (WhisperKit's AudioStreamTranscriber).
    ///
    /// `restore()` is idempotent and safe to call from any teardown/error path.
    final class DefaultInputOverride {
        private var previous: AudioDeviceID?
        private(set) var applied = false

        /// Switch the system default input to `device`, remembering the prior default.
        /// Returns true if the switch took effect. A no-op (returns false) if the
        /// selected device is ALREADY the default — nothing to restore later.
        @discardableResult
        func engage(_ device: AudioDevice) -> Bool {
            let prior = AudioInputRouter.currentDefaultInput()
            if prior == device.deviceID { return false }   // already default; leave it
            guard AudioInputRouter.setDefaultInput(device.deviceID) else { return false }
            previous = prior
            applied = true
            return true
        }

        /// Restore the previous system default input, if this override changed it.
        /// Idempotent: safe to call more than once and on paths where `engage`
        /// never ran or returned false.
        func restore() {
            guard applied, let previous else { return }
            AudioInputRouter.setDefaultInput(previous)
            self.previous = nil
            applied = false
        }
    }
}
