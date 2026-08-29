import XCTest

@testable import Gravitas_Plague

final class TuringGeneratedSpeechSourceTextPairingTests: XCTestCase {
    func testNonStreamingAndStreamingPairBySegmentIndexAndReleaseAfterPublication() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/Flow/" +
                    "TuringCharacterQwenRenderSession.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("await state.sourceText("))
        XCTAssertTrue(source.contains("for: result.segmentIndex"))
        XCTAssertTrue(source.contains("requireSourceText(\n                            for: result.segmentIndex"))
        XCTAssertTrue(source.contains("sourceTextBySegmentIndex.removeValue(forKey: index)"))
        XCTAssertTrue(source.contains("Duplicate streaming segment index"))
        XCTAssertFalse(source.contains("BEGIN_TEXT"))
    }

    func testGeneratedPayloadCarriesExactTextAndHashTogether() {
        let text = "Exact punctuation — and spacing."
        let audio = TuringComputeGapGeneratedAudio(
            segmentIndex: 7,
            samples: [0, 0.1],
            sampleRate: 16_000,
            sourceText: text
        )
        XCTAssertEqual(audio.sourceText, text)
        XCTAssertEqual(
            audio.sourceTextSHA256,
            TuringRuntimeLipSyncSHA256.text(text)
        )
    }
}

final class TuringRuntimeLipSyncTextNormalizerTests: XCTestCase {
    private let normalizer = TuringRuntimeLipSyncTextNormalizer()

    func testNormalizesProductionTextFormsDeterministically() throws {
        let normalized = try normalizer.normalize(
            exactText: "I’ll re-check 42, -7, 3.5, 21st, 80%, 9:05 — NASA.",
            wordKnown: { word in
                ["i'll", "re", "check"].contains(word)
            }
        )

        XCTAssertEqual(
            normalized.normalizedAlignmentText,
            "i'll re check forty two minus seven three point five " +
                "twenty first eighty percent nine oh five " +
                "en ay ess ay"
        )
        XCTAssertTrue(normalized.transformationCodes.contains("smartApostrophe"))
        XCTAssertTrue(normalized.transformationCodes.contains("hyphenSplit"))
        XCTAssertTrue(normalized.transformationCodes.contains("integer"))
        XCTAssertTrue(normalized.transformationCodes.contains("decimal"))
        XCTAssertTrue(normalized.transformationCodes.contains("ordinal"))
        XCTAssertTrue(normalized.transformationCodes.contains("percentage"))
        XCTAssertTrue(normalized.transformationCodes.contains("time"))
        XCTAssertTrue(normalized.transformationCodes.contains("acronym"))
    }

    func testKeepsDictionaryKnownUppercaseWordAndAppliesNFKC() throws {
        let normalized = try normalizer.normalize(
            exactText: "ＭＩＫＥ NASA",
            wordKnown: { $0 == "mike" }
        )

        XCTAssertEqual(normalized.normalizedWords, ["mike", "en", "ay", "ess", "ay"])
        XCTAssertTrue(normalized.transformationCodes.contains("nfkc"))
    }

    func testRejectsEmptyAndPunctuationOnlyText() {
        XCTAssertThrowsError(try normalizer.normalize(exactText: ""))
        XCTAssertThrowsError(try normalizer.normalize(exactText: "… — !!!"))
    }

    func testInputRejectsSourceTextHashMismatch() {
        let identity = TuringGeneratedSpeechSegmentIdentity(
            runID: "run",
            segmentIndex: 1,
            speakerCharacterID: .bigMike,
            sourceTextSHA256: TuringRuntimeLipSyncSHA256.text("right")
        )
        XCTAssertThrowsError(
            try TuringRuntimeLipSyncInput(
                identity: identity,
                exactSourceText: "wrong",
                interleavedPCM: [0],
                sampleRate: 16_000,
                channelCount: 1,
                queuedAt: .now
            )
        )
    }
}

final class TuringRuntimeLipSyncPhoneMapperTests: XCTestCase {
    func testEveryDirectPoseFamilyAndSilenceAreMapped() {
        let expected: [(String, TuringGeneratedMouthPose)] = [
            ("SIL", .rest), ("P", .small), ("AA", .wide),
            ("OW", .round), ("SH", .teeth)
        ]
        for (phone, pose) in expected {
            XCTAssertEqual(
                TuringRuntimeLipSyncPhoneTimelineMapper.pose(
                    for: phone,
                    allPhone: false
                )?.pose,
                pose,
                phone
            )
        }
    }

    func testStressSuffixesAndCompoundVowelsMapOnSourceTimeline() throws {
        let alignment = TuringPocketSphinxAlignmentResult(
            quality: .forcedTextPhones,
            alignmentFrameRate: 100,
            searchedAudioFrameCount: 30,
            segments: [
                .init(phone: "AW1", startFrame: 0, durationFrames: 10, acousticScore: 0),
                .init(phone: "OY2", startFrame: 10, durationFrames: 10, acousticScore: 0),
                .init(phone: "SIL", startFrame: 20, durationFrames: 10, acousticScore: 0)
            ],
            firstPassNanoseconds: nil,
            secondPassNanoseconds: nil
        )

        let spans = try TuringRuntimeLipSyncPhoneTimelineMapper().map(
            alignment: alignment,
            sourceSampleRate: 48_000,
            sourceSampleCount: 14_400
        )

        XCTAssertEqual(spans.map(\.pose), [.wide, .round, .round, .wide, .rest])
        XCTAssertEqual(spans.first?.startSample, 0)
        XCTAssertEqual(spans.last?.endSampleExclusive, 14_400)
    }

    func testUnknownPhoneIsRejectedForForcedTextAndDegradedForAllPhone() {
        XCTAssertNil(
            TuringRuntimeLipSyncPhoneTimelineMapper.pose(
                for: "UNKNOWN",
                allPhone: false
            )
        )
        let fallback = TuringRuntimeLipSyncPhoneTimelineMapper.pose(
            for: "UNKNOWN",
            allPhone: true
        )
        XCTAssertEqual(fallback?.pose, .wide)
        XCTAssertEqual(fallback?.unknown, true)
    }
}
