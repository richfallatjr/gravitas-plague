#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation

nonisolated struct MindEyeProjectionAuthoringLaunchConfiguration: Sendable, Equatable {
    enum Job: String, Sendable {
        case inspectSubject = "inspect-subject"
        case resolveCamera = "resolve-camera"
        case captureReference = "capture-reference"
        case validateRuntimeProjection = "validate-runtime-projection"
    }

    let job: Job
    let captureID: String
    let outputRelativePath: String

    static func current(processInfo: ProcessInfo = .processInfo) throws -> Self? {
        try current(arguments: processInfo.arguments)
    }

    static func current(arguments: [String]) throws -> Self? {
        let jobPrefix = "--mind-eye-projection-job="
        guard let argument = arguments.first(where: { $0.hasPrefix(jobPrefix) }) else {
            return nil
        }
        let rawJob = String(argument.dropFirst(jobPrefix.count))
        guard let job = Job(rawValue: rawJob) else {
            throw MindEyeProjectionError.invalidAuthoringJob(rawJob)
        }
        let capturePrefix = "--mind-eye-projection-capture-id="
        let captureID = arguments.first(where: { $0.hasPrefix(capturePrefix) })
            .map { String($0.dropFirst(capturePrefix.count)) } ?? "angel_head_v1"
        guard captureID == "angel_head_v1" else {
            throw MindEyeProjectionError.invalidProfileID(captureID)
        }
        return Self(
            job: job,
            captureID: captureID,
            outputRelativePath: "MindEyeProjectionAuthoring/\(captureID)"
        )
    }
}
#endif
