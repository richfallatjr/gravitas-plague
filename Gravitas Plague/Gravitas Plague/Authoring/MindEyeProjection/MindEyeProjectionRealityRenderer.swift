#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import CoreGraphics
import Foundation
import Metal
import RealityKit

@MainActor
final class MindEyeProjectionRealityRenderer {
    private let device: any MTLDevice

    init(device: any MTLDevice) { self.device = device }

    func render(
        scene: Chapter03LightTunnelSceneBundle,
        camera: MindEyeProjectionCameraDescriptor,
        toneMappingEnabled: Bool = true,
        pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    ) async throws -> MindEyeProjectionPixelBuffer {
        let renderer = try RealityRenderer()
        let cameraEntity = Entity()
        cameraEntity.name = "MindEyeProjectionCamera"
        cameraEntity.components.set(PerspectiveCameraComponent(
            near: camera.nearMeters,
            far: camera.farMeters,
            fieldOfViewInDegrees: camera.fieldOfViewDegrees,
            fieldOfViewOrientation: .vertical
        ))
        scene.angel.root.addChild(cameraEntity)
        cameraEntity.setTransformMatrix(camera.subjectFromCameraMatrix, relativeTo: scene.angel.root)

        renderer.entities.append(contentsOf: [scene.root])
        renderer.activeCamera = cameraEntity
        renderer.lighting.resource = scene.environment
        renderer.lighting.intensityExponent = 0.5
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 1))
        renderer.cameraSettings.isToneMappingEnabled = toneMappingEnabled

        let target = try MindEyeProjectionRenderTarget(
            device: device,
            pixelFormat: pixelFormat
        )
        let output = try RealityRenderer.CameraOutput(
            .singleProjection(colorTexture: target.texture)
        )
        for _ in 0..<2 {
            try await renderAndAwait(renderer: renderer, output: output)
        }
        try await renderAndAwait(renderer: renderer, output: output)
        return try await MindEyeProjectionPixelReadback.read(texture: target.texture, device: device)
    }

    private func renderAndAwait(
        renderer: RealityRenderer,
        output: RealityRenderer.CameraOutput
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    do {
                        try renderer.updateAndRender(
                            deltaTime: 0,
                            cameraOutput: output,
                            onComplete: { _ in continuation.resume(returning: ()) }
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw MindEyeProjectionError.renderTimedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
#endif
