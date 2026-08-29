import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeCatalogStoreTests: XCTestCase {
    func testShippedCatalogResolvesBigMikeAndCatEye81() async {
        let resources = mindEyeProjectRoot()
            .appendingPathComponent("Gravitas Plague/TuringResources", isDirectory: true)
        let store = MindEyeCatalogStore(
            locator: MindEyeResourceLocator(resourceRootURL: resources),
            worker: MindEyeSerialAssetWorker()
        )

        let mike = await store.defaultVignette(for: .bigMike)
        let catEye = await store.defaultVignette(for: .catEye81)

        XCTAssertEqual(mike?.vignetteID, "big_mike_current_room")
        XCTAssertEqual(catEye?.vignetteID, "cateye81_bunker")
        XCTAssertEqual(catEye?.characterID, .catEye81)
    }

    func testValidBigMikeResolutionAndNoRichFallback() async throws {
        let fixture = try MindEyeCatalogFixture.make(
            descriptor: validCatalog()
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = MindEyeCatalogStore(
            locator: MindEyeResourceLocator(resourceRootURL: fixture.root),
            worker: MindEyeSerialAssetWorker()
        )

        let mike = await store.defaultVignette(for: .bigMike)
        let rich = await store.defaultVignette(for: .rich)
        XCTAssertEqual(mike?.vignetteID, "big_mike_current_room")
        XCTAssertEqual(mike?.characterID, .bigMike)
        XCTAssertNil(rich)
    }

    func testInvalidCatalogFormsAreRejected() async throws {
        let invalidDescriptors = [
            MindEyeCatalogDescriptor(schemaVersion: 2, entries: validCatalog().entries),
            MindEyeCatalogDescriptor(
                schemaVersion: 1,
                entries: [validCatalog().entries[0], validCatalog().entries[0]]
            ),
            MindEyeCatalogDescriptor(
                schemaVersion: 1,
                entries: [
                    .init(
                        characterID: .bigMike,
                        defaultVignetteID: "missing",
                        vignettes: validCatalog().entries[0].vignettes
                    )
                ]
            ),
            MindEyeCatalogDescriptor(
                schemaVersion: 1,
                entries: [
                    .init(
                        characterID: .bigMike,
                        defaultVignetteID: "big_mike_current_room",
                        vignettes: [
                            .init(
                                vignetteID: "big_mike_current_room",
                                manifestResourcePath: "../manifest.json"
                            )
                        ]
                    )
                ]
            )
        ]

        for descriptor in invalidDescriptors {
            let fixture = try MindEyeCatalogFixture.make(descriptor: descriptor)
            let store = MindEyeCatalogStore(
                locator: MindEyeResourceLocator(resourceRootURL: fixture.root),
                worker: MindEyeSerialAssetWorker()
            )
            let result = await store.defaultVignette(for: .bigMike)
            XCTAssertNil(result)
            try? FileManager.default.removeItem(at: fixture.root)
        }
    }

    func testConcurrentReadsDecodeOnce() async throws {
        let fixture = try MindEyeCatalogFixture.make(descriptor: validCatalog())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let counter = MindEyeCatalogDecodeCounter()
        let worker = MindEyeCountingAssetWorker(
            base: MindEyeSerialAssetWorker(),
            counter: counter
        )
        let store = MindEyeCatalogStore(
            locator: MindEyeResourceLocator(resourceRootURL: fixture.root),
            worker: worker
        )
        async let first = store.defaultVignette(for: .bigMike)
        async let second = store.defaultVignette(for: .bigMike)
        async let third = store.defaultVignette(for: .rich)
        _ = await (first, second, third)
        let decodeCount = await counter.value()
        XCTAssertEqual(decodeCount, 1)
    }

    private func validCatalog() -> MindEyeCatalogDescriptor {
        MindEyeCatalogDescriptor(
            schemaVersion: 1,
            entries: [
                .init(
                    characterID: .bigMike,
                    defaultVignetteID: "big_mike_current_room",
                    vignettes: [
                        .init(
                            vignetteID: "big_mike_current_room",
                            manifestResourcePath: "Turing/MindsEye/Vignettes/big_mike_current_room/manifest.json"
                        )
                    ]
                )
            ]
        )
    }
}

private struct MindEyeCatalogFixture {
    let root: URL

    static func make(
        descriptor: MindEyeCatalogDescriptor
    ) throws -> MindEyeCatalogFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let catalog = root.appendingPathComponent("Turing/MindsEye/catalog.json")
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(descriptor).write(to: catalog)
        return MindEyeCatalogFixture(root: root)
    }
}

private actor MindEyeCatalogDecodeCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private nonisolated final class MindEyeCountingAssetWorker:
    @unchecked Sendable,
    MindEyeAssetWorking
{
    let base: any MindEyeAssetWorking
    let counter: MindEyeCatalogDecodeCounter

    init(base: any MindEyeAssetWorking, counter: MindEyeCatalogDecodeCounter) {
        self.base = base
        self.counter = counter
    }

    func decodeJSON<T>(
        _ type: T.Type,
        from url: URL
    ) async throws -> T where T: Decodable & Sendable {
        await counter.increment()
        return try await base.decodeJSON(type, from: url)
    }

    func inspectPNG(
        at url: URL,
        request: MindEyeImageInspectionRequest
    ) async throws -> MindEyeImageMetadata {
        try await base.inspectPNG(at: url, request: request)
    }
}
