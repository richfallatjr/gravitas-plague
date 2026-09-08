import Foundation

public enum TuringQwenBenchmarkMeasurementStatus:
    String,
    Codable,
    Sendable
{
    case measured
    case unavailable
    case notApplicable
}

/// A benchmark value whose provenance is explicit. The custom encoder always
/// writes `value`, including JSON `null` when the runtime cannot measure it.
public struct TuringQwenBenchmarkMeasurement<Value>:
    Codable,
    Sendable
where Value: Codable & Sendable {
    public let status: TuringQwenBenchmarkMeasurementStatus
    public let value: Value?
    public let detail: String?

    public init(
        status: TuringQwenBenchmarkMeasurementStatus,
        value: Value?,
        detail: String? = nil
    ) {
        self.status = status
        self.value = value
        self.detail = detail
    }

    public static func measured(_ value: Value, detail: String? = nil) -> Self {
        Self(status: .measured, value: value, detail: detail)
    }

    public static func unavailable(_ detail: String) -> Self {
        Self(status: .unavailable, value: nil, detail: detail)
    }

    public static func notApplicable(_ detail: String) -> Self {
        Self(status: .notApplicable, value: nil, detail: detail)
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case value
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(
            TuringQwenBenchmarkMeasurementStatus.self,
            forKey: .status
        )
        value = try container.decodeIfPresent(Value.self, forKey: .value)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        if let value {
            try container.encode(value, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
        try container.encodeIfPresent(detail, forKey: .detail)
    }
}

public enum TuringQwenBenchmarkSuite: String, Codable, Sendable {
    case quick
    case full
}

public enum TuringQwenBenchmarkTier: String, Codable, Sendable, CaseIterable {
    case short
    case medium
    case long
    case multiMinute
}

public struct TuringQwenBenchmarkCase: Codable, Sendable {
    public let id: String
    public let tier: TuringQwenBenchmarkTier
    public let segments: [String]

    public init(id: String, tier: TuringQwenBenchmarkTier, segments: [String]) {
        self.id = id
        self.tier = tier
        self.segments = segments
    }

    public var text: String {
        segments.joined(separator: " ")
    }

    public var wordCount: Int {
        text.split(whereSeparator: \Character.isWhitespace).count
    }

    public var digest: String {
        TuringQwenBenchmarkDigest.string(text)
    }
}

public enum TuringQwenOptimizationBenchmarkCorpus {
    /// The locked Phase 0 corpus: 10 short, 10 medium, 10 long, and three
    /// multi-minute scripts. Long inputs are explicitly segmented so the
    /// benchmark uses the production 160-row safety cap per segment rather
    /// than silently increasing it.
    public static let full: [TuringQwenBenchmarkCase] = {
        let shortTexts = [
            "Big Mike, confirm the road is clear.",
            "Hold position and listen for the signal.",
            "The generator is stable for now.",
            "Keep the door closed until dawn.",
            "Radio check. Can you hear me?",
            "Move the supplies behind the bench.",
            "The northern fence is still standing.",
            "Wait for my count, then move.",
            "No lights. Stay low and quiet.",
            "We made it through another night."
        ]

        let mediumTexts = [
            "The storm passed over the county line, but the roads are still washed out. Check the radio, count the batteries, and tell me what we can carry before the next warning arrives.",
            "I heard the aircraft circle twice before it disappeared beyond the ridge. Nobody opens that door until we know whether the engines return or the valley goes quiet again.",
            "The fence held during the first push, and the west brace only moved an inch. Bring the spare timber over, keep watch, and do not waste a single nail.",
            "We have enough fuel for one more full night if the temperature stays down. Run the lights only when needed and leave the receiver powered for emergency traffic.",
            "That broadcast repeated the same coordinates three times. Write them beside the map, verify the numbers, and wait for a second station before anyone commits to the route.",
            "The house sounds different when the wind stops. Listen for footsteps near the porch, watch the windows, and call out anything that does not belong to the building.",
            "I moved the medicine into the dry cabinet and marked every bottle. Count it again after supper so we know exactly what remains before the next supply run.",
            "There is smoke beyond the southern trees, but I cannot see a flame. Keep the hose ready, clear the path, and stay inside unless the alarm changes.",
            "The morning report says the bridge is open for light traffic. We still wait for visual confirmation, because one bad crossing would cost more than a day of delay.",
            "If the receiver comes alive, let the whole message finish before answering. Note the speaker, the time, and every place name, then read the notes back slowly."
        ]

        let longOpenings = [
            "Before sunrise, the first county crew reached the eastern checkpoint and found the warning lights dark.",
            "All night, the old receiver carried fragments of weather reports from stations that should have been silent.",
            "We inventoried the workbench twice and found that the missing tools had been returned in a different order.",
            "The aircraft appeared shortly after noon, moving low enough for us to hear each change in engine pitch.",
            "A narrow line of smoke followed the river and settled under the trees where the road bends north.",
            "The fence inspection began at the porch and continued clockwise through every repaired section of wire.",
            "At dusk, the emergency channel opened with a voice reading numbers against a wash of static.",
            "The supply plan depends on three vehicles, two safe roads, and one narrow window before the weather turns.",
            "Nobody expected the power to return, so the sudden hum from the shed stopped every conversation in the room.",
            "The final watch started quietly, with clear skies above the ridge and no movement near the tree line."
        ]
        let longContinuationSentences = [
            "The team documented each observation, compared it with the previous shift, and separated confirmed facts from guesses.",
            "Every radio call was logged with its time and direction.",
            "Nothing moved until two people agreed on the route, the fallback point, and the signal that would bring everyone home.",
            "By the end of the check, the equipment was staged, the entrances were secure, and the next watch understood the plan.",
            "We left enough margin for a delayed message or a blocked road, because the safest schedule is the one that can survive a surprise without forcing a rushed decision."
        ]

        let multiIntroductions = [
            "This is the complete overnight operations report from Big Mike.",
            "Record the following county readiness briefing from beginning to end.",
            "The next transmission is a detailed account for the morning relief crew."
        ]
        let multiParagraphSentences = [
            [
                "We began at the north fence, checking every post, brace, hinge, and patch against yesterday's notes.",
                "The ground was soft after the rain, but none of the anchors had pulled free.",
                "We marked two places for reinforcement and left the gate secured."
            ],
            [
                "At the workbench, we counted the hand tools, batteries, medical kits, water filters, and radio parts.",
                "Each item went back to its labeled position so a person working in darkness could find it without searching or moving unrelated supplies."
            ],
            [
                "The first radio sweep produced static on the emergency band and a weak carrier farther east.",
                "We listened through the full cycle, wrote down the times, and did not answer because there was no verified call sign or actionable message."
            ],
            [
                "Outside, visibility improved as the cloud layer lifted above the ridge.",
                "We checked the road with binoculars, watched the tree line for movement, and compared the scene with photographs from the previous afternoon before declaring the approach unchanged."
            ],
            [
                "Power use remained inside the planned limit.",
                "The generator carried refrigeration and communications while unnecessary lighting stayed off.",
                "Fuel measurements matched the estimate, leaving a reserve for a delayed pickup, a cold night, or an emergency medical load."
            ],
            [
                "Before changing watch, we repeated every open task aloud.",
                "The incoming team confirmed the fence repairs, radio schedule, weather threshold, supply count, and evacuation route.",
                "Nobody relied on memory alone, and every uncertainty remained clearly labeled as unresolved."
            ]
        ]

        let shorts = shortTexts.enumerated().map { index, text in
            TuringQwenBenchmarkCase(
                id: String(format: "short-%02d", index + 1),
                tier: .short,
                segments: [text]
            )
        }
        let mediums = mediumTexts.enumerated().map { index, text in
            TuringQwenBenchmarkCase(
                id: String(format: "medium-%02d", index + 1),
                tier: .medium,
                segments: [text]
            )
        }
        let longs = longOpenings.enumerated().map { index, opening in
            TuringQwenBenchmarkCase(
                id: String(format: "long-%02d", index + 1),
                tier: .long,
                segments: [opening] + longContinuationSentences
            )
        }
        let multiMinute = multiIntroductions.enumerated().map { index, introduction in
            var segments = [introduction]
            for cycle in 1...4 {
                for paragraph in multiParagraphSentences {
                    guard let firstSentence = paragraph.first else { continue }
                    segments.append("Cycle \(cycle). \(firstSentence)")
                    segments.append(contentsOf: paragraph.dropFirst())
                }
            }
            return TuringQwenBenchmarkCase(
                id: String(format: "multi-minute-%02d", index + 1),
                tier: .multiMinute,
                segments: segments
            )
        }
        return shorts + mediums + longs + multiMinute
    }()

    /// A smoke suite with representative short, medium, and long inputs. The
    /// full suite is the release/optimization comparison suite.
    public static let quick: [TuringQwenBenchmarkCase] = {
        let ids = Set(["short-01", "medium-01", "long-01"])
        return full.filter { ids.contains($0.id) }
    }()

    public static func cases(for suite: TuringQwenBenchmarkSuite) -> [TuringQwenBenchmarkCase] {
        switch suite {
        case .quick:
            quick
        case .full:
            full
        }
    }

    public static var digest: String {
        TuringQwenBenchmarkDigest.string(
            full.map { "\($0.id):\($0.tier.rawValue):\($0.text)" }
                .joined(separator: "\n")
        )
    }
}

public struct TuringQwenBenchmarkModelIdentity: Codable, Sendable {
    public let modelID: String
    public let modelRoot: String
    public let ttsModelType: String
    public let quantizationBits: TuringQwenBenchmarkMeasurement<Int>
    public let quantizationGroupSize: TuringQwenBenchmarkMeasurement<Int>
    public let cloneVoiceID: String
    public let cloneVariantID: String
    public let cloneRevision: TuringQwenBenchmarkMeasurement<String>
}

public struct TuringQwenBenchmarkDeviceIdentity: Codable, Sendable {
    public let hostName: String
    public let operatingSystem: String
    public let architecture: String
    public let physicalMemoryBytes: UInt64
    public let metalDevice: TuringQwenBenchmarkMeasurement<String>
}

public struct TuringQwenBenchmarkBuildIdentity: Codable, Sendable {
    public let configuration: String
    public let gitRevision: TuringQwenBenchmarkMeasurement<String>
    public let executable: TuringQwenBenchmarkMeasurement<String>
    public let commandBufferProfile: String
}

public struct TuringQwenBenchmarkConfiguration: Codable, Sendable {
    public let suite: TuringQwenBenchmarkSuite
    public let corpusDigest: String
    public let warmupText: String
    public let warmupCount: Int
    public let language: String
    public let maxNewRowsPerSegment: Int
    public let referenceWindowStrategy: String
    public let samplingPolicy: String
    public let samplingSeed: UInt64
    public let performanceMode: String
    public let playbackRate: Double
    public let playbackRateApplied: Bool
    public let residencyMode: String
    public let benchmarkLanePolicy: String
}

public struct TuringQwenBenchmarkInput: Codable, Sendable {
    public let id: String
    public let tier: TuringQwenBenchmarkTier
    public let text: String
    public let textDigest: String
    public let characterCount: Int
    public let wordCount: Int
    public let segments: [String]
}

public struct TuringQwenBenchmarkOutput: Codable, Sendable {
    public let generatedRows: TuringQwenBenchmarkMeasurement<Int>
    public let audioSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let sampleCount: TuringQwenBenchmarkMeasurement<Int>
    public let sampleRate: TuringQwenBenchmarkMeasurement<Int>
    public let audioDigest: TuringQwenBenchmarkMeasurement<String>
    public let reachedEOSSegments: TuringQwenBenchmarkMeasurement<Int>
    public let rowCapSegments: TuringQwenBenchmarkMeasurement<Int>
}

public struct TuringQwenBenchmarkTiming: Codable, Sendable {
    public let requestToFirstRowSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let requestToFirstPCMSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let requestToScheduledPlaybackSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let requestToAudibleCallbackSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let initialPromptSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let talkerSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let codePredictorSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let tokenMaterializationSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let speechDecoderSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let totalWallSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let audioSecondsPerWallSecond: TuringQwenBenchmarkMeasurement<Double>
    public let rowsPerSecond: TuringQwenBenchmarkMeasurement<Double>
}

public struct TuringQwenBenchmarkMemory: Codable, Sendable {
    public let processFootprintBeforeMB: TuringQwenBenchmarkMeasurement<Double>
    public let processFootprintAfterMB: TuringQwenBenchmarkMeasurement<Double>
    public let peakProcessFootprintMB: TuringQwenBenchmarkMeasurement<Double>
    public let mlxActiveBeforeMB: TuringQwenBenchmarkMeasurement<Double>
    public let mlxActiveAfterMB: TuringQwenBenchmarkMeasurement<Double>
    public let peakMLXActiveMB: TuringQwenBenchmarkMeasurement<Double>
    public let mlxCacheBeforeMB: TuringQwenBenchmarkMeasurement<Double>
    public let mlxCacheAfterMB: TuringQwenBenchmarkMeasurement<Double>
    public let peakMLXCacheMB: TuringQwenBenchmarkMeasurement<Double>
}

public struct TuringQwenBenchmarkExecution: Codable, Sendable {
    public let underrunCount: TuringQwenBenchmarkMeasurement<Int>
    public let synchronizationBarrierCount: TuringQwenBenchmarkMeasurement<Int>
    public let hostReadbackElementCount: TuringQwenBenchmarkMeasurement<Int>
    public let allocationCount: TuringQwenBenchmarkMeasurement<Int>
    public let laneCount: TuringQwenBenchmarkMeasurement<Int>
    public let laneIdentity: TuringQwenBenchmarkMeasurement<String>
    public let streamIdentity: TuringQwenBenchmarkMeasurement<String>
    public let commandBuffersSubmitted: TuringQwenBenchmarkMeasurement<Int>
    public let commandBuffersCompleted: TuringQwenBenchmarkMeasurement<Int>
    public let commandBufferFailures: TuringQwenBenchmarkMeasurement<Int>

    public init(
        underrunCount: TuringQwenBenchmarkMeasurement<Int>,
        synchronizationBarrierCount: TuringQwenBenchmarkMeasurement<Int>,
        hostReadbackElementCount: TuringQwenBenchmarkMeasurement<Int>,
        allocationCount: TuringQwenBenchmarkMeasurement<Int>,
        laneCount: TuringQwenBenchmarkMeasurement<Int>,
        laneIdentity: TuringQwenBenchmarkMeasurement<String>,
        streamIdentity: TuringQwenBenchmarkMeasurement<String>,
        commandBuffersSubmitted: TuringQwenBenchmarkMeasurement<Int>,
        commandBuffersCompleted: TuringQwenBenchmarkMeasurement<Int>,
        commandBufferFailures: TuringQwenBenchmarkMeasurement<Int>
    ) {
        self.underrunCount = underrunCount
        self.synchronizationBarrierCount = synchronizationBarrierCount
        self.hostReadbackElementCount = hostReadbackElementCount
        self.allocationCount = allocationCount
        self.laneCount = laneCount
        self.laneIdentity = laneIdentity
        self.streamIdentity = streamIdentity
        self.commandBuffersSubmitted = commandBuffersSubmitted
        self.commandBuffersCompleted = commandBuffersCompleted
        self.commandBufferFailures = commandBufferFailures
    }

    private enum CodingKeys: String, CodingKey {
        case underrunCount
        case synchronizationBarrierCount
        case hostReadbackElementCount
        case allocationCount
        case laneCount
        case laneIdentity
        case streamIdentity
        case commandBuffersSubmitted
        case commandBuffersCompleted
        case commandBufferFailures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        underrunCount = try container.decode(
            TuringQwenBenchmarkMeasurement<Int>.self,
            forKey: .underrunCount
        )
        synchronizationBarrierCount = try container.decode(
            TuringQwenBenchmarkMeasurement<Int>.self,
            forKey: .synchronizationBarrierCount
        )
        hostReadbackElementCount = try container.decode(
            TuringQwenBenchmarkMeasurement<Int>.self,
            forKey: .hostReadbackElementCount
        )
        allocationCount = try container.decode(
            TuringQwenBenchmarkMeasurement<Int>.self,
            forKey: .allocationCount
        )
        laneCount = try container.decodeIfPresent(
            TuringQwenBenchmarkMeasurement<Int>.self,
            forKey: .laneCount
        ) ?? .unavailable(
            "Baseline report predates numeric laneCount instrumentation."
        )
        laneIdentity = try container.decode(
            TuringQwenBenchmarkMeasurement<String>.self,
            forKey: .laneIdentity
        )
        streamIdentity = try container.decode(
            TuringQwenBenchmarkMeasurement<String>.self,
            forKey: .streamIdentity
        )
        commandBuffersSubmitted = try container.decode(
            TuringQwenBenchmarkMeasurement<Int>.self,
            forKey: .commandBuffersSubmitted
        )
        commandBuffersCompleted = try container.decode(
            TuringQwenBenchmarkMeasurement<Int>.self,
            forKey: .commandBuffersCompleted
        )
        commandBufferFailures = try container.decode(
            TuringQwenBenchmarkMeasurement<Int>.self,
            forKey: .commandBufferFailures
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(underrunCount, forKey: .underrunCount)
        try container.encode(
            synchronizationBarrierCount,
            forKey: .synchronizationBarrierCount
        )
        try container.encode(
            hostReadbackElementCount,
            forKey: .hostReadbackElementCount
        )
        try container.encode(allocationCount, forKey: .allocationCount)
        try container.encode(laneCount, forKey: .laneCount)
        try container.encode(laneIdentity, forKey: .laneIdentity)
        try container.encode(streamIdentity, forKey: .streamIdentity)
        try container.encode(
            commandBuffersSubmitted,
            forKey: .commandBuffersSubmitted
        )
        try container.encode(
            commandBuffersCompleted,
            forKey: .commandBuffersCompleted
        )
        try container.encode(
            commandBufferFailures,
            forKey: .commandBufferFailures
        )
    }
}

public struct TuringQwenBenchmarkQuality: Codable, Sendable {
    public let passed: Bool
    public let decodedSegmentCount: Int
    public let expectedSegmentCount: Int
    public let samplesAreFinite: TuringQwenBenchmarkMeasurement<Bool>
    public let nonEmptyAudio: TuringQwenBenchmarkMeasurement<Bool>
    public let peakAbsoluteSample: TuringQwenBenchmarkMeasurement<Float>
    public let rms: TuringQwenBenchmarkMeasurement<Float>
    public let perceptualAssessment: TuringQwenBenchmarkMeasurement<String>
}

public struct TuringQwenBenchmarkThermal: Codable, Sendable {
    public let stateBefore: TuringQwenBenchmarkMeasurement<String>
    public let stateAfter: TuringQwenBenchmarkMeasurement<String>
}

public enum TuringQwenBenchmarkRunStatus: String, Codable, Sendable {
    case passed
    case failed
    case skipped
}

public struct TuringQwenBenchmarkResult: Codable, Sendable {
    public let status: TuringQwenBenchmarkRunStatus
    public let input: TuringQwenBenchmarkInput
    public let output: TuringQwenBenchmarkOutput
    public let timing: TuringQwenBenchmarkTiming
    public let memory: TuringQwenBenchmarkMemory
    public let execution: TuringQwenBenchmarkExecution
    public let quality: TuringQwenBenchmarkQuality
    public let thermal: TuringQwenBenchmarkThermal
    public let error: String?
}

public struct TuringQwenBenchmarkAggregate: Codable, Sendable {
    public let caseCount: Int
    public let passedCaseCount: Int
    public let failedCaseCount: Int
    public let segmentCount: Int
    public let generatedRows: TuringQwenBenchmarkMeasurement<Int>
    public let audioSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let totalWallSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let audioSecondsPerWallSecond: TuringQwenBenchmarkMeasurement<Double>
    public let rowsPerSecond: TuringQwenBenchmarkMeasurement<Double>
    public let synchronizationBarrierCount: TuringQwenBenchmarkMeasurement<Int>
    public let hostReadbackElementCount: TuringQwenBenchmarkMeasurement<Int>
    public let tokenMaterializationSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let peakProcessFootprintMB: TuringQwenBenchmarkMeasurement<Double>
    public let peakMLXActiveMB: TuringQwenBenchmarkMeasurement<Double>
    public let peakMLXCacheMB: TuringQwenBenchmarkMeasurement<Double>
    public let commandBufferFailures: TuringQwenBenchmarkMeasurement<Int>
}

public struct TuringQwenBenchmarkMetricDelta: Codable, Sendable {
    public let metric: String
    public let before: TuringQwenBenchmarkMeasurement<Double>
    public let after: TuringQwenBenchmarkMeasurement<Double>
    public let delta: TuringQwenBenchmarkMeasurement<Double>
    public let deltaPercent: TuringQwenBenchmarkMeasurement<Double>
}

public struct TuringQwenBenchmarkComparison: Codable, Sendable {
    public let status: String
    public let baselineLabel: TuringQwenBenchmarkMeasurement<String>
    public let metrics: [TuringQwenBenchmarkMetricDelta]
    public let matchingCaseCount: TuringQwenBenchmarkMeasurement<Int>
    public let exactAudioDigestMatchCount: TuringQwenBenchmarkMeasurement<Int>
    public let qualityRegressions: [String]
}

public enum TuringQwenBenchmarkCompletionStatus: String, Codable, Sendable {
    case pass
    case fail
}

public struct TuringQwenBenchmarkCompletion: Codable, Sendable {
    public let status: TuringQwenBenchmarkCompletionStatus
    public let reasons: [String]
}

public struct TuringQwenOptimizationBenchmarkReport: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAtUTC: String
    public let label: String
    public let model: TuringQwenBenchmarkModelIdentity
    public let device: TuringQwenBenchmarkDeviceIdentity
    public let build: TuringQwenBenchmarkBuildIdentity
    public let configuration: TuringQwenBenchmarkConfiguration
    public let warmup: TuringQwenBenchmarkMeasurement<Double>
    public let results: [TuringQwenBenchmarkResult]
    public let aggregate: TuringQwenBenchmarkAggregate
    public let comparison: TuringQwenBenchmarkComparison
    public let completion: TuringQwenBenchmarkCompletion
}

enum TuringQwenBenchmarkDigest {
    struct Accumulator {
        private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

        mutating func update(bytes: some Sequence<UInt8>) {
            for byte in bytes {
                value ^= UInt64(byte)
                value &*= 0x0000_0100_0000_01B3
            }
        }

        mutating func update(float: Float) {
            let bits = float.bitPattern
            update(bytes: [
                UInt8(truncatingIfNeeded: bits),
                UInt8(truncatingIfNeeded: bits >> 8),
                UInt8(truncatingIfNeeded: bits >> 16),
                UInt8(truncatingIfNeeded: bits >> 24)
            ])
        }

        var string: String {
            String(format: "%016llx", value)
        }
    }

    static func string(_ value: String) -> String {
        var accumulator = Accumulator()
        accumulator.update(bytes: value.utf8)
        return accumulator.string
    }
}
