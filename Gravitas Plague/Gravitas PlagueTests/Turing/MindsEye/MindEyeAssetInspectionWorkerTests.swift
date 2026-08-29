import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeAssetInspectionWorkerTests: XCTestCase {
    @MainActor
    func testInspectionRunsOffMainOnOneSerialQueue() async throws {
        let meter = MindEyeWorkerConcurrencyMeter()
        let worker = MindEyeSerialAssetWorker { observation in
            meter.enter(observation)
            Thread.sleep(forTimeInterval: 0.01)
            meter.leave()
        }
        let url = mindEyeProductionVignetteRoot()
            .appendingPathComponent("background.png")
        let request = MindEyeImageInspectionRequest(
            role: .background,
            resourcePath: "background.png",
            expectedSize: .source,
            semanticRule: .opaqueRGBA
        )

        async let first = worker.inspectPNG(at: url, request: request)
        async let second = worker.inspectPNG(at: url, request: request)
        async let third = worker.inspectPNG(at: url, request: request)
        _ = try await (first, second, third)

        let snapshot = meter.snapshot()
        XCTAssertEqual(snapshot.maximumConcurrency, 1)
        XCTAssertEqual(snapshot.observations.count, 3)
        XCTAssertTrue(snapshot.observations.allSatisfy { !$0.isMainThread })
        XCTAssertTrue(snapshot.observations.allSatisfy(\.queueVerified))
    }

    func testProductionRGBAHeadersAndSemanticContentValidate() async throws {
        let worker = MindEyeSerialAssetWorker()
        let root = mindEyeProductionVignetteRoot()
        let fixtures: [(String, MindEyeImageRole, MindEyeImageSemanticRule)] = [
            ("background.png", .background, .opaqueRGBA),
            ("character-base.png", .characterBase, .nonemptyRGBAOverlay),
            ("eyes-open-01.png", .eyeOpen(index: 0), .nonemptyRGBAOverlay),
            ("mouth-teeth-01.png", .mouth(pose: .teeth, index: 0), .nonemptyRGBAOverlay)
        ]
        for (file, role, rule) in fixtures {
            let metadata = try await worker.inspectPNG(
                at: root.appendingPathComponent(file),
                request: MindEyeImageInspectionRequest(
                    role: role,
                    resourcePath: file,
                    expectedSize: .source,
                    semanticRule: rule
                )
            )
            XCTAssertEqual(metadata.header.width, 2_304)
            XCTAssertEqual(metadata.header.height, 1_296)
            XCTAssertEqual(metadata.header.bitDepth, 8)
            XCTAssertEqual(metadata.header.colorType, 6)
            XCTAssertFalse(metadata.sha256.isEmpty)
        }
    }

    func testSHAIsStableAndZeroByteFileFails() async throws {
        let worker = MindEyeSerialAssetWorker()
        let url = mindEyeProductionVignetteRoot()
            .appendingPathComponent("mouth-rest-01.png")
        let request = MindEyeImageInspectionRequest(
            role: .mouth(pose: .rest, index: 0),
            resourcePath: "mouth-rest-01.png",
            expectedSize: .source,
            semanticRule: .nonemptyRGBAOverlay
        )
        let first = try await worker.inspectPNG(at: url, request: request)
        let second = try await worker.inspectPNG(at: url, request: request)
        XCTAssertEqual(first.sha256, second.sha256)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        do {
            _ = try await worker.inspectPNG(at: empty, request: request)
            XCTFail("Zero-byte source unexpectedly validated")
        } catch let failure as MindEyeFailure {
            XCTAssertEqual(failure.code, .assetZeroBytes)
        }
    }
}

private nonisolated final class MindEyeWorkerConcurrencyMeter: @unchecked Sendable {
    struct Snapshot {
        let maximumConcurrency: Int
        let observations: [MindEyeWorkerExecutionObservation]
    }

    private let lock = NSLock()
    private var current = 0
    private var maximum = 0
    private var observations: [MindEyeWorkerExecutionObservation] = []

    func enter(_ observation: MindEyeWorkerExecutionObservation) {
        lock.lock()
        current += 1
        maximum = max(maximum, current)
        observations.append(observation)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            maximumConcurrency: maximum,
            observations: observations
        )
    }
}

func mindEyeProductionVignetteRoot() -> URL {
    mindEyeProjectRoot().appendingPathComponent(
        "Gravitas Plague/TuringResources/Turing/MindsEye/Vignettes/big_mike_current_room",
        isDirectory: true
    )
}
