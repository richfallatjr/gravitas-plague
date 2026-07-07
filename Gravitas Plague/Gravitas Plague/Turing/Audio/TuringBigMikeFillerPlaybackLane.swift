import AVFoundation
import Foundation

@MainActor
final class TuringBigMikeFillerPlaybackLane: NSObject, AVAudioPlayerDelegate {
    private let fillerDirectoryCandidates: [String]
    private let fillerExtensions: Set<String>
    private let avoidImmediateRepeat: Bool
    private var fillerFiles: [URL] = []
    private var fillerQueue: [URL] = []
    private var lastFillerFile: URL?
    private(set) var activeFillerPlayer: AVAudioPlayer?
    var onFillerFinished: (@MainActor () -> Void)?

    var isPlaying: Bool {
        activeFillerPlayer?.isPlaying == true
    }

    init(
        fillerDirectoryCandidates: [String] = [
            "Turing/Audio/big-mike-filler",
            "Turing/big-mike-filler",
            "big-mike-filler"
        ],
        fillerExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "caf"],
        avoidImmediateRepeat: Bool = true
    ) {
        self.fillerDirectoryCandidates = fillerDirectoryCandidates
        self.fillerExtensions = fillerExtensions
        self.avoidImmediateRepeat = avoidImmediateRepeat
        super.init()
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: fillerDirectoryCandidates,
            allowedExtensions: fillerExtensions
        )
        rebuildQueue()

        print("""
        [TuringWAVQueue] filler lane initialized
          uniqueClipCount: \(Set(fillerFiles).count)
          weightedEntryCount: \(fillerFiles.count)
          source: big-mike-filler
        """)
    }

    func startFiller(reason: String) throws {
        guard isPlaying == false else { return }
        guard let file = nextFillerFile() else {
            print("""
            [TuringWAVQueue] filler unavailable
              reason: \(reason)
            """)
            Task { @MainActor [weak self] in
                self?.onFillerFinished?()
            }
            return
        }

        let player = try AVAudioPlayer(contentsOf: file)
        player.delegate = self
        player.prepareToPlay()
        activeFillerPlayer = player
        lastFillerFile = file

        print("""
        [TuringWAVQueue] filler started
          reason: \(reason)
          file: \(file.lastPathComponent)
          nonInterruptible: true
        """)

        if player.play() == false {
            activeFillerPlayer = nil
            throw TuringGeneratedWAVError.playbackFailed(
                "AVAudioPlayer.play returned false for filler \(file.lastPathComponent)"
            )
        }
    }

    func stopFiller(reason: String) {
        guard let activeFillerPlayer else { return }
        activeFillerPlayer.stop()
        self.activeFillerPlayer = nil

        print("""
        [TuringWAVQueue] filler stopped
          reason: \(reason)
        """)
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            self.activeFillerPlayer = nil
            print("""
            [TuringWAVQueue] filler finished
              successfully: \(flag)
            """)
            self.onFillerFinished?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        Task { @MainActor in
            self.activeFillerPlayer = nil
            print("""
            [TuringWAVQueue] filler decode error
              error: \(error?.localizedDescription ?? "unknown")
            """)
            self.onFillerFinished?()
        }
    }

    private func nextFillerFile() -> URL? {
        if fillerQueue.isEmpty {
            rebuildQueue()
        }
        guard fillerQueue.isEmpty == false else { return nil }
        return fillerQueue.removeFirst()
    }

    private func rebuildQueue() {
        fillerQueue = fillerFiles.shuffled()
        if avoidImmediateRepeat,
           fillerQueue.count > 1,
           let lastFillerFile,
           fillerQueue.first == lastFillerFile {
            fillerQueue.append(fillerQueue.removeFirst())
        }
    }

    private static func discoverFillerFiles(
        candidates: [String],
        allowedExtensions: Set<String>
    ) -> [URL] {
        var weighted: [URL] = []

        for candidate in candidates {
            guard let directory = Bundle.main.url(
                forResource: candidate,
                withExtension: nil
            ) else {
                continue
            }

            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard allowedExtensions.contains(file.pathExtension.lowercased()) else {
                    continue
                }
                weighted.append(
                    contentsOf: Array(
                        repeating: file,
                        count: fillerWeight(for: file)
                    )
                )
            }
        }

        return weighted
    }

    private static func fillerWeight(for file: URL) -> Int {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let raw = stem.split(separator: "_").last,
              let parsed = Int(raw) else {
            return 1
        }
        return min(max(parsed, 1), 10)
    }
}
