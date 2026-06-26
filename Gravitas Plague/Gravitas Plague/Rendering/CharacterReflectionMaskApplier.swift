import CoreGraphics
import Foundation
import ImageIO
import RealityKit

actor CharacterReflectionMaskPreprocessor {
    static let shared = CharacterReflectionMaskPreprocessor()

    struct PreparedMask: Sendable {
        let sourceName: String
        let width: Int
        let height: Int
        let rgbData: Data
        let darkPixelCount: Int
    }

    private var preparedByPath: [String: PreparedMask] = [:]

    func prepare(
        url: URL
    ) throws -> PreparedMask {
        let key = url.path

        if let cached = preparedByPath[key] {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            throw NSError(
                domain: "CharacterReflectionMask",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create image source for \(url.lastPathComponent)"
                ]
            )
        }

        guard let sourceImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ) else {
            throw NSError(
                domain: "CharacterReflectionMask",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not decode \(url.lastPathComponent)"
                ]
            )
        }

        let prepared = try makeLuminanceMaskPixels(
            sourceImage,
            sourceName: url.lastPathComponent
        )

        preparedByPath[key] = prepared

        print(
            """
            [CharacterReflectionMask] luminance mask prepared
              source: \(prepared.sourceName)
              pixels: \(prepared.width)x\(prepared.height)
              darkPixelsLTE16: \(prepared.darkPixelCount)
              rgbOnlyMask: true
              alphaChannel: false
              preprocessingActor: true
            """
        )

        return prepared
    }

    private func makeLuminanceMaskPixels(
        _ sourceImage: CGImage,
        sourceName: String
    ) throws -> PreparedMask {
        let width = sourceImage.width
        let height = sourceImage.height

        guard width > 0, height > 0 else {
            throw NSError(
                domain: "CharacterReflectionMask",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid image dimensions for \(sourceName)"
                ]
            )
        }

        var sourcePixels = [UInt8](
            repeating: 0,
            count: width * height * 4
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let sourceContext = CGContext(
            data: &sourcePixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(
                domain: "CharacterReflectionMask",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create source context for \(sourceName)"
                ]
            )
        }

        sourceContext.draw(
            sourceImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
        )

        var outputPixels = [UInt8](
            repeating: 0,
            count: width * height * 3
        )

        var darkPixelCount = 0

        for i in 0..<(width * height) {
            let p = i * 4

            let r = Float(sourcePixels[p + 0])
            let g = Float(sourcePixels[p + 1])
            let b = Float(sourcePixels[p + 2])

            let luminanceFloat =
                0.2126 * r +
                0.7152 * g +
                0.0722 * b

            let luminance = UInt8(
                max(
                    0,
                    min(
                        255,
                        Int(luminanceFloat.rounded())
                    )
                )
            )

            if luminance <= 16 {
                darkPixelCount += 1
            }

            let outputIndex = i * 3
            outputPixels[outputIndex + 0] = luminance
            outputPixels[outputIndex + 1] = luminance
            outputPixels[outputIndex + 2] = luminance
        }

        return PreparedMask(
            sourceName: sourceName,
            width: width,
            height: height,
            rgbData: Data(outputPixels),
            darkPixelCount: darkPixelCount
        )
    }
}

@MainActor
enum CharacterReflectionMaskApplier {
    struct Report: Sendable {
        enum Outcome: String, Sendable {
            case applied
            case sidecarMissing
            case textureLoadFailed
            case noPBRMaterials
        }

        let outcome: Outcome
        let assetName: String
        let expectedSidecarName: String
        let resolvedSidecarURL: URL?
        let modelComponentsVisited: Int
        let materialsVisited: Int
        let pbrMaterialsUpdated: Int
        let nonPBRMaterialsSkipped: Int
        let existingSpecularTexturesReplaced: Int
        let existingClearcoatTexturesReplaced: Int
    }

    @discardableResult
    static func apply(
        to root: Entity,
        assetURL: URL,
        reason: String,
        bundle: Bundle = .main
    ) async -> Report {
        let assetName = assetURL.lastPathComponent
        let assetStem = assetURL
            .deletingPathExtension()
            .lastPathComponent
        let expectedSidecarName = "\(assetStem)_ior.png"

        guard let sidecarURL = resolveSidecarURL(
            expectedFileName: expectedSidecarName,
            beside: assetURL,
            bundle: bundle
        ) else {
            let report = Report(
                outcome: .sidecarMissing,
                assetName: assetName,
                expectedSidecarName: expectedSidecarName,
                resolvedSidecarURL: nil,
                modelComponentsVisited: 0,
                materialsVisited: 0,
                pbrMaterialsUpdated: 0,
                nonPBRMaterialsSkipped: 0,
                existingSpecularTexturesReplaced: 0,
                existingClearcoatTexturesReplaced: 0
            )

            print(
                """
                [CharacterReflectionMask] sidecar missing; material preserved
                  asset: \(assetName)
                  expectedSidecar: \(expectedSidecarName)
                  reason: \(reason)
                  effectiveSpecularMultiplier: 1.0
                  effectiveClearcoatMultiplier: 1.0
                  materialsChanged: false
                  opacityTouched: false
                  blendingTouched: false
                """
            )

            return report
        }

        let textureResource: TextureResource

        do {
            textureResource = try await loadScalarTexture(
                url: sidecarURL,
                name: expectedSidecarName
            )
        } catch {
            let report = Report(
                outcome: .textureLoadFailed,
                assetName: assetName,
                expectedSidecarName: expectedSidecarName,
                resolvedSidecarURL: sidecarURL,
                modelComponentsVisited: 0,
                materialsVisited: 0,
                pbrMaterialsUpdated: 0,
                nonPBRMaterialsSkipped: 0,
                existingSpecularTexturesReplaced: 0,
                existingClearcoatTexturesReplaced: 0
            )

            print(
                """
                [CharacterReflectionMask] sidecar load failed; material preserved
                  asset: \(assetName)
                  sidecar: \(sidecarURL.lastPathComponent)
                  reason: \(reason)
                  error: \(error.localizedDescription)
                  effectiveSpecularMultiplier: 1.0
                  effectiveClearcoatMultiplier: 1.0
                  materialsChanged: false
                  opacityTouched: false
                  blendingTouched: false
                """
            )

            return report
        }

        let maskTexture = PhysicallyBasedMaterial.Texture(
            textureResource
        )

        var modelComponentsVisited = 0
        var materialsVisited = 0
        var pbrMaterialsUpdated = 0
        var nonPBRMaterialsSkipped = 0
        var existingSpecularTexturesReplaced = 0
        var existingClearcoatTexturesReplaced = 0

        visitRecursively(root) { entity in
            guard var model = entity.components[ModelComponent.self] else {
                return
            }

            modelComponentsVisited += 1
            var entityMaterialChanged = false

            let updatedMaterials = model.materials.map {
                material -> any Material in
                materialsVisited += 1

                guard var pbr = material as? PhysicallyBasedMaterial else {
                    nonPBRMaterialsSkipped += 1
                    return material
                }

                let authoredSpecularScale = pbr.specular.scale
                let authoredClearcoatScale = pbr.clearcoat.scale

                if pbr.specular.texture != nil {
                    existingSpecularTexturesReplaced += 1
                }

                if pbr.clearcoat.texture != nil {
                    existingClearcoatTexturesReplaced += 1
                }

                pbr.specular = .init(
                    scale: authoredSpecularScale,
                    texture: maskTexture
                )

                pbr.clearcoat = .init(
                    scale: authoredClearcoatScale,
                    texture: maskTexture
                )

                pbrMaterialsUpdated += 1
                entityMaterialChanged = true

                return pbr
            }

            guard entityMaterialChanged else {
                return
            }

            model.materials = updatedMaterials
            entity.components.set(model)
        }

        let outcome: Report.Outcome =
            pbrMaterialsUpdated > 0
                ? .applied
                : .noPBRMaterials

        let report = Report(
            outcome: outcome,
            assetName: assetName,
            expectedSidecarName: expectedSidecarName,
            resolvedSidecarURL: sidecarURL,
            modelComponentsVisited: modelComponentsVisited,
            materialsVisited: materialsVisited,
            pbrMaterialsUpdated: pbrMaterialsUpdated,
            nonPBRMaterialsSkipped: nonPBRMaterialsSkipped,
            existingSpecularTexturesReplaced: existingSpecularTexturesReplaced,
            existingClearcoatTexturesReplaced: existingClearcoatTexturesReplaced
        )

        print(
            """
            [CharacterReflectionMask] pass complete
              outcome: \(report.outcome.rawValue)
              asset: \(report.assetName)
              sidecar: \(sidecarURL.lastPathComponent)
              reason: \(reason)
              semantic: scalar
              maskFormat: rgb_luminance_no_alpha
              blackMeaning: specular_0_clearcoat_0
              whiteMeaning: preserve_authored_scalars
              modelComponentsVisited: \(report.modelComponentsVisited)
              materialsVisited: \(report.materialsVisited)
              pbrMaterialsUpdated: \(report.pbrMaterialsUpdated)
              nonPBRMaterialsSkipped: \(report.nonPBRMaterialsSkipped)
              existingSpecularTexturesReplaced: \(report.existingSpecularTexturesReplaced)
              existingClearcoatTexturesReplaced: \(report.existingClearcoatTexturesReplaced)
              opacityTouched: false
              blendingTouched: false
              roughnessTouched: false
              ambientOcclusionTouched: false
            """
        )

        if pbrMaterialsUpdated == 0 {
            print(
                """
                [CharacterReflectionMask] WARNING no PBR material was updated
                  asset: \(assetName)
                  sidecarWasLoaded: true
                  likelyMaterialType: ShaderGraphMaterial_or_other_non_PBR
                  materialConversionAttempted: false
                """
            )
        }

        return report
    }
}

private extension CharacterReflectionMaskApplier {
    static func resolveSidecarURL(
        expectedFileName: String,
        beside assetURL: URL,
        bundle: Bundle
    ) -> URL? {
        let adjacentURL = assetURL
            .deletingLastPathComponent()
            .appendingPathComponent(expectedFileName)

        if FileManager.default.isReadableFile(atPath: adjacentURL.path) {
            return adjacentURL
        }

        let fileURL = URL(fileURLWithPath: expectedFileName)
        let basename = fileURL
            .deletingPathExtension()
            .lastPathComponent
        let fileExtension = fileURL.pathExtension.isEmpty
            ? "png"
            : fileURL.pathExtension

        if let rootURL = bundle.url(
            forResource: basename,
            withExtension: fileExtension
        ) {
            return rootURL
        }

        if let materialsURL = bundle.url(
            forResource: basename,
            withExtension: fileExtension,
            subdirectory: "CharacterLibrary/Materials"
        ) {
            return materialsURL
        }

        return nil
    }

    static func loadScalarTexture(
        url: URL,
        name: String
    ) async throws -> TextureResource {
        let prepared = try await CharacterReflectionMaskPreprocessor.shared.prepare(
            url: url
        )

        let image = try makeLuminanceMaskImage(
            prepared
        )

        return try await TextureResource(
            image: image,
            withName: name,
            options: .init(semantic: .scalar)
        )
    }

    static func makeLuminanceMaskImage(
        _ prepared: CharacterReflectionMaskPreprocessor.PreparedMask
    ) throws -> CGImage {
        let width = prepared.width
        let height = prepared.height

        guard width > 0, height > 0 else {
            throw NSError(
                domain: "CharacterReflectionMask",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid image dimensions for \(prepared.sourceName)"
                ]
            )
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let outputData = prepared.rgbData as CFData

        guard let outputProvider = CGDataProvider(data: outputData) else {
            throw NSError(
                domain: "CharacterReflectionMask",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create output data provider for \(prepared.sourceName)"
                ]
            )
        }

        guard let outputImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.none.rawValue
            ),
            provider: outputProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw NSError(
                domain: "CharacterReflectionMask",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create luminance mask image for \(prepared.sourceName)"
                ]
            )
        }

        return outputImage
    }

    static func visitRecursively(
        _ entity: Entity,
        body: (Entity) -> Void
    ) {
        body(entity)

        for child in entity.children {
            visitRecursively(
                child,
                body: body
            )
        }
    }
}
