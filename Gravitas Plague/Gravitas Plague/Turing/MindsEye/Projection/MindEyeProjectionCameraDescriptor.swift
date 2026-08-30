import Foundation
import simd

nonisolated struct MindEyeProjectionCameraDescriptor: Codable, Sendable, Equatable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let cameraID: String
    let profileID: String
    let imageWidth: Int
    let imageHeight: Int
    let nearMeters: Float
    let farMeters: Float
    let fieldOfViewDegrees: Float
    let fieldOfViewOrientation: String
    let subjectFromCamera: [Float]
    let clipFromCamera: [Float]
    let clipFromSubject: [Float]
    let targetCenterSubjectMeters: [Float]
    let targetBoundsMinimumSubjectMeters: [Float]
    let targetBoundsMaximumSubjectMeters: [Float]
    let framingPadding: Float
    let sourceCropOrigin: [Int]
    let sourceCropSize: [Int]
    let sceneDefinitionSHA256: String
    let subjectAssetSHA256: String
    let targetDescriptorSHA256: String
    let cameraMathVersion: String

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion,
              cameraID == "angel_head_v1.camera", profileID == "angel_head_v1",
              imageWidth == 1_728, imageHeight == 1_728,
              nearMeters > 0, farMeters > nearMeters,
              (15...60).contains(fieldOfViewDegrees),
              fieldOfViewOrientation == "vertical",
              subjectFromCamera.count == 16,
              clipFromCamera.count == 16,
              clipFromSubject.count == 16,
              targetCenterSubjectMeters.count == 3,
              targetBoundsMinimumSubjectMeters.count == 3,
              targetBoundsMaximumSubjectMeters.count == 3,
              sourceCropOrigin == [144, 144], sourceCropSize == [1_440, 1_440],
              framingPadding >= 1,
              !sceneDefinitionSHA256.isEmpty,
              !subjectAssetSHA256.isEmpty,
              !targetDescriptorSHA256.isEmpty,
              !cameraMathVersion.isEmpty else {
            throw MindEyeProjectionError.invalidCameraDescriptor
        }
        let values = subjectFromCamera + clipFromCamera + clipFromSubject +
            targetCenterSubjectMeters + targetBoundsMinimumSubjectMeters +
            targetBoundsMaximumSubjectMeters
        guard values.allSatisfy(\.isFinite) else {
            throw MindEyeProjectionError.nonfiniteCameraDescriptor
        }
    }

    var subjectFromCameraMatrix: simd_float4x4 { simd_float4x4(columnMajor: subjectFromCamera) }
    var clipFromCameraMatrix: simd_float4x4 { simd_float4x4(columnMajor: clipFromCamera) }
    var clipFromSubjectMatrix: simd_float4x4 { simd_float4x4(columnMajor: clipFromSubject) }
}

nonisolated extension simd_float4x4 {
    init(columnMajor values: [Float]) {
        precondition(values.count == 16)
        self.init(
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        )
    }

    var columnMajorValues: [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
            .map { $0 == 0 ? 0 : $0 }
    }
}
