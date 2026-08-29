import Foundation
import Metal

nonisolated protocol MindEyeAssetPackageLoading: Sendable {
    func loadPackage(
        _ vignette: MindEyeResolvedVignette
    ) async -> Result<MindEyeAssetPackage, MindEyeFailure>
}

nonisolated protocol MindEyeMemoryProbing: Sendable {
    func record(
        label: String,
        characterID: TuringConversationCharacterID?,
        vignetteID: String?,
        details: [String: String]
    ) async
}

actor TuringMindEyeMemoryProbe: MindEyeMemoryProbing {
    func record(
        label: String,
        characterID: TuringConversationCharacterID?,
        vignetteID: String?,
        details: [String: String]
    ) async {
        let enriched = details.merging(
            [
                "mindEyeCharacterID": characterID?.rawValue ?? "none",
                "mindEyeVignetteID": vignetteID ?? "none"
            ],
            uniquingKeysWith: { current, _ in current }
        )
        await MainActor.run {
            TuringMemoryBudgetProbe.log(label: label, details: enriched)
        }
    }
}

nonisolated struct MindEyeNoopMemoryProbe: MindEyeMemoryProbing {
    func record(
        label: String,
        characterID: TuringConversationCharacterID?,
        vignetteID: String?,
        details: [String: String]
    ) async {}
}

actor MindEyeAssetPackageLoader: MindEyeAssetPackageLoading {
    private let locator: MindEyeResourceLocator
    private let worker: any MindEyeAssetWorking
    private let textureLoader: any MindEyeTextureLoading
    private let memoryProbe: any MindEyeMemoryProbing

    init(
        locator: MindEyeResourceLocator,
        worker: any MindEyeAssetWorking,
        textureLoader: any MindEyeTextureLoading,
        memoryProbe: any MindEyeMemoryProbing = MindEyeNoopMemoryProbe()
    ) {
        self.locator = locator
        self.worker = worker
        self.textureLoader = textureLoader
        self.memoryProbe = memoryProbe
    }

    func loadPackage(
        _ vignette: MindEyeResolvedVignette
    ) async -> Result<MindEyeAssetPackage, MindEyeFailure> {
        do {
            try Task.checkCancellation()
            await memoryProbe.record(
                label: "mindseye.package.metadata.begin",
                characterID: vignette.characterID,
                vignetteID: vignette.vignetteID,
                details: [:]
            )
            let prepared = try await prepareMetadata(vignette)
            try Task.checkCancellation()
            let requests = prepared.orderedTextureRequests
            let estimatedBytes = requests.reduce(UInt64.zero) { partial, request in
                let width = UInt64(request.metadata.header.width)
                let height = UInt64(request.metadata.header.height)
                return partial + width * height * 4
            }
            await memoryProbe.record(
                label: "mindseye.package.metadata.complete",
                characterID: vignette.characterID,
                vignetteID: vignette.vignetteID,
                details: [
                    "sourceTextureCount": String(requests.count),
                    "estimatedResidentSourceBytes": String(estimatedBytes)
                ]
            )

            var loaded: [MindEyeImageRole: MindEyeGPUTexture] = [:]
            loaded.reserveCapacity(requests.count)
            for (index, request) in requests.enumerated() {
                try Task.checkCancellation()
                let texture = try await textureLoader.loadTexture(request)
                try Task.checkCancellation()
                guard loaded.updateValue(texture, forKey: request.metadata.role) == nil else {
                    throw failure(
                        .packageConstructionFailed,
                        vignette: vignette,
                        path: request.metadata.resourcePath,
                        message: "Texture role was loaded more than once."
                    )
                }
                await memoryProbe.record(
                    label: "mindseye.package.texture.loaded",
                    characterID: vignette.characterID,
                    vignetteID: vignette.vignetteID,
                    details: [
                        "textureIndex": String(index),
                        "resourcePath": request.metadata.resourcePath,
                        "width": String(texture.texture.width),
                        "height": String(texture.texture.height),
                        "pixelFormat": String(texture.texture.pixelFormat.rawValue),
                        "storageMode": String(texture.texture.storageMode.rawValue)
                    ]
                )
            }
            try Task.checkCancellation()
            let package = try assemble(prepared: prepared, loaded: loaded)
            await memoryProbe.record(
                label: "mindseye.package.loaded",
                characterID: vignette.characterID,
                vignetteID: vignette.vignetteID,
                details: [
                    "sourceTextureCount": String(package.allSourceTextures.count),
                    "estimatedResidentSourceBytes": String(package.estimatedResidentSourceBytes)
                ]
            )
            return .success(package)
        } catch is CancellationError {
            return .failure(
                failure(
                    .cancelled,
                    vignette: vignette,
                    path: nil,
                    message: "Mind's Eye package load was cancelled."
                )
            )
        } catch let error as MindEyeFailure {
            return .failure(
                MindEyeFailure(
                    code: error.code,
                    characterID: error.characterID ?? vignette.characterID,
                    vignetteID: error.vignetteID ?? vignette.vignetteID,
                    resourcePath: error.resourcePath,
                    message: error.message
                )
            )
        } catch {
            return .failure(
                failure(
                    .packageConstructionFailed,
                    vignette: vignette,
                    path: nil,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func prepareMetadata(
        _ vignette: MindEyeResolvedVignette
    ) async throws -> MindEyePreparedPackageMetadata {
        let manifestURL: URL
        do {
            manifestURL = try locator.resolve(
                resourcePath: vignette.manifestResourcePath
            )
        } catch {
            throw failure(.manifestMissing, vignette: vignette, path: vignette.manifestResourcePath, message: "Manifest could not be resolved.")
        }
        let manifest: MindEyeVignetteManifest
        do {
            manifest = try await worker.decodeJSON(
                MindEyeVignetteManifest.self,
                from: manifestURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure(.manifestInvalid, vignette: vignette, path: vignette.manifestResourcePath, message: "Manifest could not be decoded: \(error.localizedDescription)")
        }

        let validationIssues = MindEyeVignetteManifestValidator.issues(
            manifest: manifest,
            expectedVignetteID: vignette.vignetteID,
            expectedCharacterID: vignette.characterID
        )
        guard validationIssues.isEmpty else {
            let missingTeeth = validationIssues.contains { $0.code == .missingMouthTeeth }
            throw failure(
                missingTeeth ? .missingRequiredPose : .manifestInvalid,
                vignette: vignette,
                path: vignette.manifestResourcePath,
                message: validationIssues.map(\.message).joined(separator: " ")
            )
        }

        let packageRoot = manifestURL.deletingLastPathComponent()
        let plans = inspectionPlans(manifest)
        var inspected: [MindEyeImageRole: MindEyeImageMetadata] = [:]
        inspected.reserveCapacity(plans.count)
        for plan in plans {
            try Task.checkCancellation()
            let url = if plan.resourcePath.contains("/") {
                try locator.resolve(resourcePath: plan.resourcePath)
            } else {
                try locator.resolve(
                    resourcePath: plan.resourcePath,
                    under: packageRoot
                )
            }
            let metadata = try await worker.inspectPNG(at: url, request: plan)
            try Task.checkCancellation()
            guard inspected.updateValue(metadata, forKey: plan.role) == nil else {
                throw failure(.manifestInvalid, vignette: vignette, path: plan.resourcePath, message: "Manifest produced a duplicate semantic texture role.")
            }
        }

        func require(_ role: MindEyeImageRole) throws -> MindEyeImageMetadata {
            guard let value = inspected[role] else {
                throw failure(.packageConstructionFailed, vignette: vignette, path: nil, message: "Validated metadata is missing role \(role).")
            }
            return value
        }
        let mouthMetadata = try Dictionary(
            uniqueKeysWithValues: MindEyeMouthPose.allCases.map { pose in
                let count = manifest.layers.mouths.files(for: pose).count
                return (pose, try (0 ..< count).map { index in
                    try require(.mouth(pose: pose, index: index))
                })
            }
        )
        return try MindEyePreparedPackageMetadata(
            resolvedVignette: vignette,
            manifest: manifest,
            background: require(.background),
            characterBase: require(.characterBase),
            featherMask: require(.featherMask),
            eyeOpen: (0 ..< manifest.layers.eyes.open.count).map {
                try require(.eyeOpen(index: $0))
            },
            eyeClosed: (0 ..< manifest.layers.eyes.closed.count).map {
                try require(.eyeClosed(index: $0))
            },
            mouths: mouthMetadata
        )
    }

    private nonisolated func inspectionPlans(
        _ manifest: MindEyeVignetteManifest
    ) -> [MindEyeImageInspectionRequest] {
        var plans = [
            MindEyeImageInspectionRequest(
                role: .background,
                resourcePath: manifest.layers.background,
                expectedSize: .source,
                semanticRule: .opaqueRGBA
            ),
            MindEyeImageInspectionRequest(
                role: .characterBase,
                resourcePath: manifest.layers.characterBase,
                expectedSize: .source,
                semanticRule: .nonemptyRGBAOverlay
            ),
            MindEyeImageInspectionRequest(
                role: .featherMask,
                resourcePath: manifest.layers.featherMask,
                expectedSize: .viewport,
                semanticRule: .grayscaleRGBMask
            )
        ]
        plans += manifest.layers.eyes.open.enumerated().map {
            MindEyeImageInspectionRequest(
                role: .eyeOpen(index: $0.offset),
                resourcePath: $0.element,
                expectedSize: .source,
                semanticRule: .nonemptyRGBAOverlay
            )
        }
        plans += manifest.layers.eyes.closed.enumerated().map {
            MindEyeImageInspectionRequest(
                role: .eyeClosed(index: $0.offset),
                resourcePath: $0.element,
                expectedSize: .source,
                semanticRule: .nonemptyRGBAOverlay
            )
        }
        for pose in MindEyeMouthPose.allCases {
            plans += manifest.layers.mouths.files(for: pose).enumerated().map {
                MindEyeImageInspectionRequest(
                    role: .mouth(pose: pose, index: $0.offset),
                    resourcePath: $0.element,
                    expectedSize: .source,
                    semanticRule: .nonemptyRGBAOverlay
                )
            }
        }
        return plans
    }

    private nonisolated func assemble(
        prepared: MindEyePreparedPackageMetadata,
        loaded: [MindEyeImageRole: MindEyeGPUTexture]
    ) throws -> MindEyeAssetPackage {
        let vignette = prepared.resolvedVignette
        func require(_ role: MindEyeImageRole) throws -> MindEyeGPUTexture {
            guard let value = loaded[role] else {
                throw failure(.packageConstructionFailed, vignette: vignette, path: nil, message: "Loaded texture is missing role \(role).")
            }
            return value
        }
        func mouth(_ pose: MindEyeMouthPose) throws -> [MindEyeGPUTexture] {
            try (0 ..< prepared.manifest.layers.mouths.files(for: pose).count).map {
                try require(.mouth(pose: pose, index: $0))
            }
        }
        return try MindEyeAssetPackage(
            characterID: vignette.characterID,
            vignetteID: vignette.vignetteID,
            manifest: prepared.manifest,
            background: require(.background),
            characterBase: require(.characterBase),
            featherMask: require(.featherMask),
            eyes: MindEyeEyeTextures(
                open: (0 ..< prepared.manifest.layers.eyes.open.count).map {
                    try require(.eyeOpen(index: $0))
                },
                closed: (0 ..< prepared.manifest.layers.eyes.closed.count).map {
                    try require(.eyeClosed(index: $0))
                }
            ),
            mouths: MindEyeMouthTextures(
                rest: mouth(.rest),
                small: mouth(.small),
                wide: mouth(.wide),
                round: mouth(.round),
                teeth: mouth(.teeth)
            )
        )
    }

    private nonisolated func failure(
        _ code: MindEyeFailureCode,
        vignette: MindEyeResolvedVignette,
        path: String?,
        message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: code,
            characterID: vignette.characterID,
            vignetteID: vignette.vignetteID,
            resourcePath: path,
            message: message
        )
    }
}
