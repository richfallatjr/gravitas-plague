import AVFoundation
import Foundation

enum Chapter01MusicCue: String, Codable, Sendable, CaseIterable, Hashable {
    case dadWindow
    case robotAttack
}

struct Chapter01MusicCatalog: Codable, Sendable {
    struct Cue: Codable, Sendable {
        let cueID: Chapter01MusicCue
        let resourcePath: String
        let gainDB: Float
        let loops: Bool
        let fadeInSeconds: Double
        let fadeOutSeconds: Double
    }

    let schemaVersion: Int
    let cues: [Cue]

    func descriptor(for cue: Chapter01MusicCue) -> Cue? {
        cues.first { $0.cueID == cue }
    }

    func validate() throws {
        guard schemaVersion == 1,
              cues.count == Chapter01MusicCue.allCases.count,
              Set(cues.map(\.cueID)) == Set(Chapter01MusicCue.allCases),
              cues.allSatisfy({
                  !$0.resourcePath.isEmpty &&
                      $0.gainDB <= 0 &&
                      $0.fadeInSeconds >= 0 &&
                      $0.fadeOutSeconds >= 0
              }) else {
            throw Chapter01RobotError.invalidDefinition("invalid Chapter 01 music catalog")
        }
        for cue in cues {
            _ = try TuringResourceLoader.resourceURL(resourcePath: cue.resourcePath)
        }
    }

    static func load() throws -> Self {
        let value = try TuringResourceLoader.decodeResource(
            Self.self,
            resourcePath: "Turing/Story/Chapter01/chapter01.music.json"
        )
        try value.validate()
        return value
    }
}

actor Chapter01MusicController {
    private struct ActiveCue: Sendable {
        let cueID: Chapter01MusicCue
        let chapterRunID: UUID
        let fadeOutSeconds: Double
    }

    static let shared = Chapter01MusicController()

    private var catalog: Chapter01MusicCatalog?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var activeCue: ActiveCue?

    func prepare(catalog: Chapter01MusicCatalog) {
        self.catalog = catalog
    }

    func play(
        _ cueID: Chapter01MusicCue,
        chapterRunID: UUID
    ) async throws {
        if activeCue?.cueID == cueID,
           activeCue?.chapterRunID == chapterRunID {
            return
        }
        let catalog = try self.catalog ?? Chapter01MusicCatalog.load()
        self.catalog = catalog
        guard let cue = catalog.descriptor(for: cueID) else {
            throw Chapter01RobotError.invalidDefinition("missing Chapter 01 music cue \(cueID.rawValue)")
        }
        await releaseActive(reason: "replacedBy.\(cueID.rawValue)")

        let url = try TuringResourceLoader.resourceURL(resourcePath: cue.resourcePath)
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        let targetGain = Self.linearGain(decibels: cue.gainDB)
        queue.volume = cue.fadeInSeconds > 0 ? 0 : targetGain
        if cue.loops {
            looper = AVPlayerLooper(player: queue, templateItem: item)
        } else {
            queue.insert(item, after: nil)
        }
        player = queue
        activeCue = ActiveCue(
            cueID: cueID,
            chapterRunID: chapterRunID,
            fadeOutSeconds: cue.fadeOutSeconds
        )
        queue.play()
        await fade(
            chapterRunID: chapterRunID,
            cueID: cueID,
            from: queue.volume,
            to: targetGain,
            duration: cue.fadeInSeconds
        )
        print("[Chapter01Music] started cue=\(cueID.rawValue) file=\(url.lastPathComponent) gainDB=\(cue.gainDB) loops=\(cue.loops)")
    }

    func stop(
        _ cueID: Chapter01MusicCue,
        chapterRunID: UUID,
        reason: String
    ) async {
        guard activeCue?.cueID == cueID,
              activeCue?.chapterRunID == chapterRunID else {
            return
        }
        await releaseActive(reason: reason)
    }

    func stopAll(chapterRunID: UUID, reason: String) async {
        guard activeCue?.chapterRunID == chapterRunID else { return }
        await releaseActive(reason: reason)
    }

    private func releaseActive(reason: String) async {
        guard let activeCue else { return }
        await fade(
            chapterRunID: activeCue.chapterRunID,
            cueID: activeCue.cueID,
            from: player?.volume ?? 0,
            to: 0,
            duration: activeCue.fadeOutSeconds
        )
        guard self.activeCue?.chapterRunID == activeCue.chapterRunID,
              self.activeCue?.cueID == activeCue.cueID else {
            return
        }
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
        self.activeCue = nil
        print("[Chapter01Music] stopped cue=\(activeCue.cueID.rawValue) reason=\(reason)")
    }

    private func fade(
        chapterRunID: UUID,
        cueID: Chapter01MusicCue,
        from start: Float,
        to target: Float,
        duration: Double
    ) async {
        guard duration > 0 else {
            player?.volume = target
            return
        }
        let frameCount = max(1, Int(ceil(duration * 30)))
        for frame in 1...frameCount {
            guard activeCue?.chapterRunID == chapterRunID,
                  activeCue?.cueID == cueID else {
                return
            }
            let progress = Float(frame) / Float(frameCount)
            player?.volume = start + ((target - start) * progress)
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    private nonisolated static func linearGain(decibels: Float) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}
