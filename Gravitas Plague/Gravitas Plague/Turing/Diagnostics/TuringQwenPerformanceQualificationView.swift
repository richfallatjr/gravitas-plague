#if GR_QWEN_PERFORMANCE_QUALIFICATION
import Foundation
import SwiftUI
import TuringQwenNative

/// Explicit qualification builds only. No developer button or shipping entry.
/// The ordinary app path is untouched unless this build AND launch opt in.
nonisolated enum TuringQwenPerformanceQualificationLaunch {
    static var requested: Bool {
        ProcessInfo.processInfo.environment["QWEN_PERFORMANCE_REQUEST"] != nil
    }

    nonisolated struct Request: Decodable, Sendable {
        let workload: TuringQwenPerformanceWorkload
        let mode: String
        let policy: TuringQwenNativeExecutionPolicy?
        let profilerState: String
        let phaseMarkers: Bool
        let outputFilename: String
    }

    static func run() async throws -> String {
        guard let name = ProcessInfo.processInfo.environment["QWEN_PERFORMANCE_REQUEST"],
              name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".json") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("QwenQualification", isDirectory: true)
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
        guard request.outputFilename == URL(fileURLWithPath: request.outputFilename).lastPathComponent,
              request.outputFilename.hasSuffix(".json"),
              let mode = TuringQwenBoundedBenchmark.Mode(rawValue: request.mode),
              let resources = Bundle.main.resourceURL else { throw CocoaError(.coderReadCorrupt) }
        let output = directory.appendingPathComponent(request.outputFilename)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let model = resources.appendingPathComponent("Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit")
        let report = try await TuringQwenNativePhaseDiagnostics.$enabled.withValue(request.phaseMarkers) {
            try await TuringQwenBoundedBenchmark.run(options: .init(
                modelRoot: model, bundleRoot: resources, workload: request.workload, mode: mode,
                commandBufferProfile: .operations40Megabytes32, profilerState: request.profilerState,
                sceneCondition: "isolated-device-qualification-no-immersive-scene", policy: request.policy ?? .production))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output, options: .atomic)
        print("[QwenQualification] \(report.outcome) report=\(output.path)")
        return "\(report.outcome)\n\(request.outputFilename)\nNot release-qualified."
    }
}

/// A second window or SwiftUI task restart observes the same bounded run rather
/// than creating a second set of generation lanes in the qualification process.
private actor TuringQwenPerformanceQualificationRunner {
    static let shared = TuringQwenPerformanceQualificationRunner()
    private var task: Task<String, Error>?

    func runOnce() async throws -> String {
        if let task { return try await task.value }
        let work = Task.detached(priority: .userInitiated) {
            try await TuringQwenPerformanceQualificationLaunch.run()
        }
        task = work
        return try await work.value
    }
}

struct TuringQwenPerformanceQualificationView: View {
    @State private var result = "Bounded Qwen qualification running. Keep the headset awake."
    var body: some View {
        Text(result).padding(40).task {
            // Blocking identity reads and compute never run on MainActor.
            do { result = try await TuringQwenPerformanceQualificationRunner.shared.runOnce() }
            catch { result = "Qualification stopped: \(error.localizedDescription)" }
        }
    }
}
#endif
