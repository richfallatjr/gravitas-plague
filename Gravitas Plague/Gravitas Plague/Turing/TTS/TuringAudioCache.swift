import CryptoKit
import Foundation

actor TuringAudioCache {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func phase0BareBaseSmokeKey(
        request: QwenPhase0SmokeRequest,
        model: QwenTTSModelHost,
        sampleRate: Int
    ) throws -> String {
        let payload = TuringPhase0BareBaseSmokeCacheIdentity(
            schemaVersion: 1,
            generationMode: QwenPhase0GenerationContract.requiredGenerationMode,
            modelID: model.modelID,
            modelRevision: model.modelRevision,
            quantization: model.quantization,
            tokenizerRevision: model.tokenizerRevision,
            text: request.text,
            language: request.language,
            sampleRate: sampleRate,
            temperature: Double(request.temperature),
            topP: Double(request.topP),
            repetitionPenalty: Double(request.repetitionPenalty),
            maxTokens: request.maxTokens
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func key(
        segment: TuringSpeechSegment,
        voice: TuringVoiceDescriptor,
        model: QwenTTSModelHost,
        settings: QwenGenerationSettings,
        radioTreatment: TuringRadioEffectProfile?
    ) throws -> String {
        let payload = TuringAudioCacheIdentity(
            schemaVersion: 1,
            modelID: model.modelID,
            modelRevision: model.modelRevision,
            quantization: model.quantization,
            tokenizerRevision: model.tokenizerRevision,
            voiceID: voice.id,
            voiceRevision: voice.revision,
            text: segment.text,
            emotion: segment.emotion,
            language: settings.language,
            sampleRate: settings.sampleRate,
            temperature: settings.temperature,
            topP: settings.topP,
            repetitionPenalty: settings.repetitionPenalty,
            maxTokens: settings.maxTokens,
            seed: settings.seed,
            radioTreatmentID: radioTreatment?.id,
            radioTreatmentRevision: radioTreatment?.revision
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func lookup(key: String) throws -> TuringAudioCacheFile? {
        let wavURL = rootURL.appendingPathComponent("\(key).wav")
        let metadataURL = rootURL.appendingPathComponent("\(key).json")

        guard FileManager.default.fileExists(atPath: wavURL.path),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata: TuringAudioFileMetadata

        do {
            metadata = try decoder.decode(
                TuringAudioFileMetadata.self,
                from: data
            )
        } catch {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: metadataURL)

            print(
                """
                [TuringTTS] purged invalid audio cache entry
                  key: \(key)
                  wav: \(wavURL.path)
                  metadata: \(metadataURL.path)
                  error: \(error.localizedDescription)
                  regenerate: true
                """
            )

            return nil
        }

        return TuringAudioCacheFile(
            fileURL: wavURL,
            metadataURL: metadataURL,
            durationSeconds: metadata.durationSeconds,
            sampleRate: metadata.sampleRate,
            channelCount: metadata.channelCount
        )
    }

    func store(
        file: TuringAudioCacheFile,
        key: String
    ) async throws {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            throw TuringRuntimeError.audioCacheFailed(
                "Rendered file missing for key \(key)."
            )
        }
    }
}

struct TuringAudioCacheIdentity: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let modelID: String
    let modelRevision: String
    let quantization: String
    let tokenizerRevision: String
    let voiceID: String
    let voiceRevision: String?
    let text: String
    let emotion: String
    let language: String
    let sampleRate: Int
    let temperature: Double
    let topP: Double
    let repetitionPenalty: Double
    let maxTokens: Int
    let seed: UInt64?
    let radioTreatmentID: String?
    let radioTreatmentRevision: String?
}

struct TuringPhase0BareBaseSmokeCacheIdentity: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let generationMode: String
    let modelID: String
    let modelRevision: String
    let quantization: String
    let tokenizerRevision: String
    let text: String
    let language: String
    let sampleRate: Int
    let temperature: Double
    let topP: Double
    let repetitionPenalty: Double
    let maxTokens: Int
}
