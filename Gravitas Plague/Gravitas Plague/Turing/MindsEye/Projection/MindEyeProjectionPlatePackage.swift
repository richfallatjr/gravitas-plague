import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Metal
import MetalKit

nonisolated struct MindEyeProjectionPlateManifest: Codable, Sendable, Equatable {
    struct Layer: Codable, Sendable, Equatable {
        let filename: String
        let sha256: String

        private enum CodingKeys: String, CodingKey {
            case filename
            case sha256 = "SHA256"
        }
    }

    struct Eyes: Codable, Sendable, Equatable {
        let open: [Layer]
        let closed: [Layer]
    }

    struct Mouths: Codable, Sendable, Equatable {
        let rest: [Layer]
        let small: [Layer]
        let wide: [Layer]
        let round: [Layer]
        let teeth: [Layer]

        func layers(for pose: MindEyeMouthPose) -> [Layer] {
            switch pose {
            case .rest: rest
            case .small: small
            case .wide: wide
            case .round: round
            case .teeth: teeth
            }
        }
    }

    let schemaVersion: Int
    let packageID: String
    let profileID: String
    let profileSHA256: String
    let cameraID: String
    let cameraSHA256: String
    let targetSHA256: String
    let subjectAssetName: String
    let subjectAssetSHA256: String
    let sceneLightingRevision: String
    let sourceWidth: Int
    let sourceHeight: Int
    let viewportWidth: Int
    let viewportHeight: Int
    let cropOriginX: Int
    let cropOriginY: Int
    let colorSpace: String
    let compositeAlphaSemantics: String
    let projectionBase: Layer
    let eyes: Eyes
    let mouths: Mouths

    func validate(profile: MindEyeProjectionProfile) throws {
        let layerFamilies = [eyes.open, eyes.closed] +
            MindEyeMouthPose.allCases.map(mouths.layers(for:))
        let layers = [projectionBase] + layerFamilies.flatMap { $0 }
        guard schemaVersion == 2,
              packageID == "angel_head_v1",
              profileID == profile.profileID,
              cameraID == "angel_head_v1.camera",
              subjectAssetName == profile.subjectAssetName,
              sceneLightingRevision == profile.sceneContentRevision,
              sourceWidth == profile.sourceWidth,
              sourceHeight == profile.sourceHeight,
              viewportWidth == profile.viewportWidth,
              viewportHeight == profile.viewportHeight,
              cropOriginX == profile.cropOriginX,
              cropOriginY == profile.cropOriginY,
              colorSpace == "sRGB",
              compositeAlphaSemantics == "sourceOverOnly",
              layerFamilies.allSatisfy({ !$0.isEmpty }),
              layers.allSatisfy({
                  Self.validFilename($0.filename) && Self.validSHA($0.sha256)
              }),
              Self.validSHA(profileSHA256),
              Self.validSHA(cameraSHA256),
              Self.validSHA(targetSHA256),
              Self.validSHA(subjectAssetSHA256) else {
            throw MindEyeProjectionError.invalidPlateManifest(
                "identity, dimensions, or required pose families are invalid"
            )
        }
        let names = layers.map(\.filename)
        guard Set(names).count == names.count else {
            throw MindEyeProjectionError.invalidPlateManifest(
                "a plate filename appears more than once"
            )
        }
    }

    private static func validFilename(_ value: String) -> Bool {
        !value.isEmpty &&
            value == (value as NSString).lastPathComponent &&
            (value as NSString).pathExtension.lowercased() == "png"
    }

    private static func validSHA(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

nonisolated final class MindEyeProjectionPlateTexture: @unchecked Sendable {
    let texture: any MTLTexture
    let filename: String
    let sha256: String

    init(texture: any MTLTexture, filename: String, sha256: String) {
        self.texture = texture
        self.filename = filename
        self.sha256 = sha256
    }
}

nonisolated final class MindEyeProjectionPlatePackage: @unchecked Sendable {
    let profile: MindEyeProjectionProfile
    let camera: MindEyeProjectionCameraDescriptor
    let target: MindEyeProjectionTargetDescriptor
    let importedPBRContract: MindEyeProjectionImportedPBRContract
    let importedPBRContractSHA256: String
    let materialParityQualification: MindEyeProjectionMaterialParityQualification
    let materialParityQualificationSHA256: String
    let manifest: MindEyeProjectionPlateManifest
    let projectionBase: MindEyeProjectionPlateTexture
    let eyeOpen: [MindEyeProjectionPlateTexture]
    let eyeClosed: [MindEyeProjectionPlateTexture]
    let mouths: [MindEyeMouthPose: [MindEyeProjectionPlateTexture]]
    let estimatedPlateResidentBytes: UInt64

    init(
        profile: MindEyeProjectionProfile,
        camera: MindEyeProjectionCameraDescriptor,
        target: MindEyeProjectionTargetDescriptor,
        importedPBRContract: MindEyeProjectionImportedPBRContract,
        importedPBRContractSHA256: String,
        materialParityQualification: MindEyeProjectionMaterialParityQualification,
        materialParityQualificationSHA256: String,
        manifest: MindEyeProjectionPlateManifest,
        projectionBase: MindEyeProjectionPlateTexture,
        eyeOpen: [MindEyeProjectionPlateTexture],
        eyeClosed: [MindEyeProjectionPlateTexture],
        mouths: [MindEyeMouthPose: [MindEyeProjectionPlateTexture]]
    ) throws {
        guard !eyeOpen.isEmpty, !eyeClosed.isEmpty,
              MindEyeMouthPose.allCases.allSatisfy({ !(mouths[$0] ?? []).isEmpty }) else {
            throw MindEyeProjectionError.invalidPlateManifest(
                "the immutable package lost a required pose family"
            )
        }
        self.profile = profile
        self.camera = camera
        self.target = target
        self.importedPBRContract = importedPBRContract
        self.importedPBRContractSHA256 = importedPBRContractSHA256
        self.materialParityQualification = materialParityQualification
        self.materialParityQualificationSHA256 = materialParityQualificationSHA256
        self.manifest = manifest
        self.projectionBase = projectionBase
        self.eyeOpen = eyeOpen
        self.eyeClosed = eyeClosed
        self.mouths = mouths
        let all = [projectionBase] + eyeOpen + eyeClosed +
            MindEyeMouthPose.allCases.flatMap { mouths[$0] ?? [] }
        estimatedPlateResidentBytes = all.reduce(0) { total, item in
            total + UInt64(item.texture.width * item.texture.height * 4)
        }
    }
}

nonisolated final class MindEyeProjectionPlatePackageLoader: @unchecked Sendable {
    enum QualificationPolicy: Sendable, Equatable {
        case requirePassingResource
        case allowUnqualifiedAuthoringRun
    }
    private struct PNGHeader {
        let width: Int
        let height: Int
        let bitDepth: Int
        let colorType: Int
    }

    private enum Semantic {
        case opaqueBase
        case transparentOverlay
    }

    private struct ValidatedLayer {
        let descriptor: MindEyeProjectionPlateManifest.Layer
        let url: URL
    }

    private let device: any MTLDevice
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1

    init(
        device: any MTLDevice,
        label: String = "com.gravitas.plague.mindseye.angel-projection-loader"
    ) {
        self.device = device
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    func load(
        locator: MindEyeResourceLocator,
        profileResourcePath: String,
        qualificationPolicy: QualificationPolicy = .requirePassingResource
    ) async throws -> MindEyeProjectionPlatePackage {
        try Task.checkCancellation()
        let value: MindEyeProjectionPlatePackage = try await withCheckedThrowingContinuation {
            continuation in
            queue.async { [self] in
                dispatchPrecondition(condition: .notOnQueue(.main))
                precondition(DispatchQueue.getSpecific(key: queueKey) == queueValue)
                precondition(!Thread.isMainThread)
                continuation.resume(with: autoreleasepool {
                    Result {
                        try loadOnWorker(
                            locator: locator,
                            profileResourcePath: profileResourcePath,
                            qualificationPolicy: qualificationPolicy
                        )
                    }
                })
            }
        }
        try Task.checkCancellation()
        return value
    }

    private func loadOnWorker(
        locator: MindEyeResourceLocator,
        profileResourcePath: String,
        qualificationPolicy: QualificationPolicy
    ) throws -> MindEyeProjectionPlatePackage {
        let profileURL = try locator.resolve(resourcePath: profileResourcePath)
        let (profileData, profileHash) = try dataAndHash(profileURL)
        let profile = try JSONDecoder().decode(
            MindEyeProjectionProfile.self,
            from: profileData
        )
        try profile.validate()

        let cameraURL = try locator.resolve(resourcePath: profile.cameraResourcePath)
        let (cameraData, cameraHash) = try dataAndHash(cameraURL)
        let camera = try JSONDecoder().decode(
            MindEyeProjectionCameraDescriptor.self,
            from: cameraData
        )
        try camera.validate()

        let targetURL = try locator.resolve(resourcePath: profile.targetResourcePath)
        let (targetData, targetHash) = try dataAndHash(targetURL)
        let target = try JSONDecoder().decode(
            MindEyeProjectionTargetDescriptor.self,
            from: targetData
        )
        try target.validate()

        let contractURL = try locator.resolve(
            resourcePath: profile.importedPBRContractResourcePath
        )
        let (contractData, contractHash) = try dataAndHash(contractURL)
        let contract = try JSONDecoder().decode(
            MindEyeProjectionImportedPBRContract.self,
            from: contractData
        )
        try contract.validate(profile: profile, target: target)

        let manifestURL = try locator.resolve(
            resourcePath: profile.plateManifestResourcePath
        )
        let (manifestData, _) = try dataAndHash(manifestURL)
        let manifest = try JSONDecoder().decode(
            MindEyeProjectionPlateManifest.self,
            from: manifestData
        )
        try manifest.validate(profile: profile)

        guard manifest.profileSHA256 == profileHash,
              manifest.cameraSHA256 == cameraHash,
              manifest.targetSHA256 == targetHash,
              camera.subjectAssetSHA256 == manifest.subjectAssetSHA256,
              camera.targetDescriptorSHA256 == targetHash else {
            throw MindEyeProjectionError.hashMismatch("profile/camera/target identity")
        }
        let subjectURL = try locator.resolve(resourcePath: manifest.subjectAssetName)
        let (_, subjectHash) = try dataAndHash(subjectURL)
        guard subjectHash == manifest.subjectAssetSHA256 else {
            throw MindEyeProjectionError.hashMismatch("subject asset")
        }
        guard contract.subjectAssetSHA256 == subjectHash else {
            throw MindEyeProjectionError.hashMismatch("PBR contract subject asset")
        }

        let qualificationURL = try locator.resolve(
            resourcePath: profile.materialParityQualificationResourcePath
        )
        let (qualificationData, qualificationHash) = try dataAndHash(qualificationURL)
        let qualification = try JSONDecoder().decode(
            MindEyeProjectionMaterialParityQualification.self,
            from: qualificationData
        )
        if qualificationPolicy == .requirePassingResource {
            try qualification.validate(identities: .init(
                subjectAssetSHA256: subjectHash,
                profileSHA256: profileHash,
                cameraSHA256: cameraHash,
                targetSHA256: targetHash,
                importedPBRContractSHA256: contractHash
            ))
        }

        let packageDirectory = manifestURL.deletingLastPathComponent()
        let base = try validate(
            manifest.projectionBase,
            under: packageDirectory,
            semantic: .opaqueBase
        )
        let open = try manifest.eyes.open.map {
            try validate($0, under: packageDirectory, semantic: .transparentOverlay)
        }
        let closed = try manifest.eyes.closed.map {
            try validate($0, under: packageDirectory, semantic: .transparentOverlay)
        }
        var mouthLayers: [MindEyeMouthPose: [ValidatedLayer]] = [:]
        for pose in MindEyeMouthPose.allCases {
            mouthLayers[pose] = try manifest.mouths.layers(for: pose).map {
                try validate($0, under: packageDirectory, semantic: .transparentOverlay)
            }
        }
        // All JSON, hashes, headers, alpha scans, and identities are valid before
        // source texture zero is allocated. Textures then upload strictly one at a time.
        let textureLoader = MTKTextureLoader(device: device)
        let baseTexture = try loadTexture(base, loader: textureLoader, sRGB: true)
        let openTextures = try open.map { try loadTexture($0, loader: textureLoader, sRGB: true) }
        let closedTextures = try closed.map { try loadTexture($0, loader: textureLoader, sRGB: true) }
        var mouthTextures: [MindEyeMouthPose: [MindEyeProjectionPlateTexture]] = [:]
        for pose in MindEyeMouthPose.allCases {
            mouthTextures[pose] = try (mouthLayers[pose] ?? []).map {
                try loadTexture($0, loader: textureLoader, sRGB: true)
            }
        }
        return try MindEyeProjectionPlatePackage(
            profile: profile,
            camera: camera,
            target: target,
            importedPBRContract: contract,
            importedPBRContractSHA256: contractHash,
            materialParityQualification: qualification,
            materialParityQualificationSHA256: qualificationHash,
            manifest: manifest,
            projectionBase: baseTexture,
            eyeOpen: openTextures,
            eyeClosed: closedTextures,
            mouths: mouthTextures
        )
    }

    private func validate(
        _ layer: MindEyeProjectionPlateManifest.Layer,
        under directory: URL,
        semantic: Semantic
    ) throws -> ValidatedLayer {
        let url = directory.appendingPathComponent(layer.filename).standardizedFileURL
        let root = directory.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root) else {
            throw MindEyeProjectionError.invalidPlateManifest("plate escaped package directory")
        }
        let hash = try inspectPNG(
            at: url,
            expectedWidth: 1_728,
            expectedHeight: 1_728,
            semantic: semantic
        )
        guard hash == layer.sha256 else {
            throw MindEyeProjectionError.hashMismatch(layer.filename)
        }
        return ValidatedLayer(descriptor: layer, url: url)
    }

    private func inspectPNG(
        at url: URL,
        expectedWidth: Int,
        expectedHeight: Int,
        semantic: Semantic
    ) throws -> String {
        let (data, hash) = try dataAndHash(url)
        let header = try Self.parseHeader(data)
        guard header.width == expectedWidth, header.height == expectedHeight else {
            throw MindEyeProjectionError.invalidPlateManifest(
                "\(url.lastPathComponent) has dimensions \(header.width)x\(header.height)"
            )
        }
        switch semantic {
        case .opaqueBase, .transparentOverlay:
            guard header.bitDepth == 8, header.colorType == 6 else {
                throw MindEyeProjectionError.invalidPlateManifest(
                    "\(url.lastPathComponent) must be 8-bit RGBA"
                )
            }
            let alpha = try Self.alphaRange(data: data, width: header.width, height: header.height)
            switch semantic {
            case .opaqueBase:
                guard alpha.minimum == 255, alpha.maximum == 255 else {
                    throw MindEyeProjectionError.invalidPlateManifest(
                        "projection-base.png must be fully opaque"
                    )
                }
            case .transparentOverlay:
                guard alpha.minimum == 0, alpha.maximum > 0 else {
                    throw MindEyeProjectionError.invalidPlateManifest(
                        "\(url.lastPathComponent) must contain transparent and visible pixels"
                    )
                }
            }
        }
        return hash
    }

    private func loadTexture(
        _ layer: ValidatedLayer,
        loader: MTKTextureLoader,
        sRGB: Bool
    ) throws -> MindEyeProjectionPlateTexture {
        let texture = try loader.newTexture(
            URL: layer.url,
            options: [
                .SRGB: NSNumber(value: sRGB),
                .generateMipmaps: NSNumber(value: false),
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                .origin: MTKTextureLoader.Origin.topLeft,
            ]
        )
        texture.label = "MindEyeProjection_\(layer.descriptor.filename)"
        return MindEyeProjectionPlateTexture(
            texture: texture,
            filename: layer.descriptor.filename,
            sha256: layer.descriptor.sha256
        )
    }

    private func dataAndHash(_ url: URL) throws -> (Data, String) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else {
            throw MindEyeProjectionError.missingResource(url.lastPathComponent)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, digest)
    }

    private static func parseHeader(_ data: Data) throws -> PNGHeader {
        guard data.count >= 33,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              data[12..<16] == Data("IHDR".utf8) else {
            throw MindEyeProjectionError.invalidPlateManifest("invalid PNG header")
        }
        func uint32(_ offset: Int) -> Int {
            Int(data[offset]) << 24 |
                Int(data[offset + 1]) << 16 |
                Int(data[offset + 2]) << 8 |
                Int(data[offset + 3])
        }
        return PNGHeader(
            width: uint32(16),
            height: uint32(20),
            bitDepth: Int(data[24]),
            colorType: Int(data[25])
        )
    }

    private static func alphaRange(
        data: Data,
        width: Int,
        height: Int
    ) throws -> (minimum: UInt8, maximum: UInt8) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw MindEyeProjectionError.invalidPlateManifest("ImageIO decode failed")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let address = bytes.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                        CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw MindEyeProjectionError.invalidPlateManifest("RGBA alpha scan failed")
        }
        var minimum = UInt8.max
        var maximum = UInt8.min
        for index in stride(from: 3, to: pixels.count, by: 4) {
            minimum = min(minimum, pixels[index])
            maximum = max(maximum, pixels[index])
        }
        return (minimum, maximum)
    }
}
