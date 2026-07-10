import AVFoundation
import Foundation

@MainActor
final class TuringAudioSessionCoordinator {
    static let shared = TuringAudioSessionCoordinator()

    private var recordingOwners = Set<String>()
    private var playbackOwners = Set<String>()
    private var lastAppliedCategoryRawValue: String?

    private init() {}

    func configureForLaunch() {
        print("""
        [TuringAudioSession] launch policy passive
          playbackMutatesSession: false
          systemCapturePreserved: true
        """)
    }

    func beginRecording(owner: String) {
        let inserted = recordingOwners.insert(owner).inserted
        guard inserted else { return }

        if recordingOwners.count == 1 {
            applyRecordingPolicy(reason: "beginRecording.\(owner)")
        } else {
            logOwnerChange(reason: "beginRecording.\(owner)")
        }
    }

    func endRecording(owner: String) {
        recordingOwners.remove(owner)
        print("""
        [TuringAudioSession] recording owner ended
          reason: endRecording.\(owner)
          sessionMutation: false
          recordingOwners: \(recordingOwners.sorted().joined(separator: ","))
          playbackOwners: \(playbackOwners.sorted().joined(separator: ","))
        """)
    }

    func beginPlayback(owner: String) {
        playbackOwners.insert(owner)
        logOwnerChange(reason: "beginPlayback.\(owner)")
    }

    func endPlayback(owner: String) {
        playbackOwners.remove(owner)
        logOwnerChange(reason: "endPlayback.\(owner)")
    }

    private func logOwnerChange(reason: String) {
        print("""
        [TuringAudioSession] owner state changed
          reason: \(reason)
          sessionMutation: false
          recordingOwners: \(recordingOwners.sorted().joined(separator: ","))
          playbackOwners: \(playbackOwners.sorted().joined(separator: ","))
        """)
    }

    private func applyRecordingPolicy(reason: String) {
#if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        let category: AVAudioSession.Category = .playAndRecord
        let options: AVAudioSession.CategoryOptions = [
            .mixWithOthers,
            .allowBluetooth,
            .defaultToSpeaker,
        ]

        do {
            let categoryChanged = session.category != category || session.mode != .default
            if categoryChanged {
                try session.setCategory(
                    category,
                    mode: .default,
                    options: options
                )
            }
            try session.setActive(true)
            lastAppliedCategoryRawValue = category.rawValue

            print("""
            [TuringAudioSession] recording configured
              reason: \(reason)
              category: \(category.rawValue)
              categoryChanged: \(categoryChanged)
              playbackMutatesSession: false
              recordingOwners: \(recordingOwners.sorted().joined(separator: ","))
              playbackOwners: \(playbackOwners.sorted().joined(separator: ","))
            """)
        } catch {
            print("""
            [TuringAudioSession] configure failed
              reason: \(reason)
              requestedCategory: \(category.rawValue)
              currentCategory: \(session.category.rawValue)
              lastAppliedCategory: \(lastAppliedCategoryRawValue ?? "nil")
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
