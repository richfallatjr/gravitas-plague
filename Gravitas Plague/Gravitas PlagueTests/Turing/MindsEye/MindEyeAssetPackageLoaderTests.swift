import Foundation
import Metal
import XCTest

@testable import Gravitas_Plague

final class MindEyeAssetPackageLoaderTests: XCTestCase {
    func testAllMetadataPrecedesDeterministicSequentialTextureLoads() async throws {
        let recorder = MindEyePhase2EventRecorder()
        let worker = MindEyeFakeAssetWorker(
            manifest: makeMindEyeTestManifest(),
            recorder: recorder
        )
        let textureLoader = try MindEyeFakeTextureLoader(
            recorder: recorder
        )
        let probe = MindEyeTestMemoryProbe()
        let loader = MindEyeAssetPackageLoader(
            locator: MindEyeResourceLocator(resourceRootURL: URL(fileURLWithPath: "/tmp")),
            worker: worker,
            textureLoader: textureLoader,
            memoryProbe: probe
        )

        let result = await loader.loadPackage(mindEyeMikeVignette())
        let package = try result.get()
        let events = await recorder.values()
        let firstTexture = try XCTUnwrap(events.firstIndex { $0.hasPrefix("texture:") })
        let lastInspection = try XCTUnwrap(events.lastIndex { $0.hasPrefix("inspect:") })
        XCTAssertGreaterThan(firstTexture, lastInspection)
        let maximumConcurrency = await textureLoader.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 1)
        XCTAssertEqual(
            package.allSourceTextures.map(\.metadata.role),
            [
                .background,
                .characterBase,
                .featherMask,
                .eyeOpen(index: 0),
                .eyeClosed(index: 0),
                .mouth(pose: .rest, index: 0),
                .mouth(pose: .small, index: 0),
                .mouth(pose: .wide, index: 0),
                .mouth(pose: .round, index: 0),
                .mouth(pose: .teeth, index: 0)
            ]
        )
        XCTAssertEqual(package.mouths.teeth.count, 1)
        XCTAssertEqual(package.featherMask.colorInterpretation, .linearMask)
        XCTAssertTrue(
            package.allSourceTextures
                .filter { $0.metadata.role != .featherMask }
                .allSatisfy { $0.colorInterpretation == .sRGBColor }
        )
        let labels = await probe.labels()
        XCTAssertTrue(labels.contains("mindseye.package.metadata.begin"))
        XCTAssertTrue(labels.contains("mindseye.package.metadata.complete"))
        XCTAssertEqual(labels.filter { $0 == "mindseye.package.texture.loaded" }.count, 10)
        XCTAssertTrue(labels.contains("mindseye.package.loaded"))
    }

    func testEveryTextureFailurePublishesNoPackage() async throws {
        for failureIndex in 0 ..< 10 {
            let recorder = MindEyePhase2EventRecorder()
            let textureLoader = try MindEyeFakeTextureLoader(
                recorder: recorder,
                failingIndex: failureIndex
            )
            let loader = MindEyeAssetPackageLoader(
                locator: MindEyeResourceLocator(resourceRootURL: URL(fileURLWithPath: "/tmp")),
                worker: MindEyeFakeAssetWorker(
                    manifest: makeMindEyeTestManifest(),
                    recorder: recorder
                ),
                textureLoader: textureLoader
            )
            let result = await loader.loadPackage(mindEyeMikeVignette())
            guard case .failure = result else {
                XCTFail("Texture failure at index \(failureIndex) published a package")
                continue
            }
            let successCount = await textureLoader.successCount()
            XCTAssertEqual(successCount, failureIndex)
        }
    }

    func testCancelledLoadProducesNoPackage() async throws {
        let recorder = MindEyePhase2EventRecorder()
        let loader = MindEyeAssetPackageLoader(
            locator: MindEyeResourceLocator(resourceRootURL: URL(fileURLWithPath: "/tmp")),
            worker: MindEyeFakeAssetWorker(
                manifest: makeMindEyeTestManifest(),
                recorder: recorder
            ),
            textureLoader: try MindEyeFakeTextureLoader(recorder: recorder)
        )
        let task = Task { await loader.loadPackage(mindEyeMikeVignette()) }
        task.cancel()
        let result = await task.value
        guard case .failure(let failure) = result else {
            return XCTFail("Cancelled package load succeeded")
        }
        XCTAssertEqual(failure.code, .cancelled)
    }

    func testPackageConstructionRejectsEmptyTeethArray() throws {
        let core = try makeMindEyeTestGPUTexture(role: .background)
        XCTAssertThrowsError(
            try MindEyeAssetPackage(
                characterID: .bigMike,
                vignetteID: "big_mike_current_room",
                manifest: makeMindEyeTestManifest(),
                background: core,
                characterBase: makeMindEyeTestGPUTexture(role: .characterBase),
                featherMask: makeMindEyeTestGPUTexture(role: .featherMask),
                eyes: MindEyeEyeTextures(
                    open: [try makeMindEyeTestGPUTexture(role: .eyeOpen(index: 0))],
                    closed: [try makeMindEyeTestGPUTexture(role: .eyeClosed(index: 0))]
                ),
                mouths: MindEyeMouthTextures(
                    rest: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .rest, index: 0))],
                    small: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .small, index: 0))],
                    wide: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .wide, index: 0))],
                    round: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .round, index: 0))],
                    teeth: []
                )
            )
        )
    }

    func testBigMikeProductionPackageLoadsWithRealMetalDevice() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Target has no Metal device")
        }
        let locator = MindEyeResourceLocator(
            resourceRootURL: mindEyeProjectRoot()
                .appendingPathComponent("Gravitas Plague/TuringResources")
        )
        let loader = MindEyeAssetPackageLoader(
            locator: locator,
            worker: MindEyeSerialAssetWorker(),
            textureLoader: MindEyeSerialTextureLoader(device: device)
        )
        let result = await loader.loadPackage(mindEyeMikeVignette())
        switch result {
        case .success(let package):
            XCTAssertEqual(package.mouths.teeth.count, 1)
            XCTAssertEqual(package.allSourceTextures.count, 11)
        case .failure(let failure):
            XCTFail("Production package failed: \(failure)")
        }
    }
}

func mindEyeMikeVignette() -> MindEyeResolvedVignette {
    MindEyeResolvedVignette(
        characterID: .bigMike,
        vignetteID: "big_mike_current_room",
        manifestResourcePath: "Turing/MindsEye/Vignettes/big_mike_current_room/manifest.json"
    )
}

actor MindEyePhase2EventRecorder {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func values() -> [String] { events }
}

nonisolated struct MindEyeFakeAssetWorker: MindEyeAssetWorking {
    let manifest: MindEyeVignetteManifest
    let recorder: MindEyePhase2EventRecorder

    func decodeJSON<T>(
        _ type: T.Type,
        from url: URL
    ) async throws -> T where T: Decodable & Sendable {
        await recorder.append("json")
        guard let value = manifest as? T else {
            throw MindEyeFailure(
                code: .manifestInvalid,
                characterID: nil,
                vignetteID: nil,
                resourcePath: nil,
                message: "Unexpected fake JSON type."
            )
        }
        return value
    }

    func inspectPNG(
        at url: URL,
        request: MindEyeImageInspectionRequest
    ) async throws -> MindEyeImageMetadata {
        await recorder.append("inspect:\(request.role)")
        return makeMindEyeTestMetadata(
            role: request.role,
            path: request.resourcePath,
            url: url
        )
    }
}

actor MindEyeFakeTextureLoader: MindEyeTextureLoading {
    private let device: any MTLDevice
    private let recorder: MindEyePhase2EventRecorder
    private let failingIndex: Int?
    private var index = 0
    private var currentConcurrency = 0
    private var maximumConcurrencyValue = 0
    private var successfulLoads = 0

    init(
        recorder: MindEyePhase2EventRecorder,
        failingIndex: Int? = nil
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Target has no Metal device")
        }
        self.device = device
        self.recorder = recorder
        self.failingIndex = failingIndex
    }

    func loadTexture(
        _ request: MindEyeTextureLoadRequest
    ) async throws -> MindEyeGPUTexture {
        let currentIndex = index
        index += 1
        currentConcurrency += 1
        maximumConcurrencyValue = max(maximumConcurrencyValue, currentConcurrency)
        defer { currentConcurrency -= 1 }
        await recorder.append("texture:\(request.metadata.role)")
        if failingIndex == currentIndex {
            throw MindEyeFailure(
                code: .textureLoadFailed,
                characterID: nil,
                vignetteID: nil,
                resourcePath: request.metadata.resourcePath,
                message: "Injected texture failure."
            )
        }
        successfulLoads += 1
        return try makeMindEyeTestGPUTexture(
            role: request.metadata.role,
            metadata: request.metadata,
            colorInterpretation: request.colorInterpretation,
            device: device
        )
    }

    func maximumConcurrency() -> Int { maximumConcurrencyValue }
    func successCount() -> Int { successfulLoads }
}

final class MindEyeTestMemoryProbe:
    MindEyeMemoryProbing,
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "mind-eye-test-memory-probe")
    private var recordedLabels: [String] = []

    func record(
        label: String,
        characterID: TuringConversationCharacterID?,
        vignetteID: String?,
        details: [String: String]
    ) async {
        queue.sync { recordedLabels.append(label) }
    }

    func labels() async -> [String] { queue.sync { recordedLabels } }
}

func makeMindEyeTestMetadata(
    role: MindEyeImageRole,
    path: String? = nil,
    url: URL = URL(fileURLWithPath: "/tmp/fake.png")
) -> MindEyeImageMetadata {
    let isMask = role == .featherMask
    let size = isMask ? MindEyePixelSize.viewport : .source
    return MindEyeImageMetadata(
        role: role,
        resourcePath: path ?? "\(role).png",
        fileURL: url,
        byteCount: 1,
        sha256: String(repeating: "0", count: 64),
        header: MindEyePNGHeader(
            width: size.width,
            height: size.height,
            bitDepth: 8,
            colorType: isMask ? 2 : 6,
            compressionMethod: 0,
            filterMethod: 0,
            interlaceMethod: 0
        ),
        alphaMinimum: isMask ? nil : 0,
        alphaMaximum: isMask ? nil : 255,
        nonzeroAlphaPixelCount: isMask ? nil : 1,
        transparentPixelCount: isMask ? nil : 1,
        luminanceMinimum: isMask ? 0 : nil,
        luminanceMaximum: isMask ? 255 : nil,
        distinctLuminanceCount: isMask ? 16 : nil
    )
}

func makeMindEyeTestGPUTexture(
    role: MindEyeImageRole,
    metadata: MindEyeImageMetadata? = nil,
    colorInterpretation: MindEyeTextureColorInterpretation? = nil,
    device suppliedDevice: (any MTLDevice)? = nil
) throws -> MindEyeGPUTexture {
    guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Target has no Metal device")
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: 1,
        height: 1,
        mipmapped: false
    )
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw MindEyeFailure(
            code: .textureLoadFailed,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: "Test texture allocation failed."
        )
    }
    let resolvedMetadata = metadata ?? makeMindEyeTestMetadata(role: role)
    return MindEyeGPUTexture(
        texture: texture,
        metadata: resolvedMetadata,
        colorInterpretation: colorInterpretation ?? (role == .featherMask ? .linearMask : .sRGBColor)
    )
}

func makeMindEyeTestPackage(
    characterID: TuringConversationCharacterID = .bigMike,
    vignetteID: String = "big_mike_current_room"
) throws -> MindEyeAssetPackage {
    let manifest = makeMindEyeTestManifest(
        characterID: characterID,
        vignetteID: vignetteID
    )
    return try MindEyeAssetPackage(
        characterID: characterID,
        vignetteID: vignetteID,
        manifest: manifest,
        background: makeMindEyeTestGPUTexture(role: .background),
        characterBase: makeMindEyeTestGPUTexture(role: .characterBase),
        featherMask: makeMindEyeTestGPUTexture(role: .featherMask),
        eyes: MindEyeEyeTextures(
            open: [try makeMindEyeTestGPUTexture(role: .eyeOpen(index: 0))],
            closed: [try makeMindEyeTestGPUTexture(role: .eyeClosed(index: 0))]
        ),
        mouths: MindEyeMouthTextures(
            rest: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .rest, index: 0))],
            small: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .small, index: 0))],
            wide: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .wide, index: 0))],
            round: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .round, index: 0))],
            teeth: [try makeMindEyeTestGPUTexture(role: .mouth(pose: .teeth, index: 0))]
        )
    )
}
