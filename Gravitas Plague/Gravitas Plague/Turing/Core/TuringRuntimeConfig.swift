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
        let phase0AudioOnly: Bool
        let targetSegmentSecondsMin: Double
        let targetSegmentSecondsMax: Double
        let maxSegmentsBeforeSplit: Int
        let requireGPU: Bool
        let allowCPUFallback: Bool
        let language: String
        let sampleRate: Int
        let temperature: Double
        let topP: Double
        let repetitionPenalty: Double
        let maxTokens: Int
        let voiceArgumentPolicy: VoiceArgumentPolicy
        let refAudioPolicy: RefAudioPolicy
        let refTextPolicy: RefTextPolicy

        enum VoiceArgumentPolicy: String, Codable, Sendable {
            case baseNilOnly
        }

        enum RefAudioPolicy: String, Codable, Sendable {
            case phase0NilOnly
        }

        enum RefTextPolicy: String, Codable, Sendable {
            case phase0NilOnly
        }

        enum CodingKeys: String, CodingKey {
            case modelID
            case synthesisMode
            case phase0AudioOnly
            case targetSegmentSecondsMin
            case targetSegmentSecondsMax
            case maxSegmentsBeforeSplit
            case requireGPU
            case allowCPUFallback
            case language
            case sampleRate
            case temperature
            case topP
            case repetitionPenalty
            case maxTokens
            case voiceArgumentPolicy
            case refAudioPolicy
            case refTextPolicy
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            modelID = try container.decode(String.self, forKey: .modelID)
            synthesisMode = try container.decode(String.self, forKey: .synthesisMode)
            phase0AudioOnly = try container.decodeIfPresent(Bool.self, forKey: .phase0AudioOnly) ?? false
            targetSegmentSecondsMin = try container.decodeIfPresent(Double.self, forKey: .targetSegmentSecondsMin) ?? 3.0
            targetSegmentSecondsMax = try container.decodeIfPresent(Double.self, forKey: .targetSegmentSecondsMax) ?? 5.0
            maxSegmentsBeforeSplit = try container.decodeIfPresent(Int.self, forKey: .maxSegmentsBeforeSplit) ?? 5
            requireGPU = try container.decode(Bool.self, forKey: .requireGPU)
            allowCPUFallback = try container.decode(Bool.self, forKey: .allowCPUFallback)
            language = try container.decode(String.self, forKey: .language)
            sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 24_000
            temperature = try container.decode(Double.self, forKey: .temperature)
            topP = try container.decode(Double.self, forKey: .topP)
            repetitionPenalty = try container.decodeIfPresent(Double.self, forKey: .repetitionPenalty) ?? 1.0
            maxTokens = try container.decode(Int.self, forKey: .maxTokens)
            voiceArgumentPolicy = try container.decodeIfPresent(
                VoiceArgumentPolicy.self,
                forKey: .voiceArgumentPolicy
            ) ?? .baseNilOnly
            refAudioPolicy = try container.decodeIfPresent(
                RefAudioPolicy.self,
                forKey: .refAudioPolicy
            ) ?? .phase0NilOnly
            refTextPolicy = try container.decodeIfPresent(
                RefTextPolicy.self,
                forKey: .refTextPolicy
            ) ?? .phase0NilOnly
        }
    }

    struct DebugConfig: Codable, Sendable, Equatable {
        let enableMemoryMetrics: Bool
        let soakTestIterations: Int
        let maxPostWarmupGrowthMB: Int
        let phase0SmokeText: String

        enum CodingKeys: String, CodingKey {
            case enableMemoryMetrics
            case soakTestIterations
            case maxPostWarmupGrowthMB
            case phase0SmokeText
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enableMemoryMetrics = try container.decode(Bool.self, forKey: .enableMemoryMetrics)
            soakTestIterations = try container.decode(Int.self, forKey: .soakTestIterations)
            maxPostWarmupGrowthMB = try container.decodeIfPresent(Int.self, forKey: .maxPostWarmupGrowthMB) ?? 300
            phase0SmokeText = try container.decodeIfPresent(String.self, forKey: .phase0SmokeText)
                ?? "Turing Phase Zero is generating this line locally through Qwen and MLX."
        }
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
