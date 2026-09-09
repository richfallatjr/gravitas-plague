import AudioToolbox
import AVFAudio
import Darwin
import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringPCMStreamFoundationTests: XCTestCase {
    func testQwenDefaultsUseEightSecondCapacityAndTwoChunkWatermark() throws {
        let configuration = TuringPCMStreamConfiguration.qwenDefault

        try configuration.validate()
        XCTAssertEqual(configuration.sourceSampleRate, 24_000)
        XCTAssertEqual(configuration.channelCount, 1)
        XCTAssertEqual(configuration.outputCapacityFrames, 384_000)
        XCTAssertEqual(configuration.startupWatermarkFrames, 36_000)

        // Current Qwen chunks are 0.64 seconds. One must not start playback;
        // two cross the 0.75-second watermark with useful headroom.
        let outputFramesPerChunk = Int(0.64 * 48_000)
        XCTAssertLessThan(outputFramesPerChunk, configuration.startupWatermarkFrames)
        XCTAssertGreaterThanOrEqual(
            outputFramesPerChunk * 2,
            configuration.startupWatermarkFrames
        )
    }

    func testRingPreservesOrderAcrossWrapAndRejectsOversizedAppend() throws {
        let buffer = try makeBuffer(
            capacityFrames: 48,
            watermarkFrames: 24
        )
        XCTAssertTrue(
            buffer.tryAppend(
                ContiguousArray((0..<32).map(Float.init))
            )
        )
        XCTAssertTrue(buffer.hasReachedStartupWatermark)

        let first = render(buffer, frameCount: 20)
        XCTAssertEqual(first.samples, Array(0..<20).map(Float.init))
        XCTAssertFalse(first.isSilence)

        let wrapped = ContiguousArray((100..<130).map(Float.init))
        XCTAssertTrue(buffer.tryAppend(wrapped))
        XCTAssertFalse(
            buffer.tryAppend(
                ContiguousArray(repeating: 7, count: 49)
            )
        )

        let second = render(buffer, frameCount: 42)
        XCTAssertEqual(
            second.samples,
            Array(20..<32).map(Float.init) + Array(100..<130).map(Float.init)
        )
        XCTAssertEqual(buffer.availableFrames, 0)

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.renderedFrames, 62)
        XCTAssertEqual(snapshot.underrunCount, 0)
        XCTAssertNotNil(snapshot.firstPCMHostTime)
    }

    func testRenderZeroFillsAndCountsOnlyUnsealedUnderruns() throws {
        let buffer = try makeBuffer(
            capacityFrames: 48,
            watermarkFrames: 24
        )
        XCTAssertTrue(
            buffer.tryAppend(ContiguousArray([0.25, -0.5, 0.75, 1]))
        )

        let partial = render(buffer, frameCount: 8)
        XCTAssertEqual(
            partial.samples,
            [0.25, -0.5, 0.75, 1, 0, 0, 0, 0]
        )
        XCTAssertFalse(partial.isSilence)
        XCTAssertEqual(buffer.snapshot().underrunCount, 1)
        XCTAssertEqual(buffer.snapshot().underrunFrames, 4)

        buffer.seal()
        XCTAssertTrue(buffer.isDrained)
        let sealedEmpty = render(buffer, frameCount: 8)
        XCTAssertEqual(sealedEmpty.samples, Array(repeating: 0, count: 8))
        XCTAssertTrue(sealedEmpty.isSilence)
        XCTAssertEqual(buffer.snapshot().underrunCount, 1)
        XCTAssertEqual(buffer.snapshot().underrunFrames, 4)
    }

    func testStatefulTwentyFourToFortyEightKilohertzConversion() throws {
        let converter = try TuringPCMStreamRateConverter(
            sourceSampleRate: 24_000
        )
        let firstInput = makeSine(frameCount: 1_537, offset: 0)
        let secondInput = makeSine(
            frameCount: 2_111,
            offset: firstInput.count
        )

        let first = try converter.convert(firstInput)
        let second = try converter.convert(secondInput)
        let tail = try converter.finish()
        let output = Array(first + second + tail)

        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertTrue(output.allSatisfy { (-1...1).contains($0) })
        XCTAssertEqual(
            output.count,
            (firstInput.count + secondInput.count) * 2,
            accuracy: 8
        )
        XCTAssertEqual(try converter.finish(), [])
        XCTAssertThrowsError(try converter.convert([0])) { error in
            XCTAssertEqual(error as? TuringPCMStreamError, .appendAfterSeal)
        }
    }

    func testProducerRejectsOutOfOrderChunksWithoutAdvancing() async throws {
        let configuration = TuringPCMStreamConfiguration(
            sourceSampleRate: 24_000,
            channelCount: 1,
            capacitySeconds: 1,
            startupWatermarkSeconds: 0.01
        )
        let buffer = try TuringPCMStreamBuffer(configuration: configuration)
        let converter = try TuringPCMStreamRateConverter(
            sourceSampleRate: configuration.sourceSampleRate
        )
        let handle = TuringAudioPlaybackHandle(
            id: UUID(),
            requestID: UUID(),
            runID: "pcm-test",
            route: .storyWalkie
        )
        let store = TuringPCMStreamProducerStore()
        try await store.install(
            handle: handle,
            configuration: configuration,
            buffer: buffer,
            converter: converter
        )

        let firstSamples = makeSine(frameCount: 240, offset: 0)
        let first = try await store.append(
            TuringPCMStreamChunk(
                sequenceNumber: 0,
                sourceFrameOffset: 0,
                samples: firstSamples
            ),
            to: handle
        )
        XCTAssertEqual(first.acceptedSequenceNumber, 0)
        XCTAssertEqual(first.acceptedSourceFrameCount, 240)

        do {
            _ = try await store.append(
                TuringPCMStreamChunk(
                    sequenceNumber: 0,
                    sourceFrameOffset: 240,
                    samples: [0]
                ),
                to: handle
            )
            XCTFail("Expected sequence rejection.")
        } catch {
            XCTAssertEqual(
                error as? TuringPCMStreamError,
                .sequenceMismatch(expected: 1, actual: 0)
            )
        }

        do {
            _ = try await store.append(
                TuringPCMStreamChunk(
                    sequenceNumber: 1,
                    sourceFrameOffset: 241,
                    samples: [0]
                ),
                to: handle
            )
            XCTFail("Expected offset rejection.")
        } catch {
            XCTAssertEqual(
                error as? TuringPCMStreamError,
                .frameOffsetMismatch(expected: 240, actual: 241)
            )
        }

        let capturedMetrics = await store.metrics(handle)
        let metrics = try XCTUnwrap(capturedMetrics)
        XCTAssertEqual(metrics.nextExpectedSequenceNumber, 1)
        XCTAssertEqual(metrics.nextExpectedSourceFrameOffset, 240)
        XCTAssertEqual(metrics.appendedSourceFrames, 240)

        _ = try await store.append(
            TuringPCMStreamChunk(
                sequenceNumber: 1,
                sourceFrameOffset: 240,
                samples: makeSine(frameCount: 240, offset: 240)
            ),
            to: handle
        )
        try await store.seal(handle)

        do {
            _ = try await store.append(
                TuringPCMStreamChunk(
                    sequenceNumber: 2,
                    sourceFrameOffset: 480,
                    samples: [0]
                ),
                to: handle
            )
            XCTFail("Expected append-after-seal rejection.")
        } catch {
            XCTAssertEqual(error as? TuringPCMStreamError, .appendAfterSeal)
        }
    }

    private func makeBuffer(
        capacityFrames: Int,
        watermarkFrames: Int
    ) throws -> TuringPCMStreamBuffer {
        try TuringPCMStreamBuffer(
            configuration: TuringPCMStreamConfiguration(
                sourceSampleRate: 24_000,
                channelCount: 1,
                capacitySeconds: Double(capacityFrames) / 48_000,
                startupWatermarkSeconds:
                    Double(watermarkFrames) / 48_000
            )
        )
    }

    private func render(
        _ buffer: TuringPCMStreamBuffer,
        frameCount: Int
    ) -> (samples: [Float], isSilence: Bool) {
        var samples = Array(repeating: Float.nan, count: frameCount)
        var silence = ObjCBool(false)
        var timestamp = AudioTimeStamp()
        timestamp.mHostTime = mach_absolute_time()
        timestamp.mFlags = [.hostTimeValid]
        let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
            var audioBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return withUnsafePointer(to: &timestamp) { timestampPointer in
                buffer.render(
                    isSilence: &silence,
                    timestamp: timestampPointer,
                    frameCount: AVAudioFrameCount(frameCount),
                    outputData: &audioBufferList
                )
            }
        }
        XCTAssertEqual(status, noErr)
        return (samples, silence.boolValue)
    }

    private func makeSine(frameCount: Int, offset: Int) -> [Float] {
        (0..<frameCount).map { frame in
            Float(sin(Double(frame + offset) * 0.03125) * 0.8)
        }
    }
}
