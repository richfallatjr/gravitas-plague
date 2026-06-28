import Foundation

struct TuringRuntimeConfig: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let foundation: FoundationConfig
    let tts: TTSConfig
    let debug: DebugConfig

    struct FoundationConfig: Codable, Sendable, Equatable {
        let maxParallelRequests: Int
        let maxChunkTokens: Int
        let aggregateBudgetTokens: Int
        let perChunkMetadataOverheadCharacters: Int
    }

    struct TTSConfig: Codable, Sendable, Equatable {
        let modelID: String
        let synthesisMode: String
        let targetSegmentSecondsMin: Double
        let targetSegmentSecondsMax: Double
        let maxSegmentsBeforeSplit: Int
        let requireGPU: Bool
        let allowCPUFallback: Bool
        let language: String
        let sampleRate: Int
        let temperature: Double
        let topP: Double
        let maxTokens: Int
    }

    struct DebugConfig: Codable, Sendable, Equatable {
        let enableMemoryMetrics: Bool
        let soakTestIterations: Int
        let maxPostWarmupGrowthMB: Int
    }
}

enum TuringResourceLoader {
    nonisolated static func decodeResource<T: Decodable>(
        _ type: T.Type,
        resourcePath: String,
        bundle: Bundle = .main
    ) throws -> T {
        let url = try resourceURL(
            resourcePath: resourcePath,
            bundle: bundle
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated static func resourceURL(
        resourcePath: String,
        bundle: Bundle = .main
    ) throws -> URL {
        let parts = resourcePath.split(separator: "/").map(String.init)
        guard let name = parts.last else {
            throw TuringRuntimeError.resourceMissing(resourcePath)
        }

        let directory = parts.dropLast().joined(separator: "/")
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        if ext.isEmpty {
            guard let url = bundle.url(
                forResource: name,
                withExtension: nil,
                subdirectory: directory
            ) else {
                throw TuringRuntimeError.resourceMissing(resourcePath)
            }
            return url
        }

        guard let url = bundle.url(
            forResource: stem,
            withExtension: ext,
            subdirectory: directory
        ) else {
            throw TuringRuntimeError.resourceMissing(resourcePath)
        }
        return url
    }
}
