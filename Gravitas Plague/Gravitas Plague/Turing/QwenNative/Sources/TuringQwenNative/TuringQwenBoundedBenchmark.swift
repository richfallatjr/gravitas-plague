import Foundation
import CryptoKit
import MLX

public enum TuringQwenJSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), array([Self]), object([String: Self]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode([Self].self) { self = .array(x) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .object(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
}

public struct TuringQwenBoundedBenchmarkReport: Codable, Sendable {
    public let schemaVersion: Int
    public let runID: String
    public let status: String
    public let outcome: String
    public let failure: String?
    public let workload: TuringQwenPerformanceWorkload
    public let workloadSHA256: String
    public let policy: TuringQwenNativeExecutionPolicy
    public let policySHA256: String
    public let buildManifest: [String: TuringQwenJSONValue]?
    public let compiledFingerprint: TuringMLXBuildFingerprint
    public let binaryUUIDs: [String]
    public let runtimeContract: [String: TuringQwenJSONValue]
    public let observation: [String: TuringQwenJSONValue]
    public let identitySHA256: [String: String]
    public let installedPayloadSHA256: [String: String]
    public let coldLoadSeconds: Double
    public let renderWallSeconds: Double
    public let loadInclusiveWallSeconds: Double
    public let rawAudioSeconds: Double
    public let rawAudioRTF: Double?
    public let pcm: [TuringQwenPerformancePCMRecord]
    public let orderedPCMReady: [Double?]
    public let firstNeededPCMSeconds: Double?
    public let scheduler: TuringQwenNativeFreshInstanceRunReport?
    public let observedOwnershipAfterLoad: TuringQwenNativeResidencyOwnershipReport?
    public let commandBuffers: TuringQwenNativeCommandBufferRunMetrics
    public let decoderIOCounters: TuringQwenNativeSafetensorsIOCounters?
    public let sampledPeakFootprintMiB: Double
    public let residualFootprintMiB: Double
    public let residualMLXActiveBytes: Int
    public let residualMLXCacheBytes: Int
    public let unavailable: [String: String]
}

public enum TuringQwenBoundedBenchmark {
    public enum Mode: String, Sendable { case boundedReplay = "bounded-replay", decoderFixedCodes = "decoder-fixed-codes" }
    public struct Options: Sendable {
        public let modelRoot: URL
        public let bundleRoot: URL
        public let workload: TuringQwenPerformanceWorkload
        public let mode: Mode
        public let commandBufferProfile: TuringQwenNativeCommandBufferProfile
        public let profilerState: String
        public let sceneCondition: String
        public let policy: TuringQwenNativeExecutionPolicy
        public init(modelRoot: URL, bundleRoot: URL, workload: TuringQwenPerformanceWorkload,
                    mode: Mode = .boundedReplay,
                    commandBufferProfile: TuringQwenNativeCommandBufferProfile = .deviceDefault,
                    profilerState: String = "unknown", sceneCondition: String = "isolated-host-no-scene",
                    policy: TuringQwenNativeExecutionPolicy = .production) {
            self.modelRoot = modelRoot; self.bundleRoot = bundleRoot; self.workload = workload
            self.mode = mode; self.commandBufferProfile = commandBufferProfile
            self.profilerState = profilerState; self.sceneCondition = sceneCondition; self.policy = policy
        }
    }

    private struct RuntimeCatalog: Decodable {
        let characters: [Character]
        struct Character: Decodable {
            let characterID: String
            let voiceID: String
            let cloneProfileResourcePath: String
            let qwen: Qwen
        }
        struct Qwen: Decodable {
            let maxNewRows: Int
            let useExactReferenceRowCount: Bool
            let referenceWindowStrategy: String
            let decoding: TuringQwenNativeSamplingPolicy
            let qualityGate: TuringQwenNativeGenerationQualityPolicy
        }
    }

    public static func run(options: Options) async throws -> TuringQwenBoundedBenchmarkReport {
        try options.workload.validate(decoderOnly: options.mode == .decoderFixedCodes)
        try options.policy.validateImplemented()
        try configureCommandBuffers(options.commandBufferProfile)
        let configURL = options.bundleRoot.appendingPathComponent("Turing/Config/character-runtimes.json")
        let catalog = try JSONDecoder().decode(RuntimeCatalog.self, from: Data(contentsOf: configURL))
        guard let runtime = catalog.characters.first(where: {
            $0.characterID == options.workload.characterID && $0.voiceID == options.workload.voiceID
        }), options.workload.maximumRowsPerSegment <= runtime.qwen.maxNewRows else {
            throw TuringQwenNativeError.invalidConfig("Workload does not match an actual production voice/row policy")
        }
        try runtime.qwen.decoding.validate()
        guard TuringQwenNativeReferenceWindowStrategy(rawValue: runtime.qwen.referenceWindowStrategy) != nil,
              runtime.qwen.useExactReferenceRowCount else {
            throw TuringQwenNativeError.invalidConfig("Unsupported production reference policy")
        }
        let profile = try TuringQwenNativeCloneProfileLoader().loadBaseCloneProfile(
            from: options.bundleRoot, profileResourcePath: runtime.cloneProfileResourcePath,
            expectedVoiceID: runtime.voiceID, expectedCharacterID: runtime.characterID, logPrefix: "Bounded qualification")
        let variant = try profile.requireVariant(profile.defaultVariantID)
        // Hash outside the measured interval. This is identity work, not TTS cost.
        var identity: [String: String] = [:]
        for (key, url) in [
            ("model", options.modelRoot.appendingPathComponent("model.safetensors")),
            ("modelConfig", options.modelRoot.appendingPathComponent("config.json")),
            ("tokenizerVocab", options.modelRoot.appendingPathComponent("vocab.json")),
            ("tokenizerMerges", options.modelRoot.appendingPathComponent("merges.txt")),
            ("tokenizerConfig", options.modelRoot.appendingPathComponent("tokenizer_config.json")),
            ("decoder", options.modelRoot.appendingPathComponent("speech_tokenizer/model.safetensors")),
            ("decoderConfig", options.modelRoot.appendingPathComponent("speech_tokenizer/config.json")),
            ("characterRuntimes", configURL), ("referenceCodes", variant.referenceCodesURL),
            ("referenceTextTokens", variant.referenceTextTokensURL), ("speakerEmbedding", variant.speakerEmbeddingURL),
            ("voiceMetadata", profile.rootURL.appendingPathComponent("metadata.json")),
            ("voiceVariant", variant.manifestURL), ("referenceAudio", variant.normalizedReferenceAudioURL)
        ] { identity[key] = try hashFile(url) }
        identity["tokenizer"] = SHA256.hash(data: Data([
            identity["tokenizerVocab"]!, identity["tokenizerMerges"]!, identity["tokenizerConfig"]!
        ].joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
        let installedPayload = ["models": try hashDirectory(options.modelRoot),
                                "voices": try hashDirectory(options.bundleRoot.appendingPathComponent("Turing/Voices/Cloned"))]
        let manifest = try Bundle.main.url(forResource: "qwen-build-manifest", withExtension: "json")
            .map { try JSONDecoder().decode([String: TuringQwenJSONValue].self, from: Data(contentsOf: $0)) }
        let budget = try TuringQwenPerformanceBudget(wallSeconds: options.workload.wallCapSeconds,
                                                   maximumFootprintMiB: options.workload.footprintCapMiB)
        return try await TuringQwenNativeExecutionPolicy.$current.withValue(options.policy) {
            try await TuringQwenPerformanceBudget.$current.withValue(budget) {
                try await execute(options: options, runtime: runtime, profile: profile,
                                  identity: identity, installedPayload: installedPayload, manifest: manifest)
            }
        }
    }

    private static func execute(options: Options, runtime: RuntimeCatalog.Character,
                                profile: TuringQwenNativeCloneProfile, identity: [String: String],
                                installedPayload: [String: String],
                                manifest: [String: TuringQwenJSONValue]?) async throws -> TuringQwenBoundedBenchmarkReport {
        let id = "bounded-\(UUID().uuidString)"
        let start = ContinuousClock.now
        let collector = Collector()
        let thermalAtStart = ProcessInfo.processInfo.thermalState.rawValue
        let initialFootprint = TuringQwenNativeProcessMemoryProbe.snapshot().physFootprintMB
        let capture = TuringQwenNativeCommandBufferRunCapture()
        var pool: TuringQwenNativeFreshInstancePool?
        var schedulerReport: TuringQwenNativeFreshInstanceRunReport?
        var observedOwnership: TuringQwenNativeResidencyOwnershipReport?
        var renderStart = start
        var loadSeconds = 0.0
        var failure: String?
        var decoderIOCounters: TuringQwenNativeSafetensorsIOCounters?
        let sampler = Task {
            while !Task.isCancelled {
                await collector.sampleMemory()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        do {
            try TuringQwenPerformanceBudget.check()
            if options.mode == .decoderFixedCodes {
                // Fixed-code replay is explicitly isolated, not a Fresh2 throughput comparison.
                let decoder = try TuringQwenNativeSpeechDecoderSession(modelRoot: options.modelRoot)
                loadSeconds = seconds(start.duration(to: .now))
                renderStart = .now
                let codes = options.workload.decoderCodes!
                let full = try decoder.decode(rows: codes, performanceMode: .performance)
                decoderIOCounters = decoder.ioCounters()
                let trimmed = try TuringQwenNativeBaseCloneDecodeTrimmer.trimReferencePrefix(
                    from: full.samples, referenceRowCount: options.workload.decoderReferenceRows!, totalRowCount: codes.count)
                try await collector.record(index: 0, seconds: seconds(renderStart.duration(to: .now)),
                                           audio: .init(samples: trimmed, sampleRate: full.sampleRate))
            } else {
                let owner = try TuringQwenNativeGenerationSchedulerFactory.makeFresh2Pool(recoveryRunID: id)
                pool = owner
                try await owner.warmLoadExactlyRequestedInstances(modelRoot: options.modelRoot,
                    cloneProfile: profile, variantID: profile.defaultVariantID, performanceMode: .performance)
                observedOwnership = try await owner.residencyOwnershipReport()
                try TuringQwenPerformanceBudget.check()
                loadSeconds = seconds(start.duration(to: .now))
                renderStart = .now
                let fixedStart = renderStart
                let scheduler = TuringQwenNativeGenerationSchedulerFactory.makeFresh2Scheduler(
                    instancePool: owner, gpuAdmissionPolicy: try .currentProduction,
                    commandBufferProfile: options.commandBufferProfile)
                let requests = options.workload.segments.enumerated().map { index, text in
                    TuringQwenNativeBaseCloneSegmentRequest(segmentIndex: index, text: text,
                        language: options.workload.language, cloneProfile: profile,
                        maxNewRows: options.workload.maximumRowsPerSegment, performanceMode: .performance,
                        referenceRowLimit: nil, referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy(rawValue: runtime.qwen.referenceWindowStrategy)!,
                        samplingPolicy: runtime.qwen.decoding,
                        samplingSeed: options.workload.samplingSeed &+ UInt64(index),
                        generationQualityPolicy: runtime.qwen.qualityGate)
                }
                schedulerReport = try await scheduler.runSegments(requests, runID: id, modelRoot: options.modelRoot,
                    skipSegmentFailures: false, onSegmentStarted: { _,_ in },
                    onSegmentDecoded: { decoded in
                        try await collector.record(index: decoded.segmentIndex,
                            seconds: seconds(fixedStart.duration(to: .now)), audio: decoded.audio)
                    })
            }
            try TuringQwenPerformanceBudget.check()
        } catch { failure = String(describing: error) }
        let renderEnd = ContinuousClock.now
        // Native owner teardown is authoritative; never clear shared state behind it.
        if let pool { await pool.unloadAll(reason: "boundedQualificationFinished") }
        await collector.sampleMemory()
        sampler.cancel()
        await sampler.value
        let snapshot = await collector.snapshot()
        let count = options.mode == .decoderFixedCodes ? 1 : options.workload.segments.count
        let ordered = try TuringQwenPerformanceReadiness.ordered(snapshot.records, count: count)
        let renderWall = seconds(renderStart.duration(to: renderEnd))
        let rawAudio = snapshot.records.reduce(0) { $0 + Double($1.sampleCount) / Double($1.sampleRate) }
        let memory = Memory.snapshot()
        let commandBuffers = capture.finish(profile: options.commandBufferProfile, admissionMode: .currentOverlap)
        let resolved = try TuringMetalDiagnostics.configuration()
        let policyJSON = try JSONDecoder().decode(TuringQwenJSONValue.self, from: JSONEncoder().encode(options.policy))
        #if GR_TURING_METAL_RECOVERY_QUALIFICATION
        let recoveryDefines = ["GR_TURING_METAL_RECOVERY_QUALIFICATION"]
        #elseif GR_TURING_METAL_STREAM_RECOVERY
        let recoveryDefines = ["GR_TURING_METAL_STREAM_RECOVERY"]
        #else
        let recoveryDefines: [String] = []
        #endif
        return TuringQwenBoundedBenchmarkReport(schemaVersion: 1, runID: id,
            status: "DEVICE_QUALIFICATION_PENDING", outcome: failure == nil ? "SCOUT_COMPLETED" : "FAILED_OR_BUDGET_STOPPED",
            failure: failure, workload: options.workload, workloadSHA256: try options.workload.fingerprint,
            policy: options.policy, policySHA256: options.policy.fingerprint, buildManifest: manifest,
            compiledFingerprint: try TuringMLXBuildFingerprint.current, binaryUUIDs: TuringMLXBinaryIdentity.current,
            runtimeContract: ["residencyMode": .string(options.mode == .decoderFixedCodes ? "isolatedDecoder" : "independentFresh2"),
                "laneCount": .number(options.mode == .decoderFixedCodes ? 0 : 2),
                "weightStoreCount": .number(options.mode == .decoderFixedCodes ? 0 : 2), "decoderCount": .number(1),
                "admissionPolicy": .string("currentOverlap"), "requestedCommandBufferProfile": .string(options.commandBufferProfile.rawValue),
                "resolvedCommandBufferProfile": .object(["maximumOperations": .number(Double(resolved.maximumOperationsPerBuffer)),
                    "maximumMegabytes": .number(Double(resolved.maximumMegabytesPerBuffer))]),
                "executionPolicy": policyJSON, "seedPolicy": .string("fixture seed + segment index"),
                "recoveryDefines": .array(recoveryDefines.map { .string($0) }),
                "policySHA256": .string(options.policy.fingerprint), "playbackRateApplied": .bool(false)],
            observation: ["runID": .string(id), "clockBasis": .string("ContinuousClock"),
                "osBuild": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                "deviceModel": .string(deviceModel()), "profilerState": .string(options.profilerState),
                "sceneCondition": .string(options.sceneCondition), "coldWarmDefinition": .string("fresh engine; filesystem/driver warmth uncontrolled"),
                "initialThermalState": .number(Double(thermalAtStart)),
                "finalThermalState": .number(Double(ProcessInfo.processInfo.thermalState.rawValue)),
                "initialMemoryBytes": .number(initialFootprint * 1_048_576)],
            identitySHA256: identity, installedPayloadSHA256: installedPayload,
            coldLoadSeconds: loadSeconds, renderWallSeconds: renderWall,
            loadInclusiveWallSeconds: seconds(start.duration(to: renderEnd)), rawAudioSeconds: rawAudio,
            rawAudioRTF: rawAudio > 0 && failure == nil ? renderWall / rawAudio : nil,
            pcm: snapshot.records, orderedPCMReady: ordered, firstNeededPCMSeconds: ordered.first ?? nil,
            scheduler: schedulerReport, observedOwnershipAfterLoad: observedOwnership,
            commandBuffers: commandBuffers, decoderIOCounters: decoderIOCounters,
            sampledPeakFootprintMiB: snapshot.peakFootprint, residualFootprintMiB: TuringQwenNativeProcessMemoryProbe.snapshot().physFootprintMB,
            residualMLXActiveBytes: memory.activeMemory, residualMLXCacheBytes: memory.cacheMemory,
            unavailable: ["promotion": "A bounded scout is not five-voice/device qualification; external provenance and quality gates required",
                "fixedWork": "Prompt replay has a fixed maximum row budget, not forced identical output tokens; compare row/sample work before claiming arithmetic speedup",
                "sceneFrameTiming": "No scene timing source attached to this runner", "audibleStart": "PCM-only observer; no player is replaced",
                "GPUAttribution": "Command-buffer interval sums are not kernel ownership or GPU utilization", "energy": "Not measured",
                "quality": "Short row-capped scout is not a voice/content acceptance test"])
    }

    private actor Collector {
        var records: [TuringQwenPerformancePCMRecord] = []
        var peakFootprint: Double = 0
        func sampleMemory() { peakFootprint = max(peakFootprint, TuringQwenNativeProcessMemoryProbe.snapshot().physFootprintMB) }
        func record(index: Int, seconds: Double, audio: TuringQwenNativeAudio) throws {
            guard !audio.samples.isEmpty, audio.samples.allSatisfy(\.isFinite), audio.sampleRate > 0 else {
                throw TuringQwenNativeError.invalidConfig("Invalid/nonfinite qualification PCM")
            }
            let digest = audio.samples.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
            records.append(.init(segmentIndex: index, readySeconds: seconds, sampleCount: audio.samples.count,
                                 sampleRate: audio.sampleRate, pcmSHA256: digest))
            sampleMemory()
        }
        func snapshot() -> (records: [TuringQwenPerformancePCMRecord], peakFootprint: Double) { (records, peakFootprint) }
    }

    private static func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        // FileHandle's Foundation buffers can be autoreleased. Bound each
        // chunk's lifetime instead of retaining gigabytes until task return.
        while try autoreleasepool(invoking: {
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Same canonical inventory as qwen_build_provenance.py; performed before timing.
    private static func hashDirectory(_ root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw TuringQwenNativeError.invalidConfig("Cannot enumerate installed payload: \(root.path)")
        }
        var files: [String: TuringQwenPayloadInventory.Entry] = [:]
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".cache" { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if attributes.isRegularFile == true {
                let path = String(url.path.dropFirst(root.path.count + 1))
                files[path] = .init(bytes: attributes.fileSize ?? 0, sha256: try hashFile(url))
            }
        }
        guard !files.isEmpty else { throw TuringQwenNativeError.invalidConfig("Empty installed payload") }
        return TuringQwenPayloadInventory.fingerprint(files)
    }
    private static func configureCommandBuffers(_ profile: TuringQwenNativeCommandBufferProfile) throws {
        if !TuringMetalDiagnostics.deviceIsInitialized {
            if let count = profile.configuredOperations { setenv("MLX_MAX_OPS_PER_BUFFER", String(count), 1) }
            else { unsetenv("MLX_MAX_OPS_PER_BUFFER") }
            if let count = profile.configuredMegabytes { setenv("MLX_MAX_MB_PER_BUFFER", String(count), 1) }
            else { unsetenv("MLX_MAX_MB_PER_BUFFER") }
            // Configuration is published by the first real MLX device use.
            // Reading it here would fail before device initialization.
            return
        }
        let actual = try TuringMetalDiagnostics.configuration()
        guard (profile.configuredOperations == nil || profile.configuredOperations == actual.maximumOperationsPerBuffer),
              (profile.configuredMegabytes == nil || profile.configuredMegabytes == actual.maximumMegabytesPerBuffer) else {
            throw TuringQwenNativeError.invalidConfig("Already-initialized Metal device has a different buffer profile; launch a fresh process")
        }
    }
    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}
