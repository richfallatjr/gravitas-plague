import Foundation
@testable import Gravitas_Plague

func mindEyeProjectionRepositoryRoot(file: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: String(describing: file))
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
}

func mindEyeProjectionResourceData(_ relativePath: String) throws -> Data {
    try Data(contentsOf: mindEyeProjectionRepositoryRoot().appendingPathComponent(relativePath))
}

func mindEyeProjectionProfileFixture() throws -> MindEyeProjectionProfile {
    try JSONDecoder().decode(
        MindEyeProjectionProfile.self,
        from: mindEyeProjectionResourceData(
            "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/profiles/angel_head_v1.json"
        )
    )
}

func mindEyeProjectionCameraFixture() throws -> MindEyeProjectionCameraDescriptor {
    try JSONDecoder().decode(
        MindEyeProjectionCameraDescriptor.self,
        from: mindEyeProjectionResourceData(
            "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/cameras/angel_head_v1.camera.json"
        )
    )
}

func mindEyeProjectionTargetFixture() throws -> MindEyeProjectionTargetDescriptor {
    try JSONDecoder().decode(
        MindEyeProjectionTargetDescriptor.self,
        from: mindEyeProjectionResourceData(
            "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/targets/angel_head_v1.target.json"
        )
    )
}

func mindEyeProjectionManifestFixture(captureID: String = "angel_head_v1") -> MindEyeProjectionCaptureManifest {
    MindEyeProjectionCaptureManifest(
        schemaVersion: 1,
        captureID: captureID,
        repositoryCommit: "test",
        worktreeWasDirty: true,
        appBuildConfiguration: "test",
        SDKBuild: "test",
        simulatorRuntime: "test",
        simulatorDevice: "test",
        profileID: "angel_head_v1",
        profileSHA256: String(repeating: "a", count: 64),
        cameraID: "angel_head_v1.camera",
        cameraSHA256: String(repeating: "b", count: 64),
        targetSHA256: String(repeating: "c", count: 64),
        subjectAssetSHA256: String(repeating: "d", count: 64),
        heavenEXRSHA256: String(repeating: "e", count: 64),
        sceneDefinitionSHA256: String(repeating: "f", count: 64),
        sourceWidth: 1_728,
        sourceHeight: 1_728,
        viewportWidth: 1_440,
        viewportHeight: 1_440,
        captureState: "frameZero",
        mediaTimeSeconds: 0,
        animationAdvancedFrames: 0,
        beautyPixelFormat: "bgra8Unorm_srgb",
        maskPixelFormat: "bgra8Unorm",
        maskCoverageFraction: 0.25,
        maskBoundingBoxPixels: [500, 500, 728, 728],
        maskCenterErrorPixels: [0, 0],
        outputs: []
    )
}
