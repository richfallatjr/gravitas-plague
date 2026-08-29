import XCTest

@testable import Gravitas_Plague

private enum MindEyePhase9GeneratedFixtures {
    static func sourceTrack(
        poses: [TuringGeneratedMouthPose]
    ) throws -> TuringGeneratedSpeechFrameTrack {
        var runs = ContiguousArray<TuringGeneratedMouthPoseRun>()
        for (index, pose) in poses.enumerated() {
            if let last = runs.last, last.pose == pose {
                runs[runs.count - 1] = .init(
                    startFrame: last.startFrame,
                    endFrameExclusive: index + 1,
                    pose: pose
                )
            } else {
                runs.append(.init(startFrame: index, endFrameExclusive: index + 1, pose: pose))
            }
        }
        return try TuringGeneratedSpeechFrameTrack(
            sampleRate: 60,
            sampleCount: poses.count,
            poseBits: ContiguousArray(poses.map(\.rawValue)),
            poseRuns: runs
        )
    }
}

final class MindEyeGeneratedFrameTrackAdapterTests: XCTestCase {
    func testAdapterCompactsToMindEyeRunsWithoutFrameArray() throws {
        let source = try MindEyePhase9GeneratedFixtures.sourceTrack(
            poses: [.rest, .small, .small, .wide, .teeth, .rest]
        )
        let adapted = try MindEyeGeneratedFrameTrackAdapter.adapt(source).get()
        XCTAssertEqual(adapted.frameCount, 6)
        XCTAssertEqual(adapted.poseRuns.map(\.pose), [.rest, .small, .wide, .teeth, .rest])
        XCTAssertEqual(adapted.poseRuns.last?.endFrameExclusive, adapted.frameCount)
    }
}

final class MindEyeGeneratedFrameClockMapperTests: XCTestCase {
    func testExactFrameBoundariesAndPastEnd() throws {
        let source = try MindEyePhase9GeneratedFixtures.sourceTrack(
            poses: [.rest, .small, .wide, .round, .teeth, .rest]
        )
        let track = try MindEyeGeneratedFrameTrackAdapter.adapt(source).get()
        XCTAssertEqual(try MindEyeGeneratedFrameClockMapper.position(elapsed: .zero, track: track).get(), .frame(0))
        XCTAssertEqual(try MindEyeGeneratedFrameClockMapper.position(elapsed: .milliseconds(50), track: track).get(), .frame(3))
        XCTAssertEqual(try MindEyeGeneratedFrameClockMapper.position(elapsed: .milliseconds(100), track: track).get(), .pastEnd)
    }
}

final class MindEyeGeneratedMouthVariantPlanTests: XCTestCase {
    func testGeneratedStreamsAreDeterministicAndBounded() throws {
        let source = try MindEyePhase9GeneratedFixtures.sourceTrack(
            poses: [.rest, .small, .rest, .wide, .round, .teeth, .rest]
        )
        let track = try MindEyeGeneratedFrameTrackAdapter.adapt(source).get()
        let counts = MindEyeMouthVariantCounts(rest: 2, small: 2, wide: 2, round: 2, teeth: 2)
        let first = try MindEyeGeneratedMouthVariantPlanBuilder.build(
            track: track, counts: counts, rootSeed: 42
        ).get()
        let second = try MindEyeGeneratedMouthVariantPlanBuilder.build(
            track: track, counts: counts, rootSeed: 42
        ).get()
        XCTAssertEqual(first, second)
        for index in track.poseRuns.indices {
            let selection = try XCTUnwrap(first.selection(forRun: index, track: track))
            XCTAssertTrue((0..<counts.count(for: selection.pose)).contains(selection.variantIndex))
        }
    }
}

final class MindEyeGeneratedMouthPlaybackSessionTests: XCTestCase {
    func testSameRunDoesNotRedeliverAndPastEndReturnsRestOnce() throws {
        let source = try MindEyePhase9GeneratedFixtures.sourceTrack(
            poses: [.small, .small, .wide, .wide, .rest, .rest]
        )
        let track = try MindEyeGeneratedFrameTrackAdapter.adapt(source).get()
        let plan = try MindEyeGeneratedMouthVariantPlanBuilder.build(
            track: track,
            counts: .init(rest: 1, small: 1, wide: 1, round: 1, teeth: 1),
            rootSeed: 3
        ).get()
        let origin = ContinuousClock.now
        var session = MindEyeGeneratedFramePlaybackSession(
            presentationKey: .init(playbackRunID: "run", playbackHandleID: UUID()),
            segmentIndex: 2,
            track: track,
            variantPlan: plan,
            clock: .init(origin: origin)
        )
        XCTAssertNotNil(try session.sample(at: origin).get())
        XCTAssertNil(try session.sample(at: origin.advanced(by: .milliseconds(10))).get())
        XCTAssertEqual(
            try session.sample(at: origin.advanced(by: .milliseconds(40))).get()?.selection.pose,
            .wide
        )
        XCTAssertEqual(
            try session.sample(at: origin.advanced(by: .milliseconds(100))).get()?.selection.pose,
            .rest
        )
        XCTAssertNil(try session.sample(at: origin.advanced(by: .milliseconds(200))).get())
    }
}
