@preconcurrency import RealityKit
import Foundation

nonisolated final class TuringPreparedRealityAudioResource: @unchecked Sendable {
    let resource: AudioFileResource
    let fileURL: URL
    let shouldLoop: Bool

    init(
        resource: AudioFileResource,
        fileURL: URL,
        shouldLoop: Bool
    ) {
        self.resource = resource
        self.fileURL = fileURL
        self.shouldLoop = shouldLoop
    }
}

actor TuringRealityAudioResourceLoader {
    static let shared = TuringRealityAudioResourceLoader()

    struct Key: Hashable, Sendable {
        let fileURL: URL
        let shouldLoop: Bool
    }

    private var bundledCache: [Key: TuringPreparedRealityAudioResource] = [:]
    private var transientCache: [Key: TuringPreparedRealityAudioResource] = [:]

    func load(
        fileURL: URL,
        shouldLoop: Bool,
        cachePolicy: TuringAudioResourceCachePolicy
    ) async throws -> TuringPreparedRealityAudioResource {
        TuringAudioOffloadSignposts.assertNotMainThread(
            "AudioFileResource.asyncPrepare"
        )
        TuringAudioOffloadSignposts.offMain(
            "AudioFileResource.asyncPrepare",
            file: fileURL.lastPathComponent
        )
        let key = Key(fileURL: fileURL, shouldLoop: shouldLoop)
        switch cachePolicy {
        case .bundled:
            if let existing = bundledCache[key] { return existing }
        case .transient:
            if let existing = transientCache[key] { return existing }
        case .none:
            break
        }

        let resource = try await AudioFileResource(
            contentsOf: fileURL,
            configuration: .init(
                loadingStrategy: .preload,
                shouldLoop: shouldLoop
            )
        )
        let prepared = TuringPreparedRealityAudioResource(
            resource: resource,
            fileURL: fileURL,
            shouldLoop: shouldLoop
        )
        switch cachePolicy {
        case .bundled:
            bundledCache[key] = prepared
        case .transient:
            transientCache[key] = prepared
        case .none:
            break
        }
        return prepared
    }

    func evictTransient(fileURL: URL) {
        transientCache = transientCache.filter { $0.key.fileURL != fileURL }
    }

    func clearTransient() {
        transientCache.removeAll(keepingCapacity: false)
    }

    func clearAll() {
        transientCache.removeAll(keepingCapacity: false)
        bundledCache.removeAll(keepingCapacity: false)
    }
}
