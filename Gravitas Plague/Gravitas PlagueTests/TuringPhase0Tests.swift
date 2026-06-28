import XCTest
@testable import Gravitas_Plague

final class TuringPhase0Tests: XCTestCase {
    func testTuringRuntimeConfigDecodesBundledJSON() throws {
        let config = try TuringResourceLoader.decodeResource(
            TuringRuntimeConfig.self,
            resourcePath: "Turing/Config/turing-runtime.json"
        )

        XCTAssertEqual(config.schemaVersion, 3)
        XCTAssertEqual(config.tts.modelID, "qwen3-tts-12hz-0.6b-base-8bit")
        XCTAssertFalse(config.tts.allowCPUFallback)
        XCTAssertTrue(config.tts.requireGPU)
        XCTAssertTrue(config.tts.phase0AudioOnly)
        XCTAssertEqual(config.tts.generationMode, "bareBaseSmoke")
        XCTAssertEqual(config.tts.voiceArgumentPolicy, .baseNilOnly)
        XCTAssertEqual(config.tts.refAudioPolicy, .phase0NilOnly)
        XCTAssertEqual(config.tts.refTextPolicy, .phase0NilOnly)
        XCTAssertEqual(config.tts.topP, 1.0)
        XCTAssertEqual(config.tts.repetitionPenalty, 1.0)
    }

    func testTuringModelRegistryPreservesPinnedRevision() async throws {
        let registry = try TuringModelRegistry()
        let model = try await registry.model(id: "qwen3-tts-12hz-0.6b-base-8bit")

        XCTAssertEqual(model.quantization, "8bit")
        XCTAssertEqual(model.modelType, "qwen3_tts")
        XCTAssertTrue(model.phase0RuntimeAllowed)
        XCTAssertTrue(model.requiresGPU)
        XCTAssertFalse(model.allowCPUFallback)
        XCTAssertEqual(
            model.modelRevision,
            "50f45ef0047cde7e84c2ef04326acb8ada2436a7"
        )
        XCTAssertEqual(
            model.tokenizerRevision,
            "50f45ef0047cde7e84c2ef04326acb8ada2436a7:speech_tokenizer"
        )
    }

    func testTuringVoiceRegistryFindsPhase0Voice() async throws {
        let registry = try TuringVoiceRegistry()
        let voice = try await registry.voice(id: "qwen_phase0_default")

        XCTAssertEqual(voice.kind, .library)
        XCTAssertNil(voice.resourcePath)
        XCTAssertNil(voice.qwenVoiceArgument)
        XCTAssertNil(voice.refAudioPath)
        XCTAssertNil(voice.refText)
        XCTAssertTrue(voice.phase0RuntimeAllowed)
    }

    func testBareBaseSmokeAcceptsNilVoiceNilReferenceInputs() throws {
        XCTAssertNoThrow(
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "base",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: nil,
                hasRefAudio: false,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: false
            )
        )
    }

    func testBareBaseSmokeRejectsRyanBeforeModelLoad() {
        XCTAssertThrowsPhase0ContractError(
            .voiceArgumentForbidden("Ryan")
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "base",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: "Ryan",
                hasRefAudio: false,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: false
            )
        }
    }

    func testBareBaseSmokeRejectsAidenBeforeModelLoad() {
        XCTAssertThrowsPhase0ContractError(
            .voiceArgumentForbidden("Aiden")
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "base",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: "Aiden",
                hasRefAudio: false,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: false
            )
        }
    }

    func testBareBaseSmokeRejectsReferenceTextBeforeModelLoad() {
        XCTAssertThrowsPhase0ContractError(
            .refTextForbidden("reference transcript")
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "base",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: nil,
                hasRefAudio: false,
                refText: "reference transcript",
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: false
            )
        }
    }

    func testBareBaseSmokeRejectsReferenceAudioBeforeModelLoad() {
        XCTAssertThrowsPhase0ContractError(
            .refAudioForbidden
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "base",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: nil,
                hasRefAudio: true,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: false
            )
        }
    }

    func testBareBaseSmokeRejectsCustomVoiceModelBeforeModelLoad() {
        XCTAssertThrowsPhase0ContractError(
            .invalidCheckpointKind("custom_voice")
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "custom_voice",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: nil,
                hasRefAudio: false,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: false
            )
        }
    }

    func testBareBaseSmokeRejectsVoiceDesignModelBeforeModelLoad() {
        XCTAssertThrowsPhase0ContractError(
            .invalidModelID("qwen3-tts-12hz-1.7b-voicedesign-bf16")
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-1.7b-voicedesign-bf16",
                checkpointKind: "voice_design",
                quantization: "bf16",
                generationMode: "bareBaseSmoke",
                voiceArgument: nil,
                hasRefAudio: false,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: false
            )
        }
    }

    func testBareBaseSmokeRejectsCPUFallbackEnabled() {
        XCTAssertThrowsPhase0ContractError(
            .cpuFallbackForbidden
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "base",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: nil,
                hasRefAudio: false,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: true,
                isMainActor: false
            )
        }
    }

    func testBareBaseSmokeRejectsMainActorGenerationFlag() {
        XCTAssertThrowsPhase0ContractError(
            .mainActorForbidden
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: "Hello from Qwen3-TTS."),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "base",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: nil,
                hasRefAudio: false,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: true
            )
        }
    }

    func testBareBaseSmokeRejectsEmptyText() {
        XCTAssertThrowsPhase0ContractError(
            .emptyText
        ) {
            try QwenPhase0GenerationContract.validateBeforeGenerate(
                request: QwenPhase0SmokeRequest(text: " "),
                modelID: "qwen3-tts-12hz-0.6b-base-8bit",
                checkpointKind: "base",
                quantization: "8bit",
                generationMode: "bareBaseSmoke",
                voiceArgument: nil,
                hasRefAudio: false,
                refText: nil,
                requireGPU: true,
                allowCPUFallback: false,
                isMainActor: false
            )
        }
    }

    func testTuringAudioCacheKeyChangesForIdentityFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = TuringAudioCache(rootURL: root)
        let segment = TuringSpeechSegment(text: "hello", emotion: "urgent")
        let voice = TuringVoiceDescriptor(
            id: "qwen_phase0_default",
            kind: .library,
            resourcePath: nil,
            qwenVoiceArgument: nil,
            refAudioPath: nil,
            refText: nil,
            phase0RuntimeAllowed: true,
            revision: "voice-a"
        )
        let settings = QwenGenerationSettings(
            language: "English",
            sampleRate: 24000,
            temperature: 0.7,
            topP: 1.0,
            repetitionPenalty: 1.0,
            maxTokens: 512,
            seed: nil
        )

        let baseHost = TestQwenHost(modelRevision: "model-a")
        let baseKey = try await cache.key(
            segment: segment,
            voice: voice,
            model: baseHost,
            settings: settings,
            radioTreatment: nil
        )

        let modelRevisionKey = try await cache.key(
            segment: segment,
            voice: voice,
            model: TestQwenHost(modelRevision: "model-b"),
            settings: settings,
            radioTreatment: nil
        )
        XCTAssertNotEqual(baseKey, modelRevisionKey)

        let voiceRevisionKey = try await cache.key(
            segment: segment,
            voice: TuringVoiceDescriptor(
                id: voice.id,
                kind: voice.kind,
                resourcePath: voice.resourcePath,
                qwenVoiceArgument: voice.qwenVoiceArgument,
                refAudioPath: voice.refAudioPath,
                refText: voice.refText,
                phase0RuntimeAllowed: voice.phase0RuntimeAllowed,
                revision: "voice-b"
            ),
            model: baseHost,
            settings: settings,
            radioTreatment: nil
        )
        XCTAssertNotEqual(baseKey, voiceRevisionKey)

        let textKey = try await cache.key(
            segment: TuringSpeechSegment(text: "hello again", emotion: "urgent"),
            voice: voice,
            model: baseHost,
            settings: settings,
            radioTreatment: nil
        )
        XCTAssertNotEqual(baseKey, textKey)

        let generationKey = try await cache.key(
            segment: segment,
            voice: voice,
            model: baseHost,
            settings: QwenGenerationSettings(
                language: "English",
                sampleRate: 24000,
                temperature: 0.9,
                topP: 0.9,
                maxTokens: 2048,
                seed: nil
            ),
            radioTreatment: nil
        )
        XCTAssertNotEqual(baseKey, generationKey)
    }

    func testSchedulerSerializesRendersAndCacheHitSkipsSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let host = TestQwenHost(modelRevision: "model-a")
        let scheduler = QwenTTSSequentialScheduler(
            host: host,
            cache: TuringAudioCache(rootURL: root),
            fileWriter: TuringAudioFileWriter(rootURL: root),
            settings: TestQwenHost.settings
        )
        let voice = TestQwenHost.voice

        async let first: TuringRenderedSegment = scheduler.render(
            segment: TuringSpeechSegment(text: "line one", emotion: "neutral"),
            segmentIndex: 0,
            voice: voice,
            radioTreatment: nil
        )
        async let second: TuringRenderedSegment = scheduler.render(
            segment: TuringSpeechSegment(text: "line two", emotion: "neutral"),
            segmentIndex: 1,
            voice: voice,
            radioTreatment: nil
        )

        _ = try await [first, second]

        XCTAssertEqual(await host.maxConcurrentSyntheses, 1)
        XCTAssertEqual(await host.sessionCreateCount, 2)

        _ = try await scheduler.render(
            segment: TuringSpeechSegment(text: "line one", emotion: "neutral"),
            segmentIndex: 2,
            voice: voice,
            radioTreatment: nil
        )

        XCTAssertEqual(await host.sessionCreateCount, 2)
    }

    func testSchedulerPhase0BareBaseSmokeUsesHostPathWithoutVoice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let host = TestQwenHost(modelRevision: "model-a")
        let scheduler = QwenTTSSequentialScheduler(
            host: host,
            cache: TuringAudioCache(rootURL: root),
            fileWriter: TuringAudioFileWriter(rootURL: root),
            settings: TestQwenHost.settings
        )
        let request = QwenPhase0SmokeRequest(
            text: "Hello from Qwen3-TTS."
        )

        _ = try await scheduler.renderPhase0BareBaseSmoke(
            request: request
        )

        XCTAssertEqual(await host.phase0GenerateCount, 1)
        XCTAssertEqual(await host.lastPhase0Request, request)

        _ = try await scheduler.renderPhase0BareBaseSmoke(
            request: request
        )

        XCTAssertEqual(await host.phase0GenerateCount, 1)
    }

    func testFailedSynthesisReleasesTransientState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let host = TestQwenHost(
            modelRevision: "model-a",
            shouldFailSynthesis: true
        )
        let scheduler = QwenTTSSequentialScheduler(
            host: host,
            cache: TuringAudioCache(rootURL: root),
            fileWriter: TuringAudioFileWriter(rootURL: root),
            settings: TestQwenHost.settings
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await scheduler.render(
                segment: TuringSpeechSegment(text: "line one", emotion: "neutral"),
                segmentIndex: 0,
                voice: TestQwenHost.voice,
                radioTreatment: nil
            )
        }

        XCTAssertEqual(await host.releaseCount, 1)
    }

    func testPacketizerSplitsAtSixAndSeven() {
        XCTAssertEqual(TuringPacketizer.packetize(Array(1...5)).count, 1)
        XCTAssertEqual(TuringPacketizer.packetize(Array(1...6)).map(\.count), [3, 3])
        XCTAssertEqual(TuringPacketizer.packetize(Array(1...7)).map(\.count), [4, 3])
    }

    func testJSONSanitizerAcceptsFencedObject() async throws {
        struct Payload: Decodable, Equatable {
            let value: String
        }

        let decoded = try await TuringJSONGate.decodeStrict(
            Payload.self,
            raw: """
            ```json
            {"value":"ok"}
            ```
            """
        )

        XCTAssertEqual(decoded, Payload(value: "ok"))
    }
}

private actor TestQwenHost: QwenTTSModelHost {
    let modelID = "qwen3-tts-12hz-0.6b-base-8bit"
    let modelRevision: String
    let quantization = "8bit"
    let tokenizerRevision = "tokenizer-a"

    private(set) var sessionCreateCount = 0
    private(set) var currentConcurrentSyntheses = 0
    private(set) var maxConcurrentSyntheses = 0
    private(set) var releaseCount = 0
    private(set) var phase0GenerateCount = 0
    private(set) var lastPhase0Request: QwenPhase0SmokeRequest?

    private let shouldFailSynthesis: Bool

    static let settings = QwenGenerationSettings(
        language: "English",
        sampleRate: 24000,
        temperature: 0.7,
        topP: 1.0,
        repetitionPenalty: 1.0,
        maxTokens: 512,
        seed: nil
    )

    static let voice = TuringVoiceDescriptor(
        id: "qwen_phase0_default",
        kind: .library,
        resourcePath: nil,
        qwenVoiceArgument: nil,
        refAudioPath: nil,
        refText: nil,
        phase0RuntimeAllowed: true,
        revision: "voice-a"
    )

    init(
        modelRevision: String,
        shouldFailSynthesis: Bool = false
    ) {
        self.modelRevision = modelRevision
        self.shouldFailSynthesis = shouldFailSynthesis
    }

    func loadIfNeeded() async throws {}

    func assertGPUAvailable() async throws {}

    func generatePhase0BareBaseSmoke(
        _ request: QwenPhase0SmokeRequest
    ) async throws -> QwenWaveform {
        try beginSynthesis()
        phase0GenerateCount += 1
        lastPhase0Request = request
        try await Task.sleep(nanoseconds: 10_000_000)
        endSynthesis()

        return QwenWaveform(
            samples: Array(repeating: 0.05, count: 240),
            sampleRate: 24000,
            channelCount: 1
        )
    }

    func makeSession() async throws -> QwenTTSSynthesisSession {
        sessionCreateCount += 1
        return TestQwenSession(host: self)
    }

    func beginSynthesis() throws {
        if shouldFailSynthesis {
            throw TuringRuntimeError.qwenSynthesisFailed("test failure")
        }

        currentConcurrentSyntheses += 1
        maxConcurrentSyntheses = max(
            maxConcurrentSyntheses,
            currentConcurrentSyntheses
        )
    }

    func endSynthesis() {
        currentConcurrentSyntheses -= 1
    }

    func recordRelease() {
        releaseCount += 1
    }
}

private struct TestQwenSession: QwenTTSSynthesisSession {
    let host: TestQwenHost

    func synthesize(
        text: String,
        emotion: String,
        voice: TuringVoiceDescriptor,
        settings: QwenGenerationSettings
    ) async throws -> QwenWaveform {
        _ = (text, emotion, voice, settings)
        try await host.beginSynthesis()
        try await Task.sleep(nanoseconds: 10_000_000)
        await host.endSynthesis()

        return QwenWaveform(
            samples: Array(repeating: 0.05, count: 240),
            sampleRate: 24000,
            channelCount: 1
        )
    }

    func releaseTransientState() async {
        await host.recordRelease()
    }
}

private func XCTAssertThrowsPhase0ContractError(
    _ expected: QwenPhase0GenerationContract.ContractError,
    _ expression: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        try expression()
        XCTFail("Expected Phase 0 contract error.", file: file, line: line)
    } catch let error as QwenPhase0GenerationContract.ContractError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error).", file: file, line: line)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown.", file: file, line: line)
    } catch {
        // Expected.
    }
}
