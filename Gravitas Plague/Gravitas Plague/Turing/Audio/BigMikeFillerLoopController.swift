import Foundation
import AVFoundation

/// Starter latency-bridge filler loop for Big Mike.
///
/// Purpose:
/// - Play short preauthored filler clips only while Qwen is late between generated segments.
/// - Stop immediately/fade when real speech is ready.
/// - Do not replace story dialogue.
/// - Do not cache generated speech.
///
/// This first pass uses AVAudioPlayer directly so the compute-ahead stall behavior can be proven
/// without touching the Qwen runtime. Production can swap this sink to GravitasDemoAudioController
/// spatial playback after the policy is validated.
@MainActor
final class BigMikeFillerLoopController: NSObject, AVAudioPlayerDelegate {
    enum State: String {
        case idle
        case playing
        case stopping
    }

    struct Configuration: Sendable {
        var bundleSubdirectories: [String] = [
            "Turing/Audio/big-mike-filler",
            "Turing/big-mike-filler",
            "big-mike-filler"
        ]
        var allowedExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "caf"]
        var fadeOutSeconds: TimeInterval = 0.20
        var maxContinuousSeconds: TimeInterval = 12.0
        var maxConsecutiveClips: Int = 2
        var volume: Float = 0.85
        var avoidImmediateRepeat: Bool = true
    }

    private let configuration: Configuration
    private var clips: [URL] = []
    private var player: AVAudioPlayer?
    private var state: State = .idle
    private var currentRunID = UUID()
    private var lastClipURL: URL?
    private var loopStartedAt: Date?
    private var clipsPlayedInCurrentRun = 0

    override init() {
        self.configuration = Configuration()
        super.init()
        self.clips = Self.discoverClips(configuration: configuration)
        print("""
        [BigMikeFiller] initialized
          clipCount: \(clips.count)
          subdirectories: \(configuration.bundleSubdirectories.joined(separator: ", "))
        """)
    }

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
        self.clips = Self.discoverClips(configuration: configuration)
        print("""
        [BigMikeFiller] initialized
          clipCount: \(clips.count)
          subdirectories: \(configuration.bundleSubdirectories.joined(separator: ", "))
        """)
    }

    var isAvailable: Bool { clips.isEmpty == false }
    var currentState: State { state }

    func reloadClips() {
        clips = Self.discoverClips(configuration: configuration)
        print("""
        [BigMikeFiller] clips reloaded
          clipCount: \(clips.count)
        """)
    }

    /// Start random filler if it is not already playing.
    func start(reason: String) {
        guard state == .idle else {
            print("""
            [BigMikeFiller] start ignored
              reason: \(reason)
              state: \(state.rawValue)
            """)
            return
        }

        guard clips.isEmpty == false else {
            print("""
            [BigMikeFiller] unavailable
              reason: \(reason)
              clipCount: 0
            """)
            return
        }

        currentRunID = UUID()
        loopStartedAt = Date()
        clipsPlayedInCurrentRun = 0
        state = .playing

        print("""
        [BigMikeFiller] loop started
          reason: \(reason)
          clipCount: \(clips.count)
          maxContinuousSeconds: \(configuration.maxContinuousSeconds)
          maxConsecutiveClips: \(configuration.maxConsecutiveClips)
        """)

        playNextClip(runID: currentRunID)
    }

    /// Stop filler because real Qwen speech is ready.
    func stopForRealSpeech(reason: String) {
        guard state == .playing else {
            state = .idle
            player?.stop()
            player = nil
            return
        }

        state = .stopping
        let runID = currentRunID
        let fade = max(0.0, configuration.fadeOutSeconds)

        print("""
        [BigMikeFiller] stopping for real speech
          reason: \(reason)
          fadeOutSeconds: \(fade)
        """)

        guard let player else {
            finishStop(runID: runID)
            return
        }

        if fade <= 0.0 {
            player.stop()
            finishStop(runID: runID)
            return
        }

        Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            let steps = 8
            let startingVolume = player.volume
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64((fade / Double(steps)) * 1_000_000_000))
                guard self.currentRunID == runID else { return }
                player.volume = startingVolume * Float(steps - step) / Float(steps)
            }
            player.stop()
            self.finishStop(runID: runID)
        }
    }

    func stopImmediately(reason: String) {
        print("""
        [BigMikeFiller] stopped immediately
          reason: \(reason)
        """)
        currentRunID = UUID()
        state = .idle
        player?.stop()
        player = nil
        loopStartedAt = nil
        clipsPlayedInCurrentRun = 0
    }

    private func finishStop(runID: UUID) {
        guard currentRunID == runID else { return }
        state = .idle
        player = nil
        loopStartedAt = nil
        clipsPlayedInCurrentRun = 0
        print("[BigMikeFiller] loop stopped")
    }

    private func playNextClip(runID: UUID) {
        guard currentRunID == runID, state == .playing else { return }

        if shouldStopBecauseBudgetExpired() {
            print("""
            [BigMikeFiller] loop budget expired
              clipsPlayed: \(clipsPlayedInCurrentRun)
            """)
            stopImmediately(reason: "budgetExpired")
            return
        }

        guard let clip = chooseRandomClip() else {
            stopImmediately(reason: "noClipAvailable")
            return
        }

        do {
            let next = try AVAudioPlayer(contentsOf: clip)
            next.delegate = self
            next.numberOfLoops = 0
            next.volume = configuration.volume
            next.prepareToPlay()
            player = next
            lastClipURL = clip
            clipsPlayedInCurrentRun += 1
            next.play()

            print("""
            [BigMikeFiller] clip started
              clip: \(clip.lastPathComponent)
              indexInRun: \(clipsPlayedInCurrentRun)
            """)
        } catch {
            print("""
            [BigMikeFiller] clip failed
              clip: \(clip.lastPathComponent)
              error: \(error.localizedDescription)
            """)
            stopImmediately(reason: "clipPlaybackFailed")
        }
    }

    private func chooseRandomClip() -> URL? {
        guard clips.isEmpty == false else { return nil }
        guard configuration.avoidImmediateRepeat, clips.count > 1, let lastClipURL else {
            return clips.randomElement()
        }
        let candidates = clips.filter { $0 != lastClipURL }
        return candidates.randomElement() ?? clips.randomElement()
    }

    private func shouldStopBecauseBudgetExpired() -> Bool {
        if configuration.maxConsecutiveClips > 0,
           clipsPlayedInCurrentRun >= configuration.maxConsecutiveClips {
            return true
        }
        if let loopStartedAt,
           Date().timeIntervalSince(loopStartedAt) >= configuration.maxContinuousSeconds {
            return true
        }
        return false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.player === player else { return }
            print("""
            [BigMikeFiller] clip finished
              successful: \(flag)
            """)
            self.playNextClip(runID: self.currentRunID)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            print("""
            [BigMikeFiller] decode error
              error: \(error?.localizedDescription ?? "unknown")
            """)
            self.stopImmediately(reason: "decodeError")
        }
    }

    private static func discoverClips(configuration: Configuration) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []

        for subdir in configuration.bundleSubdirectories {
            for ext in configuration.allowedExtensions {
                if let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: subdir) {
                    found.append(contentsOf: urls)
                }
            }
        }

        if found.isEmpty, let resourceURL = Bundle.main.resourceURL {
            if let enumerator = fm.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    guard url.pathComponents.contains("big-mike-filler") else { continue }
                    guard configuration.allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    found.append(url)
                }
            }
        }

        return Array(Set(found)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Minimal bridge that starts filler when a gap opens between generated segments and stops it
/// as soon as the next real segment is ready.
@MainActor
final class BigMikeSegmentGapFillerBridge {
    private let loop: BigMikeFillerLoopController
    private var enabled = true

    init() {
        self.loop = BigMikeFillerLoopController()
    }

    init(loop: BigMikeFillerLoopController) {
        self.loop = loop
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled == false {
            loop.stopImmediately(reason: "disabled")
        }
    }

    func segmentEndedWaitingForNext(segmentIndex: Int) {
        guard enabled else { return }
        loop.start(reason: "segmentEndedWaitingForNext.segment\(segmentIndex)")
    }

    func nextRealSegmentReady(segmentIndex: Int) {
        guard enabled else { return }
        loop.stopForRealSpeech(reason: "nextRealSegmentReady.segment\(segmentIndex)")
    }

    func playbackStopped(reason: String) {
        loop.stopImmediately(reason: reason)
    }
}
