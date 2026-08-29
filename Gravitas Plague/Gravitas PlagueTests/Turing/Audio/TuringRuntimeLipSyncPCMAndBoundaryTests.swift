import XCTest

@testable import Gravitas_Plague

final class TuringRuntimeLipSyncPCMPreprocessorTests: XCTestCase {
    func testSanitizesDownmixesAndConvertsDeterministically() async throws {
        let samples: [Float] = [
            1.5, -0.5,
            .nan, .infinity,
            -1.5, 0.5,
            0.25, 0.75
        ]
        let first = try await prepare(
            samples: samples,
            sampleRate: 16_000,
            channelCount: 2
        )
        let second = try await prepare(
            samples: samples,
            sampleRate: 16_000,
            channelCount: 2
        )

        XCTAssertEqual(first.monoPCM16, second.monoPCM16)
        XCTAssertEqual(first.sourcePCM_SHA256, second.sourcePCM_SHA256)
        XCTAssertEqual(first.monoPCM16, [8192, 0, -8192, 16384])
        XCTAssertEqual(first.alignmentSampleRate, 16_000)
    }

    func testResamplesCommonQwenRatesWithinDurationTolerance() async throws {
        for rate in [24_000, 44_100, 48_000] {
            let prepared = try await prepare(
                samples: Array(repeating: Float(0.125), count: rate),
                sampleRate: rate,
                channelCount: 1
            )
            XCTAssertEqual(prepared.monoPCM16.count, 16_000, accuracy: 2)
        }
    }

    func testCancellationIsObservedBeforePreprocessing() async {
        let token = TuringGeneratedSpeechAnalysisCancellationToken()
        token.cancel()
        do {
            _ = try await prepare(
                samples: [0, 0],
                sampleRate: 16_000,
                channelCount: 1,
                cancellation: token
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? TuringRuntimeLipSyncFailure, .cancelled)
        }
    }

    private func prepare(
        samples: [Float],
        sampleRate: Int,
        channelCount: Int,
        cancellation: TuringGeneratedSpeechAnalysisCancellationToken = .init()
    ) async throws -> TuringRuntimeLipSyncPreparedPCM {
        let text = "test"
        let input = try TuringRuntimeLipSyncInput(
            identity: TuringGeneratedSpeechSegmentIdentity(
                runID: "pcm",
                segmentIndex: 0,
                speakerCharacterID: .bigMike,
                sourceTextSHA256: TuringRuntimeLipSyncSHA256.text(text)
            ),
            exactSourceText: text,
            interleavedPCM: samples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            queuedAt: .now
        )
        return try await Task.detached {
            try TuringRuntimeLipSyncPCMPreprocessor().prepare(
                input: input,
                cancellation: cancellation
            )
        }.value
    }
}

final class TuringRuntimeLipSyncBoundaryRefinerTests: XCTestCase {
    func testRefinementIsDeterministicOrderedAndNonempty() throws {
        let sampleRate = 16_000
        var pcm = Array(repeating: Float.zero, count: sampleRate)
        for index in 2_400..<12_000 {
            pcm[index] = index.isMultiple(of: 2) ? 0.25 : -0.25
        }
        let phones: [TuringRuntimeLipSyncSourcePhoneSpan] = [
            .init(phone: "SIL", pose: .rest, startSample: 0, endSampleExclusive: 1_600, unknownAllPhoneLabel: false),
            .init(phone: "AA", pose: .wide, startSample: 1_600, endSampleExclusive: 8_000, unknownAllPhoneLabel: false),
            .init(phone: "SIL", pose: .rest, startSample: 8_000, endSampleExclusive: 16_000, unknownAllPhoneLabel: false)
        ]
        let token = TuringGeneratedSpeechAnalysisCancellationToken()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))

        let first = try TuringRuntimeLipSyncBoundaryRefiner().refine(
            phones: phones,
            finalPCM: pcm,
            sampleRate: sampleRate,
            channelCount: 1,
            cancellation: token,
            deadline: deadline
        )
        let second = try TuringRuntimeLipSyncBoundaryRefiner().refine(
            phones: phones,
            finalPCM: pcm,
            sampleRate: sampleRate,
            channelCount: 1,
            cancellation: token,
            deadline: deadline
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.phones.allSatisfy { $0.startSample < $0.endSampleExclusive })
        XCTAssertEqual(first.phones, first.phones.sorted {
            ($0.startSample, $0.endSampleExclusive) <
                ($1.startSample, $1.endSampleExclusive)
        })
        XCTAssertTrue((-12...12).contains(first.globalOffsetFrames))
    }

    func testUnknownAllPhoneLabelUsesActivityWithoutChangingRegistration() throws {
        let phone = TuringRuntimeLipSyncSourcePhoneSpan(
            phone: "UNKNOWN",
            pose: .wide,
            startSample: 0,
            endSampleExclusive: 1_600,
            unknownAllPhoneLabel: true
        )
        let result = try TuringRuntimeLipSyncBoundaryRefiner().refine(
            phones: [phone],
            finalPCM: Array(repeating: 0, count: 1_600),
            sampleRate: 16_000,
            channelCount: 1,
            cancellation: .init(),
            deadline: ContinuousClock.now.advanced(by: .seconds(1))
        )

        XCTAssertEqual(result.degradedPhoneCount, 1)
        XCTAssertEqual(result.phones.first?.pose, .rest)
    }
}
