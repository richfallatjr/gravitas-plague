import Darwin
import Foundation
import XCTest
@testable import TuringQwenNative

final class TuringQwenNativePositionalSafetensorsTests: XCTestCase {
    private func fixture(
        metadata: [String: Any]? = nil,
        payload: Data? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-positional-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model.safetensors")
        var header = try JSONSerialization.data(withJSONObject: metadata ?? [
            "f32": ["dtype": "F32", "shape": [3, 2], "data_offsets": [0, 24]],
            "bf16": ["dtype": "BF16", "shape": [2, 2], "data_offsets": [24, 32]]
        ], options: [.sortedKeys])
        while !header.count.isMultiple(of: 8) { header.append(0x20) }
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header)
        if let payload {
            data.append(payload)
        } else {
            for value: Float in [1, -2, 3.5, 4, 5, 6] {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            for value: UInt16 in [0x3f80, 0xc000, 0x4060, 0x4080] {
                var bits = value.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        try data.write(to: url)
        return url
    }

    func testTensorBytesDtypesDuplicateRowsAndEmptySelectionsMatchLegacy() throws {
        let index = try TuringQwenNativeSafetensorsIndex.load(from: fixture())
        let legacy = TuringQwenNativeSafetensorsReader(index: index)
        let candidate = try TuringQwenNativeSafetensorsReader(index: index, decoderIO: .positionalReaderCandidate)
        for name in ["f32", "bf16"] {
            XCTAssertEqual(try candidate.loadTensorFloat32(name: name), try legacy.loadTensorFloat32(name: name))
            XCTAssertEqual(try candidate.loadRowsFloat32(name: name, rows: [1, 0, 1]),
                           try legacy.loadRowsFloat32(name: name, rows: [1, 0, 1]))
            XCTAssertEqual(try candidate.loadRowsFloat32(name: name, rows: []),
                           try legacy.loadRowsFloat32(name: name, rows: []))
        }
        let counters = try XCTUnwrap(candidate.ioCounters())
        XCTAssertEqual(counters.opens, 1)
        XCTAssertEqual(counters.tensorRequests, 2)
        XCTAssertEqual(counters.rowRequests, 4)
        XCTAssertEqual(counters.repeatedTensorRequests, 4)
        XCTAssertEqual(counters.float32ConvertedElements, 12)
        XCTAssertEqual(counters.readCalls, 8)
        XCTAssertEqual(counters.bytesRead, 68)
        XCTAssertNil(legacy.ioCounters())
    }

    func testConcurrentReadsNeverShareASeekCursor() async throws {
        let index = try TuringQwenNativeSafetensorsIndex.load(from: fixture())
        let reader = try TuringQwenNativeSafetensorsReader(index: index, decoderIO: .positionalReaderCandidate)
        let expected = try reader.loadRowsFloat32(name: "f32", rows: [2, 0, 1, 2])
        let values = try await withThrowingTaskGroup(of: TuringQwenNativeFloatTensor.self) { group in
            for _ in 0..<16 {
                group.addTask { try reader.loadRowsFloat32(name: "f32", rows: [2, 0, 1, 2]) }
            }
            var values: [TuringQwenNativeFloatTensor] = []
            for try await result in group { values.append(result) }
            return values
        }
        XCTAssertEqual(values.count, 16)
        XCTAssertTrue(values.allSatisfy { $0 == expected })
        XCTAssertEqual(reader.ioCounters()?.opens, 1)
        XCTAssertEqual(reader.ioCounters()?.readCalls, 68)
    }

    func testPartialReadsAndEINTRRetryWithoutChangingBytes() throws {
        let index = try TuringQwenNativeSafetensorsIndex.load(from: fixture())
        let fault = FirstReadInterrupt()
        let file = try TuringQwenNativePositionalSafetensorsFile(
            url: index.fileURL, expectedIdentity: XCTUnwrap(index.fileIdentity),
            readOperation: { fd, buffer, count, offset in
                if fault.consume() { errno = EINTR; return -1 }
                return Darwin.pread(fd, buffer, min(3, count), offset)
            })
        let bytes = try file.readExactly(offset: index.dataStartOffset, count: 24)
        let allBytes = try Data(contentsOf: index.fileURL)
        XCTAssertEqual(bytes, allBytes.subdata(in: Int(index.dataStartOffset)..<(Int(index.dataStartOffset) + 24)))
        XCTAssertEqual(file.snapshot().readCalls, 9)
        XCTAssertEqual(file.snapshot().interruptedReads, 1)
        XCTAssertEqual(file.snapshot().bytesRead, 24)
    }

    func testTruncationMissingFileAndReplacementAreRejected() throws {
        let url = try fixture()
        let index = try TuringQwenNativeSafetensorsIndex.load(from: url)
        let reader = try TuringQwenNativeSafetensorsReader(index: index, decoderIO: .positionalReaderCandidate)
        let file = try TuringQwenNativePositionalSafetensorsFile(
            url: url, expectedIdentity: XCTUnwrap(index.fileIdentity))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: index.dataStartOffset + 4)
        try handle.close()
        XCTAssertThrowsError(try reader.loadTensorFloat32(name: "f32"))
        XCTAssertThrowsError(try file.readExactly(offset: index.dataStartOffset, count: 24))
        XCTAssertThrowsError(try TuringQwenNativeSafetensorsReader(index: index, decoderIO: .positionalReaderCandidate))

        let replacedURL = try fixture()
        let replacedIndex = try TuringQwenNativeSafetensorsIndex.load(from: replacedURL)
        let replacedReader = try TuringQwenNativeSafetensorsReader(index: replacedIndex, decoderIO: .positionalReaderCandidate)
        let replacementBytes = try Data(contentsOf: replacedURL)
        try FileManager.default.moveItem(at: replacedURL, to: replacedURL.appendingPathExtension("old"))
        try replacementBytes.write(to: replacedURL)
        XCTAssertThrowsError(try replacedReader.loadTensorFloat32(name: "f32"))
        try FileManager.default.removeItem(at: replacedURL)
        XCTAssertThrowsError(try replacedReader.loadTensorFloat32(name: "f32"))
    }

    func testMalformedMetadataAndReadBoundsThrowInsteadOfOverflowing() throws {
        let cases: [[String: Any]] = [
            ["dtype": "F32", "shape": [-1, 2], "data_offsets": [0, 8]],
            ["dtype": "F32", "shape": [Int.max, 2], "data_offsets": [0, 8]],
            ["dtype": "F32", "shape": [Int.max], "data_offsets": [0, 8]],
            ["dtype": "F32", "shape": [1], "data_offsets": [1, 5]],
            ["dtype": "F32", "shape": [100], "data_offsets": [0, 400]],
            ["dtype": "F32", "shape": [1], "data_offsets": [0]],
            ["dtype": "I8", "shape": [1], "data_offsets": [0, 1]]
        ]
        for metadata in cases {
            let url = try fixture(metadata: ["bad": metadata])
            XCTAssertThrowsError(try TuringQwenNativeSafetensorsReader(
                index: TuringQwenNativeSafetensorsIndex.load(from: url), decoderIO: .positionalReaderCandidate))
        }
        let index = try TuringQwenNativeSafetensorsIndex.load(from: fixture())
        let reader = try TuringQwenNativeSafetensorsReader(index: index, decoderIO: .positionalReaderCandidate)
        XCTAssertThrowsError(try reader.loadRowsFloat32(name: "f32", rows: [-1]))
        XCTAssertThrowsError(try reader.loadRowsFloat32(name: "f32", rows: [3]))
        let file = try TuringQwenNativePositionalSafetensorsFile(
            url: index.fileURL, expectedIdentity: XCTUnwrap(index.fileIdentity))
        XCTAssertThrowsError(try file.readExactly(offset: UInt64.max, count: 4))
        XCTAssertThrowsError(try file.readExactly(offset: 0, count: -1))
        XCTAssertThrowsError(try file.readExactly(offset: UInt64(Int64.max), count: 1))
    }

    func testDescriptorClosesWhenReaderOwnerReleases() throws {
        let index = try TuringQwenNativeSafetensorsIndex.load(from: fixture())
        let fd: Int32 = try autoreleasepool {
            let file = try TuringQwenNativePositionalSafetensorsFile(
                url: index.fileURL, expectedIdentity: XCTUnwrap(index.fileIdentity))
            XCTAssertGreaterThanOrEqual(fcntl(file.descriptor, F_GETFD), 0)
            return file.descriptor
        }
        let result = fcntl(fd, F_GETFD)
        let failure = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(failure, EBADF)
    }

    func testCancelledReadThrowsAndProductionPolicyRemainsLegacy() async throws {
        let index = try TuringQwenNativeSafetensorsIndex.load(from: fixture())
        let reader = try TuringQwenNativeSafetensorsReader(index: index, decoderIO: .positionalReaderCandidate)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try reader.loadTensorFloat32(name: "f32")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled positional reads must fail.")
        } catch is CancellationError {
        }
        XCTAssertEqual(TuringQwenNativeExecutionPolicy.production.decoderIO, .legacy)
        XCTAssertNoThrow(try TuringQwenNativeExecutionPolicy(decoderIO: .positionalReaderCandidate).validateImplemented())
        XCTAssertThrowsError(try TuringQwenNativeExecutionPolicy(decoderIO: .budgetedHotSetCandidate).validateImplemented())
    }
}

private final class FirstReadInterrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true
    func consume() -> Bool {
        lock.withLock {
            let result = pending
            pending = false
            return result
        }
    }
}
