import Foundation

actor TuringTransientAudioFileStore {
    struct StoredFile: Sendable, Hashable {
        let id: String
        let fileURL: URL
        let metadataURL: URL
        let durationSeconds: TimeInterval
        let sampleRate: Int
        let channelCount: Int
    }

    private let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TuringTransientAudio", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func cleanupAll(reason: String) async {
        do {
            if fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.removeItem(at: rootURL)
            }
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            print(
                """
                [TuringTTS] transient audio cleanup completed
                  reason: \(reason)
                  root: \(rootURL.path)
                """
            )
        } catch {
            print(
                """
                [TuringTTS] transient audio cleanup failed
                  reason: \(reason)
                  error: \(error.localizedDescription)
                """
            )
        }
    }

    func write(
        waveform: QwenWaveform,
        purpose: String,
        segmentIndex: Int,
        writer: TuringAudioFileWriter
    ) async throws -> StoredFile {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let renderID = "\(purpose)-segment-\(segmentIndex)-\(UUID().uuidString)"
        let fileURL = rootURL
            .appendingPathComponent(renderID, isDirectory: false)
            .appendingPathExtension("wav")

        let written = try await writer.write(
            waveform: waveform,
            explicitFileURL: fileURL
        )

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableWAVURL = written.fileURL
        var mutableMetadataURL = written.metadataURL
        try? mutableWAVURL.setResourceValues(resourceValues)
        try? mutableMetadataURL.setResourceValues(resourceValues)

        print(
            """
            [TuringTTS] transient Qwen audio written
              renderID: \(renderID)
              file: \(written.fileURL.lastPathComponent)
              persistentCache: false
            """
        )

        return StoredFile(
            id: renderID,
            fileURL: written.fileURL,
            metadataURL: written.metadataURL,
            durationSeconds: written.durationSeconds,
            sampleRate: written.sampleRate,
            channelCount: written.channelCount
        )
    }

    func delete(
        _ file: StoredFile,
        reason: String
    ) async {
        do {
            if fileManager.fileExists(atPath: file.fileURL.path) {
                try fileManager.removeItem(at: file.fileURL)
            }
            if fileManager.fileExists(atPath: file.metadataURL.path) {
                try fileManager.removeItem(at: file.metadataURL)
            }
            print(
                """
                [TuringTTS] transient Qwen audio deleted
                  renderID: \(file.id)
                  reason: \(reason)
                """
            )
        } catch {
            print(
                """
                [TuringTTS] transient Qwen audio delete failed
                  renderID: \(file.id)
                  reason: \(reason)
                  error: \(error.localizedDescription)
                """
            )
        }
    }

    func delete(
        renderedSegment: TuringRenderedSegment,
        reason: String
    ) async {
        let metadataURL = renderedSegment.fileURL
            .deletingPathExtension()
            .appendingPathExtension("json")
        await delete(
            StoredFile(
                id: renderedSegment.renderID,
                fileURL: renderedSegment.fileURL,
                metadataURL: metadataURL,
                durationSeconds: renderedSegment.durationSeconds,
                sampleRate: renderedSegment.sampleRate,
                channelCount: renderedSegment.channelCount
            ),
            reason: reason
        )
    }
}
