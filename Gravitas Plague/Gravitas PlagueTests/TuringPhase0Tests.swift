import XCTest
@testable import Gravitas_Plague

final class TuringPhase0Tests: XCTestCase {
    func testTuringRuntimeConfigDecodesBundledJSON() throws {
        let config = try TuringResourceLoader.decodeResource(
            TuringRuntimeConfig.self,
            resourcePath: "Turing/Config/turing-runtime.json"
        )

        XCTAssertEqual(config.schemaVersion, 1)
        XCTAssertEqual(config.tts.modelID, "qwen3-tts-12hz-1.7b-base-4bit")
        XCTAssertFalse(config.tts.allowCPUFallback)
        XCTAssertTrue(config.tts.requireGPU)
    }

    func testTuringModelRegistryPreservesPinnedRevision() async throws {
        let registry = try TuringModelRegistry()
        let model = try await registry.model(id: "qwen3-tts-12hz-1.7b-base-4bit")

        XCTAssertEqual(model.quantization, "4bit")
        XCTAssertEqual(
            model.modelRevision,
            "37e955a1deb861c088ae5f3a67043185f3d1a60c"
        )
        XCTAssertEqual(
            model.tokenizerRevision,
            "37e955a1deb861c088ae5f3a67043185f3d1a60c:speech_tokenizer"
        )
    }

    func testTuringVoiceRegistryFindsPhase0Voice() async throws {
        let registry = try TuringVoiceRegistry()
        let voice = try await registry.voice(id: "phase0_ryan_dev")

        XCTAssertEqual(voice.kind, .library)
        XCTAssertEqual(voice.resourcePath, "qwen-preset:Ryan")
    }

    func testTuringAudioCacheKeyChangesForIdentityFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = TuringAudioCache(rootURL: root)
        let segment = TuringSpeechSegment(text: "hello", emotion: "urgent")
        let voice = TuringVoiceDescriptor(
            id: "phase0_ryan_dev",
            kind: .library,
            resourcePath: "qwen-preset:Ryan",
            revision: "voice-a"
        )
        let settings = QwenGenerationSettings(
            language: "English",
            sampleRate: 24000,
            temperature: 0.7,
            topP: 0.95,
            maxTokens: 4096,
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
    let modelID = "qwen3-tts-12hz-1.7b-base-4bit"
    let modelRevision: String
    let quantization = "4bit"
    let tokenizerRevision = "tokenizer-a"

    private(set) var sessionCreateCount = 0
    private(set) var currentConcurrentSyntheses = 0
    private(set) var maxConcurrentSyntheses = 0
    private(set) var releaseCount = 0

    private let shouldFailSynthesis: Bool

    static let settings = QwenGenerationSettings(
        language: "English",
        sampleRate: 24000,
        temperature: 0.7,
        topP: 0.95,
        maxTokens: 4096,
        seed: nil
    )

    static let voice = TuringVoiceDescriptor(
        id: "phase0_ryan_dev",
        kind: .library,
        resourcePath: "qwen-preset:Ryan",
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
