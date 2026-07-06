import AVFoundation
import Foundation

@MainActor
final class TuringAudioSessionCoordinator {
    static let shared = TuringAudioSessionCoordinator()

    private var recordingOwners = Set<String>()
    private var playbackOwners = Set<String>()
    private var lastAppliedCategory: AVAudioSession.Category?

    private init() {}

    func configureForLaunch() {
        applyPolicy(reason: "launch")
    }

    func beginRecording(owner: String) {
        recordingOwners.insert(owner)
        applyPolicy(reason: "beginRecording.\(owner)")
    }

    func endRecording(owner: String) {
        recordingOwners.remove(owner)
        applyPolicy(reason: "endRecording.\(owner)")
    }

    func beginPlayback(owner: String) {
        playbackOwners.insert(owner)
        applyPolicy(reason: "beginPlayback.\(owner)")
    }

    func endPlayback(owner: String) {
        playbackOwners.remove(owner)
        applyPolicy(reason: "endPlayback.\(owner)")
    }

    private func applyPolicy(reason: String) {
#if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        let hasRecordingOwner = recordingOwners.isEmpty == false
        let category: AVAudioSession.Category = hasRecordingOwner
            ? .playAndRecord
            : .ambient
        let options: AVAudioSession.CategoryOptions = hasRecordingOwner
            ? [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
            : [.mixWithOthers]

        do {
            try session.setCategory(
                category,
                mode: .default,
                options: options
            )
            try session.setActive(true)
            lastAppliedCategory = category

            print("""
            [TuringAudioSession] configured
              reason: \(reason)
              category: \(category.rawValue)
              recordingOwners: \(recordingOwners.sorted().joined(separator: ","))
              playbackOwners: \(playbackOwners.sorted().joined(separator: ","))
            """)
        } catch {
            print("""
            [TuringAudioSession] configure failed
              reason: \(reason)
              requestedCategory: \(category.rawValue)
              currentCategory: \(session.category.rawValue)
              lastAppliedCategory: \(lastAppliedCategory?.rawValue ?? "nil")
              error: \(error.localizedDescription)
            """)
        }
#else
        print("""
        [TuringAudioSession] configure skipped
          reason: \(reason)
          platform: nonAVAudioSession
        """)
#endif
    }
}
