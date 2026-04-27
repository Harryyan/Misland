import AppKit
import MioMiniCore

/// Plays a stock macOS system sound on key state transitions. We use NSSound
/// rather than bundling .wav assets so v1 ships with no audio files. The
/// trade-off: less stylized than 8-bit chiptune, but zero asset weight and
/// 100% reliability.
public enum SoundEvent: String, CaseIterable, Sendable {
    case sessionStart
    case approvalNeeded
    case approvalGranted
    case approvalDenied
    case sessionComplete

    public var label: String {
        switch self {
        case .sessionStart:     return "Session start"
        case .approvalNeeded:   return "Approval needed"
        case .approvalGranted:  return "Approval granted"
        case .approvalDenied:   return "Approval denied"
        case .sessionComplete:  return "Session complete"
        }
    }

    /// Stock macOS system sound. See `/System/Library/Sounds/`.
    public var systemSoundName: String {
        switch self {
        case .sessionStart:     return "Tink"
        case .approvalNeeded:   return "Funk"
        case .approvalGranted:  return "Glass"
        case .approvalDenied:   return "Basso"
        case .sessionComplete:  return "Hero"
        }
    }
}

@MainActor
public final class SoundPlayer: ObservableObject {
    public static let shared = SoundPlayer()

    public func play(_ event: SoundEvent) {
        NSSound(named: NSSound.Name(event.systemSoundName))?.play()
    }
}
