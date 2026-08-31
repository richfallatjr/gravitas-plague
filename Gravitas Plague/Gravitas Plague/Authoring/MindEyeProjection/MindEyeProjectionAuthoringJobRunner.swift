#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import CryptoKit
import Foundation
import Metal
import RealityKit
import UIKit
import simd

@MainActor
final class MindEyeProjectionAuthoringJobRunner {
    private let factory = Chapter03LightTunnelSceneFactory()
    private var cachedHeavenResources: Chapter03LightTunnelSceneFactory.HeavenResources?

    func run(_ job: MindEyeProjectionAuthoringJob) async throws {
        let store = try MindEyeProjectionExportStore(captureID: job.configuration.captureID)
        do {
            switch job.configuration.job {
            case .inspectSubject:
                try await inspect(store: store)
            case .resolveCamera:
                try await resolveCamera(store: store)
            case .captureReference:
                try await captureReference(store: store)
            case .validateRuntimeProjection:
                throw MindEyeProjectionError.rendererUnavailable(
                    "visionOS 27 marks CustomMaterial unavailable; a ShaderGraphMaterial program is required"
                )
            case .materialParity:
                try await materialParity(store: store)
            case .coordinateSpaceProof:
                try await coordinateSpaceProof(store: store)
            }
        } catch {
            try? await store.publishFailure(error)
            throw error
        }
    }

    private func coordinateSpaceProof(store: MindEyeProjectionExportStore) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MindEyeProjectionError.rendererUnavailable("Metal device is unavailable")
        }
        let locator = try MindEyeResourceLocator.applicationBundle()
        let package = try await MindEyeProjectionPlatePackageLoader(
            device: device,
            label: "com.gravitas.plague.mindseye.coordinate-proof-loader"
        ).load(
            locator: locator,
            profileResourcePath: MindEyeAngelProjectionController.profileResourcePath,
            qualificationPolicy: .allowUnqualifiedAuthoringRun
        )
        let rawMask = try await MindEyeProjectionReceiverMaskLoader(device: device).load(
            locator: locator,
            descriptor: package.profile.projectionReceiverUVMask
        )
        let receiverMask = try await MindEyeProjectionReceiverMaskTextureSource.make(
            payload: rawMask,
            device: device
        )
        let projectionTexture = try await MindEyeProjectionTextureSource.make()
        try await MindEyeProjectionDiagnosticCheckerEncoder.encode(
            output: projectionTexture,
            device: device
        )
        let renderer = MindEyeProjectionRealityRenderer(device: device)

        func render(
            mode: MindEyeProjectionMaterialDiagnosticMode,
            weight: Float
        ) async throws -> MindEyeProjectionPixelBuffer {
            let scene = try await makeScene(mode: .projectionAuthoringBeauty)
            do {
                scene.portalDome.isEnabled = false
                try applyAuthoringMaterials(
                    target: package.target,
                    subjectRoot: scene.angel.root,
                    pass: .faceBeauty
                )
                let bindings = try Chapter03AngelBlendShapeResolver().resolve(
                    in: scene.angel.visualRoot,
                    targetName: "jawOpenProjection"
                )
                try AngelBlendShapePoseCapture.assign(weight, bindings: bindings)
                let controller = MindEyeProjectionMaterialController()
                if mode != .originalImportedPBR {
                    let preparation = try await MindEyeProjectionMaterialFactory.prepare(
                        package: package,
                        projectionTexture: projectionTexture,
                        receiverMask: receiverMask,
                        subjectRoot: scene.angel.root,
                        diagnosticMode: mode
                    )
                    try controller.commit(preparation)
                }
                let image = try await renderer.render(
                    scene: scene,
                    camera: package.camera,
                    toneMappingEnabled: false,
                    pixelFormat: .bgra8Unorm_srgb
                )
                controller.release(reason: "coordinateSpaceProof.complete")
                scene.release(reason: "projectionAuthoring.coordinateSpaceProof.complete")
                return image
            } catch {
                scene.release(reason: "projectionAuthoring.coordinateSpaceProof.failed")
                throw error
            }
        }

        let original = try await render(mode: .originalImportedPBR, weight: 0)
        let coverageZero = try await render(
            mode: .projectionMaterialCoverageZero,
            weight: 0
        )
        let receiverUV = try await render(mode: .visualizeReceiverUVMask, weight: 0)
        let weights: [Float] = [0, 0.33, 0.50, 1]
        var checkerFrames: [MindEyeProjectionPixelBuffer] = []
        for weight in weights {
            checkerFrames.append(
                try await render(mode: .visualizeProjectorChecker, weight: weight)
            )
        }
        let frameHashes = checkerFrames.map {
            MindEyeProjectionExportStore.sha256($0.bgra8)
        }
        guard Set(frameHashes).count >= 2 else {
            throw MindEyeProjectionError.coordinateSpaceProofFailed(
                "checker did not respond to blendshape deformation"
            )
        }

        let fixed: [(MindEyeProjectionPixelBuffer, String)] = [
            (original, "angel_head_v1_coordinate-original-pbr.png"),
            (coverageZero, "angel_head_v1_coordinate-projection-zero.png"),
            (receiverUV, "angel_head_v1_coordinate-receiver-uv.png"),
        ]
        let checkerNames = weights.map {
            String(format: "angel_head_v1_coordinate-checker-%03d.png", Int($0 * 100))
        }
        var fixedURLs: [URL] = []
        for entry in fixed { fixedURLs.append(await store.url(entry.1)) }
        var checkerURLs: [URL] = []
        for name in checkerNames { checkerURLs.append(await store.url(name)) }
        try await Task.detached(priority: .userInitiated) {
            for (entry, URL) in zip(fixed, fixedURLs) {
                try MindEyeProjectionPNGWriter.writeBGRA8(entry.0, to: URL)
            }
            for (frame, URL) in zip(checkerFrames, checkerURLs) {
                try MindEyeProjectionPNGWriter.writeBGRA8(frame, to: URL)
            }
        }.value

        let report = MindEyeProjectionCoordinateProofReport(
            schemaVersion: 1,
            graphVersion: package.importedPBRContract.graphVersion,
            cameraSHA256: package.manifest.cameraSHA256,
            receiverMaskSHA256: rawMask.metadata.SHA256,
            receiverUVSetName: rawMask.metadata.UVSetName,
            receiverUVSetIndex: rawMask.metadata.UVSetIndex,
            weights: weights,
            checkerFrameSHA256: frameHashes,
            blendshapeChangesProjectedSurface: Set(frameHashes).count >= 2,
            projectorMotionChangesChecker: false,
            projectorMotionChangesUVBoundary: nil,
            UVMaskChangeReframesChecker: nil,
            physicalDeviceQualified: false,
            qualificationNote: "Simulator captures prove distinct mesh-deformation states. Independent projector-motion and physical-device observations remain required."
        )
        try await store.write(report, filename: "angel_head_v1.coordinate-space-proof.json")
        let reportData = try JSONEncoder.canonical.encode(report)
        try await store.publish(marker: .init(
            schemaVersion: 1,
            captureID: "angel_head_v1",
            status: "complete",
            manifest: "angel_head_v1.coordinate-space-proof.json",
            cameraSHA256: package.manifest.cameraSHA256,
            outputSetSHA256: MindEyeProjectionExportStore.sha256(reportData),
            failureCode: nil,
            message: report.qualificationNote
        ))
    }

    private func materialParity(store: MindEyeProjectionExportStore) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MindEyeProjectionError.rendererUnavailable("Metal device is unavailable")
        }
        let locator = try MindEyeResourceLocator.applicationBundle()
        let package = try await MindEyeProjectionPlatePackageLoader(
            device: device,
            label: "com.gravitas.plague.mindseye.material-parity-loader"
        ).load(
            locator: locator,
            profileResourcePath: MindEyeAngelProjectionController.profileResourcePath,
            qualificationPolicy: .allowUnqualifiedAuthoringRun
        )
        let rawMask = try await MindEyeProjectionReceiverMaskLoader(
            device: device
        ).load(
            locator: locator,
            descriptor: package.profile.projectionReceiverUVMask
        )
        let receiverMask = try await MindEyeProjectionReceiverMaskTextureSource.make(
            payload: rawMask,
            device: device
        )
        let projectionTexture = try await MindEyeProjectionTextureSource.make()
        let compositor = try await MindEyeProjectionCompositorPipeline(
            device: device
        ).resources()
        try await MindEyeProjectionCompositeEncoder.encodeAndCommit(
            package: package,
            frame: MindEyeCompositeFrameState(
                sequence: 0,
                backgroundTransform: .identity,
                characterTransform: .identity,
                eyeSelection: .open(variantIndex: 0),
                mouthSelection: .init(pose: .rest, variantIndex: 0),
                maskMode: .artistRGB
            ),
            output: projectionTexture,
            resources: compositor
        )
        let renderer = MindEyeProjectionRealityRenderer(device: device)

        // Render A and B from the same entity graph, IBL resources, camera,
        // transforms, and frame state. Reconstructing the scene between the
        // two samples admits asynchronous environment-processing variance and
        // measures more than the material replacement under qualification.
        let parityScene = try await makeScene(mode: .projectionAuthoringBeauty)
        parityScene.portalDome.isEnabled = false
        try applyAuthoringMaterials(
            target: package.target,
            subjectRoot: parityScene.angel.root,
            pass: .faceBeauty
        )
        let original = try await renderer.render(
            scene: parityScene,
            camera: package.camera,
            toneMappingEnabled: false,
            pixelFormat: .bgra8Unorm_srgb
        )
        let materialController = MindEyeProjectionMaterialController()
        let preparation = try await MindEyeProjectionMaterialFactory.prepare(
            package: package,
            projectionTexture: projectionTexture,
            receiverMask: receiverMask,
            subjectRoot: parityScene.angel.root,
            diagnosticMode: .projectionMaterialCoverageZero
        )
        try materialController.commit(preparation)
        let replacement = try await renderer.render(
            scene: parityScene,
            camera: package.camera,
            toneMappingEnabled: false,
            pixelFormat: .bgra8Unorm_srgb
        )
        materialController.release(reason: "materialParity.complete")
        try applyAuthoringMaterials(
            target: package.target,
            subjectRoot: parityScene.angel.root,
            pass: .binaryCoverage
        )
        let targetMask = try await renderer.render(
            scene: parityScene,
            camera: package.camera,
            toneMappingEnabled: false,
            pixelFormat: .bgra8Unorm
        )
        parityScene.release(reason: "projectionAuthoring.materialParity.complete")

        let parity = try await Task.detached(priority: .userInitiated) {
            try Self.measureMaterialParity(
                original: original,
                replacement: replacement,
                targetMask: targetMask
            )
        }.value
        let originalURL = await store.url("angel_head_v1_material-parity-original.png")
        let replacementURL = await store.url("angel_head_v1_material-parity-replacement.png")
        let maskURL = await store.url("angel_head_v1_material-parity-target-mask.png")
        let diffURL = await store.url("angel_head_v1_material-parity-diff.png")
        try await Task.detached(priority: .userInitiated) {
            try MindEyeProjectionPNGWriter.writeBGRA8(original, to: originalURL)
            try MindEyeProjectionPNGWriter.writeBGRA8(replacement, to: replacementURL)
            try MindEyeProjectionPNGWriter.writeBGRA8(targetMask, to: maskURL)
            try MindEyeProjectionPNGWriter.writeBGRA8(parity.diff, to: diffURL)
        }.value

        let (_, profileHash) = try MindEyeProjectionCameraStore(
            locator: locator
        ).dataAndSHA256(resourcePath: MindEyeAngelProjectionController.profileResourcePath)
        let contractURL = try locator.resolve(
            resourcePath: package.profile.importedPBRContractResourcePath
        )
        let contractHash = try MindEyeProjectionExportStore.sha256(file: contractURL)
        let qualification = MindEyeProjectionMaterialParityQualification(
            schemaVersion: 1,
            qualificationID: "angel_head_v1.material-parity",
            subjectAssetSHA256: package.manifest.subjectAssetSHA256,
            profileSHA256: profileHash,
            cameraSHA256: package.manifest.cameraSHA256,
            targetSHA256: package.manifest.targetSHA256,
            importedPBRContractSHA256: contractHash,
            graphVersion: package.importedPBRContract.graphVersion,
            SDKBuild: ProcessInfo.processInfo.environment["GR_SDK_BUILD"] ??
                ProcessInfo.processInfo.operatingSystemVersionString,
            renderWidth: original.width,
            renderHeight: original.height,
            maskPixelCount: parity.maskPixelCount,
            RMSELinearRGB: parity.RMSE,
            p99AbsoluteErrorLinearRGB: parity.p99,
            maximumAbsoluteErrorLinearRGB: parity.maximum,
            PSNRDecibels: parity.PSNR,
            passed: parity.passed
        )
        try await store.write(
            qualification,
            filename: "angel_head_v1.material-parity.json"
        )
        let qualificationData = try JSONEncoder.canonical.encode(qualification)
        try await store.publish(marker: .init(
            schemaVersion: 1,
            captureID: "angel_head_v1",
            status: parity.passed ? "complete" : "failed",
            manifest: "angel_head_v1.material-parity.json",
            cameraSHA256: package.manifest.cameraSHA256,
            outputSetSHA256: MindEyeProjectionExportStore.sha256(qualificationData),
            failureCode: parity.passed ? nil : "materialParityUnqualified",
            message: parity.passed ? nil : "replacement PBR exceeded parity gates"
        ))
        guard parity.passed else {
            throw MindEyeProjectionError.materialParityUnqualified
        }
    }

    private func inspect(store: MindEyeProjectionExportStore) async throws {
        let scene = try await makeScene(mode: .projectionAuthoringBeauty)
        defer { scene.release(reason: "projectionAuthoring.inspect") }
        let report = try MindEyeProjectionHierarchyReporter.make(subjectRoot: scene.angel.root)
        let blendShape = try AngelBlendShapeRealityKitProbe.run(
            root: scene.angel.visualRoot
        )
        let bindingSummary = blendShape.bindings.map {
            "\($0.entityPath)#\($0.groupIndex):\($0.weightIndex)=\($0.weightName)"
        }.joined(separator: ",")
        let meshEvidence = blendShape.importedMeshEvidence.joined(separator: " | ")
        let inspectedText = report.text +
            "BLENDSHAPE_PROBE target=jawOpenProjection " +
            "modelEntityCount=\(blendShape.modelEntityCount) " +
            "bindings=\(bindingSummary) " +
            "meshEvidence=\(meshEvidence) " +
            "testedWeights=\(blendShape.testedWeights) " +
            "returnedToZero=\(blendShape.returnedToZero)\n"
        try await store.write(
            Data(inspectedText.utf8),
            filename: "angel_head_v1_scene-hierarchy.txt"
        )
        try await store.write(report.candidate, filename: "angel_head_v1.target.json")
        let marker = MindEyeProjectionCompletionMarker(
            schemaVersion: 1, captureID: "angel_head_v1", status: "complete",
            manifest: nil, cameraSHA256: nil,
            outputSetSHA256: MindEyeProjectionExportStore.sha256(Data(inspectedText.utf8)),
            failureCode: nil, message: nil
        )
        try await store.publish(marker: marker)
    }

    private func resolveCamera(store: MindEyeProjectionExportStore) async throws {
        let (profile, target, hashes) = try loadContracts()
        let scene = try await makeScene(mode: .projectionAuthoringBeauty)
        defer { scene.release(reason: "projectionAuthoring.resolveCamera") }
        let resolution = try MindEyeProjectionTargetResolver.resolve(
            descriptor: target, subjectRoot: scene.angel.root
        )
        let fit: MindEyeProjectionCameraMath.Fit
        let cameraMathVersion: String
        if let control = target.authoringFramingControl {
            fit = try MindEyeProjectionCameraMath.fit(authoringControl: control)
            cameraMathVersion = MindEyeProjectionCameraMath.cubeFramingVersion
        } else {
            let bounds = resolution.framingEntity.visualBounds(relativeTo: scene.angel.root)
            fit = try MindEyeProjectionCameraMath.fit(
                minimum: bounds.min,
                maximum: bounds.max,
                forwardAxis: SIMD3(target.subjectForwardAxis[0], target.subjectForwardAxis[1], target.subjectForwardAxis[2]),
                localOffset: SIMD3(target.targetLocalOffsetMeters[0], target.targetLocalOffsetMeters[1], target.targetLocalOffsetMeters[2])
            )
            cameraMathVersion = MindEyeProjectionCameraMath.version
        }
        let camera = MindEyeProjectionCameraDescriptor(
            schemaVersion: 1,
            cameraID: "angel_head_v1.camera",
            profileID: profile.profileID,
            imageWidth: profile.sourceWidth,
            imageHeight: profile.sourceHeight,
            nearMeters: 0.02,
            farMeters: 20,
            fieldOfViewDegrees: 30,
            fieldOfViewOrientation: "vertical",
            subjectFromCamera: fit.subjectFromCamera.columnMajorValues,
            clipFromCamera: fit.clipFromCamera.columnMajorValues,
            clipFromSubject: fit.clipFromSubject.columnMajorValues,
            targetCenterSubjectMeters: fit.targetCenter.array,
            targetBoundsMinimumSubjectMeters: fit.targetMinimum.array,
            targetBoundsMaximumSubjectMeters: fit.targetMaximum.array,
            framingPadding: 1.12,
            sourceCropOrigin: [profile.cropOriginX, profile.cropOriginY],
            sourceCropSize: [profile.viewportWidth, profile.viewportHeight],
            sceneDefinitionSHA256: hashes.scene,
            subjectAssetSHA256: hashes.subject,
            targetDescriptorSHA256: hashes.target,
            cameraMathVersion: cameraMathVersion
        )
        try camera.validate()
        try await store.write(camera, filename: "angel_head_v1.camera.json")
        let data = try JSONEncoder.canonical.encode(camera)
        try await store.publish(marker: .init(
            schemaVersion: 1, captureID: "angel_head_v1", status: "complete",
            manifest: nil,
            cameraSHA256: MindEyeProjectionExportStore.sha256(data),
            outputSetSHA256: MindEyeProjectionExportStore.sha256(data),
            failureCode: nil, message: nil
        ))
    }

    private func captureReference(store: MindEyeProjectionExportStore) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MindEyeProjectionError.rendererUnavailable("Metal device is unavailable")
        }
        let (profile, target, hashes) = try loadContracts()
        let locator = try MindEyeResourceLocator.applicationBundle()
        let cameraStore = MindEyeProjectionCameraStore(locator: locator)
        let camera = try cameraStore.loadCamera(resourcePath: profile.cameraResourcePath)
        let (_, cameraHash) = try cameraStore.dataAndSHA256(resourcePath: profile.cameraResourcePath)
        let authoringMaskPath =
            "Turing/MindsEye/Projection/masks/angel_head_v1_projection-mask-uv.png"
        let projectionMaskTexture = try await TextureResource(
            contentsOf: locator.resolve(resourcePath: authoringMaskPath),
            options: .init(semantic: .raw, mipmapsMode: .none)
        )
        let renderer = MindEyeProjectionRealityRenderer(device: device)

        let sceneBeautyScene = try await makeScene(mode: .projectionAuthoringBeauty)
        let sceneBeauty = try await renderer.render(scene: sceneBeautyScene, camera: camera)
        sceneBeautyScene.release(reason: "projectionAuthoring.sceneBeauty")

        let faceScene = try await makeScene(mode: .projectionAuthoringBeauty)
        try applyAuthoringMaterials(target: target, subjectRoot: faceScene.angel.root, pass: .faceBeauty)
        faceScene.portalDome.isEnabled = false
        let faceBeauty = try await renderer.render(scene: faceScene, camera: camera)
        faceScene.release(reason: "projectionAuthoring.faceBeauty")

        let maskScene = try await makeScene(mode: .projectionAuthoringMask)
        try applyAuthoringMaterials(
            target: target,
            subjectRoot: maskScene.angel.root,
            pass: .binaryMask,
            projectionMaskTexture: projectionMaskTexture
        )
        let renderedProjectionMaskAOV = try await renderer.render(
            scene: maskScene,
            camera: camera,
            toneMappingEnabled: false,
            pixelFormat: .bgra8Unorm
        )
        maskScene.release(reason: "projectionAuthoring.mask")

        let (projectionMaskAOV, processed) = try await Task.detached(priority: .userInitiated) {
            // Preserve the AOV as the exact flat owner texture rendered on the
            // geometry. Its black facial island is converted to the canonical
            // white-projects runtime convention only for the processed mask.
            let projectionMaskAOV = renderedProjectionMaskAOV
            let processed = try MindEyeProjectionMaskProcessor.process(
                projectionMaskAOV,
                // Authoring-only camera-space diagnostic controls. Runtime
                // receiver coverage comes exclusively from model UVs.
                inset: 12,
                feather: 32,
                foregroundIsDark: true
            )
            return (projectionMaskAOV, processed)
        }.value
        try MindEyeProjectionValidation.validateAuthoredMaskForLockedCrop(
            processed.metrics
        )

        let geometryPoseOutputs = try await captureGeometryPoses(
            store: store,
            renderer: renderer,
            camera: camera,
            cameraSHA256: cameraHash,
            target: target,
            profile: profile,
            projectionMaskTexture: projectionMaskTexture
        )

        let sceneURL = await store.url("angel_head_v1_scene-beauty.png")
        let faceURL = await store.url("angel_head_v1_face-beauty.png")
        let aovURL = await store.url("angel_head_v1_projection-mask-aov.png")
        let linearURL = await store.url("angel_head_v1_projection-mask-linear16.png")
        let previewURL = await store.url("angel_head_v1_projection-mask-preview.png")
        let guideURL = await store.url("angel_head_v1_alignment-guide.png")
        try await Task.detached(priority: .userInitiated) {
            try MindEyeProjectionPNGWriter.writeBGRA8(sceneBeauty, to: sceneURL)
            try MindEyeProjectionPNGWriter.writeBGRA8(faceBeauty, to: faceURL)
            try MindEyeProjectionPNGWriter.writeBGRA8(projectionMaskAOV, to: aovURL)
            try MindEyeProjectionPNGWriter.writeGray16(processed.linear16, width: 1_728, height: 1_728, to: linearURL)
            try MindEyeProjectionPNGWriter.writeGray8(processed.preview8, width: 1_728, height: 1_728, to: previewURL)
            let guide = Self.makeAlignmentGuide(faceBeauty: faceBeauty, mask: processed.preview8)
            try MindEyeProjectionPNGWriter.writeBGRA8(guide, to: guideURL)
        }.value

        let hierarchyScene = try await makeScene(mode: .projectionAuthoringBeauty)
        let hierarchy = try MindEyeProjectionHierarchyReporter.make(subjectRoot: hierarchyScene.angel.root)
        hierarchyScene.release(reason: "projectionAuthoring.hierarchy")
        try await store.write(Data(hierarchy.text.utf8), filename: "angel_head_v1_scene-hierarchy.txt")
        try await store.write(camera, filename: "angel_head_v1_camera.json")

        var roles: [(String, String, Int, String, String, Int, Int)] = [
            ("sceneBeauty", "angel_head_v1_scene-beauty.png", 8, "sRGB", "opaque", 1_728, 1_728),
            ("faceBeauty", "angel_head_v1_face-beauty.png", 8, "sRGB", "opaque", 1_728, 1_728),
            ("projectionMaskAOV", "angel_head_v1_projection-mask-aov.png", 8, "linearRGB", "opaque", 1_728, 1_728),
            ("projectionMaskLinear16", "angel_head_v1_projection-mask-linear16.png", 16, "linearGray", "none", 1_728, 1_728),
            ("projectionMaskPreview", "angel_head_v1_projection-mask-preview.png", 8, "gray", "none", 1_728, 1_728),
            ("alignmentGuide", "angel_head_v1_alignment-guide.png", 8, "sRGB", "opaque", 1_728, 1_728),
            ("camera", "angel_head_v1_camera.json", 8, "UTF-8", "none", 0, 0),
            ("hierarchy", "angel_head_v1_scene-hierarchy.txt", 8, "UTF-8", "none", 0, 0)
        ]
        roles.append(contentsOf: geometryPoseOutputs)
        var outputs: [MindEyeProjectionCaptureManifest.Output] = []
        for (role, filename, bits, color, alpha, width, height) in roles {
            let url = await store.url(filename)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            outputs.append(.init(
                role: role, filename: filename,
                width: width,
                height: height,
                bitsPerChannel: bits, colorSpace: color, alphaMode: alpha,
                byteCount: data.count, SHA256: MindEyeProjectionExportStore.sha256(data)
            ))
        }
        let manifest = MindEyeProjectionCaptureManifest(
            schemaVersion: 1, captureID: "angel_head_v1",
            repositoryCommit: ProcessInfo.processInfo.environment["GR_REPOSITORY_COMMIT"] ?? "unknown",
            worktreeWasDirty: ProcessInfo.processInfo.environment["GR_WORKTREE_DIRTY"] == "1",
            appBuildConfiguration: "Debug+GR_MIND_EYE_PROJECTION_AUTHORING",
            SDKBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            simulatorRuntime: ProcessInfo.processInfo.environment["SIMULATOR_RUNTIME_VERSION"] ?? "unknown",
            simulatorDevice: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown",
            profileID: profile.profileID, profileSHA256: hashes.profile,
            cameraID: camera.cameraID, cameraSHA256: cameraHash,
            targetSHA256: hashes.target, subjectAssetSHA256: hashes.subject,
            heavenEXRSHA256: hashes.heaven, sceneDefinitionSHA256: hashes.scene,
            sourceWidth: 1_728, sourceHeight: 1_728,
            viewportWidth: 1_440, viewportHeight: 1_440,
            captureState: "frameZero", mediaTimeSeconds: 0, animationAdvancedFrames: 0,
            beautyPixelFormat: "bgra8Unorm_srgb", maskPixelFormat: "bgra8Unorm",
            maskCoverageFraction: processed.metrics.coverageFraction,
            maskBoundingBoxPixels: processed.metrics.boundingBox,
            maskCenterErrorPixels: processed.metrics.centerErrorPixels,
            outputs: outputs
        )
        try await store.write(manifest, filename: "angel_head_v1_capture-manifest.json")
        try MindEyeProjectionCaptureValidator.validate(
            directory: store.staging,
            manifest: manifest
        )
        let outputSet = MindEyeProjectionExportStore.sha256(
            Data(outputs.map(\.SHA256).joined(separator: "\n").utf8)
        )
        try await store.publish(marker: .init(
            schemaVersion: 1, captureID: "angel_head_v1", status: "complete",
            manifest: "angel_head_v1_capture-manifest.json", cameraSHA256: cameraHash,
            outputSetSHA256: outputSet, failureCode: nil, message: nil
        ))
    }

    private func captureGeometryPoses(
        store: MindEyeProjectionExportStore,
        renderer: MindEyeProjectionRealityRenderer,
        camera: MindEyeProjectionCameraDescriptor,
        cameraSHA256: String,
        target: MindEyeProjectionTargetDescriptor,
        profile: MindEyeProjectionProfile,
        projectionMaskTexture: TextureResource
    ) async throws -> [(String, String, Int, String, String, Int, Int)] {
        let directory = "GeometryPoses"
        try await store.createDirectory(directory)
        var beauties: [MindEyeProjectionPixelBuffer] = []
        var coverages: [MindEyeProjectionPixelBuffer] = []
        var manifestPoses: [AngelBlendShapePoseCaptureManifest.Pose] = []
        var outputs: [(String, String, Int, String, String, Int, Int)] = []

        // Each pose uses a fresh entity graph. Authoring pass materials replace
        // ModelComponent values, so the weight must be applied after each
        // material replacement and before that graph is attached to a renderer.
        // Applying it earlier can leave the public blend-weight arrays updated
        // while RealityKit renders the undeformed mesh. The expensive EXR/IBL
        // resources remain shared through cachedHeavenResources.
        for (pose, weight) in AngelBlendShapePoseCapture.orderedGeometryPoses {
            let poseScene = try await makeScene(mode: .projectionAuthoringBeauty)
            do {
                let bindings = try Chapter03AngelBlendShapeResolver().resolve(
                    in: poseScene.angel.visualRoot,
                    targetName: "jawOpenProjection"
                )
                poseScene.portalDome.isEnabled = false
                try applyAuthoringMaterials(
                    target: target,
                    subjectRoot: poseScene.angel.root,
                    pass: .faceBeauty
                )
                try AngelBlendShapePoseCapture.assign(weight, bindings: bindings)
                beauties.append(try await renderer.render(
                    scene: poseScene,
                    camera: camera
                ))
                try applyAuthoringMaterials(
                    target: target,
                    subjectRoot: poseScene.angel.root,
                    pass: .binaryMask,
                    projectionMaskTexture: projectionMaskTexture
                )
                try AngelBlendShapePoseCapture.assign(weight, bindings: bindings)
                coverages.append(try await renderer.render(
                    scene: poseScene,
                    camera: camera,
                    toneMappingEnabled: false,
                    pixelFormat: .bgra8Unorm
                ))
                poseScene.release(
                    reason: "projectionAuthoring.geometryPose.\(pose.rawValue).complete"
                )
            } catch {
                poseScene.release(
                    reason: "projectionAuthoring.geometryPose.\(pose.rawValue).failed"
                )
                throw error
            }
        }

        let beautyStateHashes = Set(beauties.map {
            MindEyeProjectionExportStore.sha256($0.bgra8)
        })
        let coverageStateHashes = Set(coverages.map {
            MindEyeProjectionExportStore.sha256($0.bgra8)
        })
        guard beautyStateHashes.count == AngelBlendShapePoseCapture.orderedGeometryPoses.count else {
            throw MindEyeProjectionError.invalidCapture(
                "blendshape pose beauty renders are not four distinct geometry states"
            )
        }
        guard coverageStateHashes.count >= 2 else {
            throw MindEyeProjectionError.invalidCapture(
                "blendshape projection coverage does not respond to geometry deformation"
            )
        }

        for (pose, weight) in AngelBlendShapePoseCapture.orderedGeometryPoses {
            let suffix: String
            switch pose {
            case .rest: suffix = "rest_000"
            case .small: suffix = "small_033"
            case .round: suffix = "round_050"
            case .wide: suffix = "wide_100"
            case .teeth:
                preconditionFailure("teeth aliases rest and is not captured separately")
            }
            let beautyFilename = "\(directory)/angel_head_v1_geometry-\(suffix).png"
            let coverageFilename = "\(directory)/angel_head_v1_coverage-\(suffix).png"
            manifestPoses.append(.init(
                semanticPose: pose,
                geometryWeight: weight,
                beautyFilename: beautyFilename,
                coverageFilename: coverageFilename
            ))
            outputs.append((
                "geometryPoseBeauty.\(pose.rawValue)", beautyFilename,
                8, "sRGB", "opaque", 1_728, 1_728
            ))
            outputs.append((
                "geometryPoseCoverage.\(pose.rawValue)", coverageFilename,
                8, "linearRGB", "opaque", 1_728, 1_728
            ))
        }

        let unionCoverage = Self.unionCoverage(coverages)
        let processedUnion = try await Task.detached(priority: .userInitiated) {
            try MindEyeProjectionMaskProcessor.process(
                unionCoverage,
                inset: 12,
                feather: 32
            )
        }.value
        try MindEyeProjectionValidation.validateAuthoredMaskForLockedCrop(
            processedUnion.metrics
        )
        let contactSheet = Self.makeContactSheet(beauties)
        let deformationHeatmap = Self.makeDeformationHeatmap(
            rest: beauties[0],
            wide: beauties[3]
        )

        let unionFilename = "\(directory)/angel_head_v1_projection-mask-union-linear16.png"
        let unionPreviewFilename = "\(directory)/angel_head_v1_projection-mask-union-preview.png"
        let contactFilename = "\(directory)/angel_head_v1_geometry-pose-contact-sheet.png"
        let heatmapFilename = "\(directory)/angel_head_v1_geometry-displacement-heatmap.png"
        let poseManifestFilename = "\(directory)/angel_head_v1_geometry-pose-manifest.json"
        let poseManifest = AngelBlendShapePoseCaptureManifest(
            schemaVersion: 1,
            blendShapeName: "jawOpenProjection",
            projectorCameraSHA256: cameraSHA256,
            poses: manifestPoses,
            teethGeometryAlias: .rest,
            unionMaskFilename: unionFilename
        )

        var beautyURLs: [(URL, URL)] = []
        for pose in manifestPoses {
            beautyURLs.append((
                await store.url(pose.beautyFilename),
                await store.url(pose.coverageFilename)
            ))
        }
        let unionURL = await store.url(unionFilename)
        let unionPreviewURL = await store.url(unionPreviewFilename)
        let contactURL = await store.url(contactFilename)
        let heatmapURL = await store.url(heatmapFilename)
        try await Task.detached(priority: .userInitiated) {
            for index in beauties.indices {
                try MindEyeProjectionPNGWriter.writeBGRA8(
                    beauties[index], to: beautyURLs[index].0
                )
                try MindEyeProjectionPNGWriter.writeBGRA8(
                    coverages[index], to: beautyURLs[index].1
                )
            }
            try MindEyeProjectionPNGWriter.writeGray16(
                processedUnion.linear16, width: 1_728, height: 1_728, to: unionURL
            )
            try MindEyeProjectionPNGWriter.writeGray8(
                processedUnion.preview8, width: 1_728, height: 1_728, to: unionPreviewURL
            )
            try MindEyeProjectionPNGWriter.writeBGRA8(contactSheet, to: contactURL)
            try MindEyeProjectionPNGWriter.writeBGRA8(deformationHeatmap, to: heatmapURL)
        }.value
        try await store.write(poseManifest, filename: poseManifestFilename)

        outputs.append(contentsOf: [
            ("geometryUnionMaskLinear16", unionFilename, 16, "linearGray", "none", 1_728, 1_728),
            ("geometryUnionMaskPreview", unionPreviewFilename, 8, "gray", "none", 1_728, 1_728),
            ("geometryContactSheet", contactFilename, 8, "sRGB", "opaque", 3_456, 3_456),
            ("geometryDeformationHeatmap", heatmapFilename, 8, "sRGB", "opaque", 1_728, 1_728),
            ("geometryPoseManifest", poseManifestFilename, 8, "UTF-8", "none", 0, 0),
        ])
        return outputs
    }

    private func makeScene(mode: Chapter03LightTunnelSceneMode) async throws -> Chapter03LightTunnelSceneBundle {
        let definition = try TuringResourceLoader.decodeResource(
            Chapter03LightTunnelDefinition.self,
            resourcePath: Chapter03LightTunnelDefinitionStore.resourcePath
        )
        try definition.validate()
        let resources: Chapter03LightTunnelSceneFactory.HeavenResources
        if let cachedHeavenResources {
            resources = cachedHeavenResources
        } else {
            let loaded = try factory.loadHeavenResources()
            cachedHeavenResources = loaded
            resources = loaded
        }
        return try await factory.make(
            runID: UUID(), definition: definition.visual,
            originFromDevice: matrix_identity_float4x4,
            mode: mode,
            resources: resources
        )
    }

    private func loadContracts() throws -> (
        MindEyeProjectionProfile,
        MindEyeProjectionTargetDescriptor,
        (profile: String, target: String, scene: String, subject: String, heaven: String)
    ) {
        let locator = try MindEyeResourceLocator.applicationBundle()
        let store = MindEyeProjectionCameraStore(locator: locator)
        let profilePath = "Turing/MindsEye/Projection/profiles/angel_head_v1.json"
        let profile = try store.loadProfile(resourcePath: profilePath)
        let target = try store.loadTarget(resourcePath: profile.targetResourcePath)
        let (_, profileHash) = try store.dataAndSHA256(resourcePath: profilePath)
        let (_, targetHash) = try store.dataAndSHA256(resourcePath: profile.targetResourcePath)
        let (_, sceneHash) = try store.dataAndSHA256(resourcePath: Chapter03LightTunnelDefinitionStore.resourcePath)
        let subjectURL = Bundle.main.url(forResource: "angel_posed_01", withExtension: "usdz")!
        let heavenURL = Bundle.main.url(forResource: "heaven-sunrise", withExtension: "exr")!
        return (profile, target, (
            profileHash, targetHash, sceneHash,
            try MindEyeProjectionExportStore.sha256(file: subjectURL),
            try MindEyeProjectionExportStore.sha256(file: heavenURL)
        ))
    }

    private func applyAuthoringMaterials(
        target: MindEyeProjectionTargetDescriptor,
        subjectRoot: Entity,
        pass: MindEyeProjectionRenderPass,
        projectionMaskTexture: TextureResource? = nil
    ) throws {
        let resolution = try MindEyeProjectionTargetResolver.resolve(descriptor: target, subjectRoot: subjectRoot)
        let selected = Set(resolution.materials.map { "\($0.entityPath)#\($0.materialIndex)" })
        var black = UnlitMaterial(); black.color = .init(tint: .black)
        var white = UnlitMaterial(); white.color = .init(tint: .white)
        let projectionMaskMaterial: UnlitMaterial?
        if let projectionMaskTexture {
            var material = UnlitMaterial(texture: projectionMaskTexture)
            material.blending = .opaque
            projectionMaskMaterial = material
        } else {
            projectionMaskMaterial = nil
        }
        if pass == .binaryMask, projectionMaskMaterial == nil {
            throw MindEyeProjectionError.invalidCapture(
                "projection-mask texture is unavailable for the AOV pass"
            )
        }
        visitModels(subjectRoot, path: subjectRoot.name) { entity, path, model in
            var model = model
            model.materials = model.materials.enumerated().map { index, material -> any Material in
                let isTarget = selected.contains("\(path)#\(index)")
                switch pass {
                case .faceBeauty:
                    return isTarget ? material : black
                case .binaryMask:
                    return isTarget ? projectionMaskMaterial! : black
                case .binaryCoverage:
                    return isTarget ? white : black
                case .sceneBeauty:
                    return material
                }
            }
            entity.components.set(model)
        }
    }

    private func visitModels(
        _ entity: Entity,
        path: String,
        body: (Entity, String, ModelComponent) -> Void
    ) {
        if let model = entity.components[ModelComponent.self] { body(entity, path, model) }
        for child in entity.children {
            visitModels(child, path: path + "/" + child.name, body: body)
        }
    }

    nonisolated private static func unionCoverage(
        _ buffers: [MindEyeProjectionPixelBuffer]
    ) -> MindEyeProjectionPixelBuffer {
        precondition(buffers.count == 4)
        let width = 1_728
        let height = 1_728
        let bytesPerRow = width * 4
        var output = Data(repeating: 0, count: bytesPerRow * height)
        let isolated = buffers.map {
            MindEyeProjectionMaskProcessor.isolatedForeground(
                $0,
                foregroundIsDark: true
            )
        }
        output.withUnsafeMutableBytes { destinationRaw in
            guard let destination = destinationRaw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let visible = isolated.contains { $0[index] }
                    let pixel = destination + y * bytesPerRow + x * 4
                    let value: UInt8 = visible ? 255 : 0
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                    pixel[3] = 255
                }
            }
        }
        return .init(width: width, height: height, bytesPerRow: bytesPerRow, bgra8: output)
    }

    nonisolated private static func makeContactSheet(
        _ buffers: [MindEyeProjectionPixelBuffer]
    ) -> MindEyeProjectionPixelBuffer {
        precondition(buffers.count == 4)
        let tile = 1_728
        let width = tile * 2
        let height = tile * 2
        let bytesPerRow = width * 4
        var output = Data(repeating: 0, count: bytesPerRow * height)
        output.withUnsafeMutableBytes { destinationRaw in
            guard let destination = destinationRaw.baseAddress else { return }
            for (index, buffer) in buffers.enumerated() {
                let originX = (index % 2) * tile
                let originY = (index / 2) * tile
                buffer.bgra8.withUnsafeBytes { sourceRaw in
                    guard let source = sourceRaw.baseAddress else { return }
                    for y in 0..<tile {
                        let sourceRow = source.advanced(by: y * buffer.bytesPerRow)
                        let destinationRow = destination.advanced(
                            by: (originY + y) * bytesPerRow + originX * 4
                        )
                        destinationRow.copyMemory(from: sourceRow, byteCount: tile * 4)
                    }
                }
            }
        }
        return .init(width: width, height: height, bytesPerRow: bytesPerRow, bgra8: output)
    }

    nonisolated private static func makeDeformationHeatmap(
        rest: MindEyeProjectionPixelBuffer,
        wide: MindEyeProjectionPixelBuffer
    ) -> MindEyeProjectionPixelBuffer {
        let width = 1_728
        let height = 1_728
        let bytesPerRow = width * 4
        var output = Data(repeating: 0, count: bytesPerRow * height)
        output.withUnsafeMutableBytes { destinationRaw in
            rest.bgra8.withUnsafeBytes { restRaw in
                wide.bgra8.withUnsafeBytes { wideRaw in
                    guard let destination = destinationRaw.bindMemory(to: UInt8.self).baseAddress,
                          let restBytes = restRaw.bindMemory(to: UInt8.self).baseAddress,
                          let wideBytes = wideRaw.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    for y in 0..<height {
                        for x in 0..<width {
                            let restPixel = restBytes + y * rest.bytesPerRow + x * 4
                            let widePixel = wideBytes + y * wide.bytesPerRow + x * 4
                            let difference = max(
                                abs(Int(restPixel[0]) - Int(widePixel[0])),
                                max(
                                    abs(Int(restPixel[1]) - Int(widePixel[1])),
                                    abs(Int(restPixel[2]) - Int(widePixel[2]))
                                )
                            )
                            let amplified = UInt8(min(255, difference * 3))
                            let pixel = destination + y * bytesPerRow + x * 4
                            pixel[0] = 0
                            pixel[1] = amplified / 4
                            pixel[2] = amplified
                            pixel[3] = 255
                        }
                    }
                }
            }
        }
        return .init(width: width, height: height, bytesPerRow: bytesPerRow, bgra8: output)
    }

    nonisolated private static func makeAlignmentGuide(
        faceBeauty: MindEyeProjectionPixelBuffer,
        mask: [UInt8]
    ) -> MindEyeProjectionPixelBuffer {
        var data = faceBeauty.bgra8
        data.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            func overlay(_ x: Int, _ y: Int, b: UInt8, g: UInt8, r: UInt8) {
                guard x >= 0, y >= 0, x < 1_728, y < 1_728 else { return }
                let p = bytes + y * faceBeauty.bytesPerRow + x * 4
                p[0] = UInt8((Int(p[0]) + Int(b)) / 2)
                p[1] = UInt8((Int(p[1]) + Int(g)) / 2)
                p[2] = UInt8((Int(p[2]) + Int(r)) / 2)
                p[3] = 255
            }
            for y in 0..<1_728 {
                for x in 0..<1_728 {
                    let index = y * 1_728 + x
                    let boundary = x == 144 || y == 144 || x == 1_583 || y == 1_583
                    let grid = x % 144 == 0 || y % 144 == 0
                    let center = x == 864 || y == 864
                    let contour = mask[index] > 0 && (
                        x == 0 || y == 0 || x == 1_727 || y == 1_727 ||
                        mask[index - (x > 0 ? 1 : 0)] == 0 ||
                        mask[index + (x < 1_727 ? 1 : 0)] == 0 ||
                        mask[index - (y > 0 ? 1_728 : 0)] == 0 ||
                        mask[index + (y < 1_727 ? 1_728 : 0)] == 0
                    )
                    if boundary { overlay(x, y, b: 0, g: 255, r: 255) }
                    else if center { overlay(x, y, b: 255, g: 255, r: 0) }
                    else if contour { overlay(x, y, b: 0, g: 0, r: 255) }
                    else if grid { overlay(x, y, b: 80, g: 80, r: 80) }
                }
            }
        }
        return .init(width: faceBeauty.width, height: faceBeauty.height,
                     bytesPerRow: faceBeauty.bytesPerRow, bgra8: data)
    }

    /// The production Angel currently has one whole-body mesh/material. The
    /// owner-authored face cube therefore supplies both the camera framing and
    /// the spatial boundary for the flat projection-mask-texture AOV.
    nonisolated private static func clipProjectionMaskAOVToFramingCube(
        _ buffer: MindEyeProjectionPixelBuffer,
        camera: MindEyeProjectionCameraDescriptor,
        target: MindEyeProjectionTargetDescriptor
    ) throws -> MindEyeProjectionPixelBuffer {
        guard let control = target.authoringFramingControl else {
            throw MindEyeProjectionError.invalidCapture(
                "owner-authored face cube is missing from the target descriptor"
            )
        }
        try control.validate()
        let center = SIMD3<Float>(
            control.centerSubjectMeters[0],
            control.centerSubjectMeters[1],
            control.centerSubjectMeters[2]
        )
        let right = SIMD3<Float>(
            control.rightAxisSubject[0],
            control.rightAxisSubject[1],
            control.rightAxisSubject[2]
        )
        let up = SIMD3<Float>(
            control.upAxisSubject[0],
            control.upAxisSubject[1],
            control.upAxisSubject[2]
        )
        let forward = SIMD3<Float>(
            control.forwardAxisSubject[0],
            control.forwardAxisSubject[1],
            control.forwardAxisSubject[2]
        )
        let halfExtents = SIMD3<Float>(
            control.halfExtentsMeters[0],
            control.halfExtentsMeters[1],
            control.halfExtentsMeters[2]
        )
        var projected: [SIMD3<Float>] = []
        for x in [-halfExtents.x, halfExtents.x] {
            for y in [-halfExtents.y, halfExtents.y] {
                for z in [-halfExtents.z, halfExtents.z] {
                    if let uv = MindEyeProjectionCameraMath.projectorUV(
                        subjectPosition: center + right * x + up * y + forward * z,
                        clipFromSubject: camera.clipFromSubjectMatrix
                    ) {
                        projected.append(uv)
                    }
                }
            }
        }
        guard projected.count == 8 else {
            throw MindEyeProjectionError.invalidCapture(
                "owner-authored face cube does not project into the capture camera"
            )
        }
        let minimumUV = projected.reduce(
            SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        ) { simd_min($0, SIMD2($1.x, $1.y)) }
        let maximumUV = projected.reduce(
            SIMD2<Float>(repeating: -Float.greatestFiniteMagnitude)
        ) { simd_max($0, SIMD2($1.x, $1.y)) }
        let minimumX = max(0, Int(floor(minimumUV.x * Float(buffer.width))))
        let minimumY = max(0, Int(floor(minimumUV.y * Float(buffer.height))))
        let maximumX = min(
            buffer.width - 1,
            Int(ceil(maximumUV.x * Float(buffer.width))) - 1
        )
        let maximumY = min(
            buffer.height - 1,
            Int(ceil(maximumUV.y * Float(buffer.height))) - 1
        )
        guard minimumX < maximumX, minimumY < maximumY else {
            throw MindEyeProjectionError.invalidCapture(
                "owner-authored face cube projects to an empty capture region"
            )
        }

        var data = buffer.bgra8
        data.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for y in 0..<buffer.height {
                let row = bytes + y * buffer.bytesPerRow
                for x in 0..<buffer.width
                    where x < minimumX || x > maximumX ||
                        y < minimumY || y > maximumY {
                    let pixel = row + x * 4
                    pixel[0] = 0
                    pixel[1] = 0
                    pixel[2] = 0
                    pixel[3] = 255
                }
            }
        }
        return .init(
            width: buffer.width,
            height: buffer.height,
            bytesPerRow: buffer.bytesPerRow,
            bgra8: data
        )
    }

    nonisolated private struct MaterialParityMeasurement: Sendable {
        let maskPixelCount: Int
        let RMSE: Double
        let p99: Double
        let maximum: Double
        let PSNR: Double
        let passed: Bool
        let diff: MindEyeProjectionPixelBuffer
    }

    nonisolated private static func measureMaterialParity(
        original: MindEyeProjectionPixelBuffer,
        replacement: MindEyeProjectionPixelBuffer,
        targetMask: MindEyeProjectionPixelBuffer
    ) throws -> MaterialParityMeasurement {
        guard original.width == replacement.width,
              original.height == replacement.height,
              original.width == targetMask.width,
              original.height == targetMask.height else {
            throw MindEyeProjectionError.invalidCapture(
                "material parity buffers have different dimensions"
            )
        }
        var errors: [Double] = []
        errors.reserveCapacity(original.width * original.height)
        var squaredError = 0.0
        var maximum = 0.0
        var maskPixelCount = 0
        var diffData = Data(
            repeating: 0,
            count: original.bytesPerRow * original.height
        )
        original.bgra8.withUnsafeBytes { originalRaw in
            replacement.bgra8.withUnsafeBytes { replacementRaw in
                targetMask.bgra8.withUnsafeBytes { maskRaw in
                    diffData.withUnsafeMutableBytes { diffRaw in
                        guard let originalBytes = originalRaw.bindMemory(
                            to: UInt8.self
                        ).baseAddress,
                        let replacementBytes = replacementRaw.bindMemory(
                            to: UInt8.self
                        ).baseAddress,
                        let maskBytes = maskRaw.bindMemory(to: UInt8.self).baseAddress,
                        let diffBytes = diffRaw.bindMemory(to: UInt8.self).baseAddress else {
                            return
                        }
                        for y in 0..<original.height {
                            let originalRow = originalBytes + y * original.bytesPerRow
                            let replacementRow = replacementBytes + y * replacement.bytesPerRow
                            let maskRow = maskBytes + y * targetMask.bytesPerRow
                            let diffRow = diffBytes + y * original.bytesPerRow
                            for x in 0..<original.width {
                                let offset = x * 4
                                let included = max(
                                    maskRow[offset],
                                    max(maskRow[offset + 1], maskRow[offset + 2])
                                ) >= 128
                                diffRow[offset + 3] = 255
                                guard included else { continue }
                                maskPixelCount += 1
                                for channel in 0..<3 {
                                    let left = linearSRGB(originalRow[offset + channel])
                                    let right = linearSRGB(replacementRow[offset + channel])
                                    let error = abs(left - right)
                                    errors.append(error)
                                    squaredError += error * error
                                    maximum = max(maximum, error)
                                    diffRow[offset + channel] = UInt8(
                                        min(255, Int((error * 1_024).rounded()))
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        guard maskPixelCount > 0, !errors.isEmpty else {
            throw MindEyeProjectionError.invalidCapture(
                "material parity target mask is empty"
            )
        }
        errors.sort()
        let RMSE = sqrt(squaredError / Double(errors.count))
        let p99Index = min(
            errors.count - 1,
            max(0, Int(ceil(Double(errors.count) * 0.99)) - 1)
        )
        let p99 = errors[p99Index]
        let PSNR = RMSE > 0 ? -20 * log10(RMSE) : 120
        let passed = RMSE <= 0.0075 && p99 <= 0.020 &&
            maximum <= 0.080 && PSNR >= 42
        return MaterialParityMeasurement(
            maskPixelCount: maskPixelCount,
            RMSE: RMSE,
            p99: p99,
            maximum: maximum,
            PSNR: PSNR,
            passed: passed,
            diff: .init(
                width: original.width,
                height: original.height,
                bytesPerRow: original.bytesPerRow,
                bgra8: diffData
            )
        )
    }

    nonisolated private static func linearSRGB(_ byte: UInt8) -> Double {
        let value = Double(byte) / 255
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}

nonisolated private extension SIMD3 where Scalar == Float {
    var array: [Float] { [x, y, z] }
}

nonisolated private extension JSONEncoder {
    static var canonical: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return value
    }
}
#endif
