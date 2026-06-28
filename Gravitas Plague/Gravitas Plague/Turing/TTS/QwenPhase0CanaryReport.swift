import Foundation

enum QwenPhase0CanaryStage: String, Codable, Sendable {
    case assetIntegrity
    case loadModel
    case preparePrompt
    case firstTalkerForward
    case sampleFirstToken
    case firstCodePredictorForward
    case sampleFirstCodeToken
    case decodeOneChunk
    case fullGenerate
    case writeWav
    case playbackSubmit
}

enum QwenPhase0CanaryStatus: String, Codable, Sendable {
    case notRun
    case passed
    case failedSwiftError
    case failedPreviousProcessAssert
}

struct QwenPhase0CanaryReport: Codable, Sendable, Equatable {
    let status: QwenPhase0CanaryStatus
    let lastCompletedStage: QwenPhase0CanaryStage?
    let lastStartedStage: QwenPhase0CanaryStage?
    let modelID: String
    let modelRevision: String
    let quantization: String
    let tokenizerRevision: String
    let packageBaseRevision: String
    let localPackagePatch: String
    let appBuild: String
    let osVersion: String
    let samplerMode: String
    let smokeText: String
    let language: String
    let voiceArgument: String?
    let refAudio: String?
    let refText: String?
    let failureSummary: String?
    let createdAt: Date

    var likelyPreviousProcessAssert: Bool {
        status != .passed &&
        lastStartedStage != nil &&
        lastStartedStage != lastCompletedStage
    }

    func matches(
        model: TuringModelDescriptor,
        smokeRequest: QwenPhase0SmokeRequest
    ) -> Bool {
        status == .passed &&
        modelID == model.id &&
        modelRevision == model.modelRevision &&
        quantization == model.quantization &&
        tokenizerRevision == model.tokenizerRevision &&
        packageBaseRevision == QwenPhase0CanaryIdentity.packageBaseRevision &&
        localPackagePatch == QwenPhase0CanaryIdentity.localPackagePatch &&
        samplerMode == QwenPhase0CanaryIdentity.samplerMode &&
        smokeText == smokeRequest.text &&
        language == smokeRequest.language &&
        voiceArgument == nil &&
        refAudio == nil &&
        refText == nil
    }

    func updating(
        status: QwenPhase0CanaryStatus,
        lastCompletedStage: QwenPhase0CanaryStage?,
        lastStartedStage: QwenPhase0CanaryStage?,
        failureSummary: String?
    ) -> QwenPhase0CanaryReport {
        QwenPhase0CanaryReport(
            status: status,
            lastCompletedStage: lastCompletedStage,
            lastStartedStage: lastStartedStage,
            modelID: modelID,
            modelRevision: modelRevision,
            quantization: quantization,
            tokenizerRevision: tokenizerRevision,
            packageBaseRevision: packageBaseRevision,
            localPackagePatch: localPackagePatch,
            appBuild: appBuild,
            osVersion: osVersion,
            samplerMode: samplerMode,
            smokeText: smokeText,
            language: language,
            voiceArgument: voiceArgument,
            refAudio: refAudio,
            refText: refText,
            failureSummary: failureSummary,
            createdAt: createdAt
        )
    }
}

enum QwenPhase0CanaryIdentity {
    static let packageBaseRevision = "3cfa97201572e438eece2036299383834473253f"
    static let localPackagePatch = "qwen3tts_phase0_host_sampler_breadcrumbs_forced"
    static let samplerMode = "hostSafeGreedy"

    static func makeReport(
        model: TuringModelDescriptor,
        smokeRequest: QwenPhase0SmokeRequest,
        status: QwenPhase0CanaryStatus = .notRun
    ) -> QwenPhase0CanaryReport {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let appBuild = [version, build]
            .compactMap { $0 }
            .joined(separator: "-")

        return QwenPhase0CanaryReport(
            status: status,
            lastCompletedStage: nil,
            lastStartedStage: nil,
            modelID: model.id,
            modelRevision: model.modelRevision,
            quantization: model.quantization,
            tokenizerRevision: model.tokenizerRevision,
            packageBaseRevision: packageBaseRevision,
            localPackagePatch: localPackagePatch,
            appBuild: appBuild.isEmpty ? "unknown" : appBuild,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            samplerMode: samplerMode,
            smokeText: smokeRequest.text,
            language: smokeRequest.language,
            voiceArgument: nil,
            refAudio: nil,
            refText: nil,
            failureSummary: nil,
            createdAt: Date()
        )
    }
}

actor QwenPhase0CanaryStore {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    static func defaultURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "TuringQwenPhase0CanaryReport.json"
        )
    }

    func load() throws -> QwenPhase0CanaryReport? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(
                QwenPhase0CanaryReport.self,
                from: data
            )
        } catch {
            let invalidURL = url.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent).invalid-\(Int(Date().timeIntervalSince1970)).json"
                )

            try? FileManager.default.moveItem(
                at: url,
                to: invalidURL
            )

            print(
                """
                [TuringTTS] ignored invalid Qwen canary report
                  path: \(url.path)
                  movedTo: \(invalidURL.path)
                  error: \(error.localizedDescription)
                  canaryBlocked: false
                """
            )

            return nil
        }
    }

    func markStarted(
        _ stage: QwenPhase0CanaryStage,
        report: QwenPhase0CanaryReport
    ) throws {
        try write(
            report.updating(
                status: .notRun,
                lastCompletedStage: report.lastCompletedStage,
                lastStartedStage: stage,
                failureSummary: nil
            )
        )
    }

    func markCompleted(
        _ stage: QwenPhase0CanaryStage
    ) throws {
        guard let report = try load() else {
            return
        }

        try write(
            report.updating(
                status: report.status,
                lastCompletedStage: stage,
                lastStartedStage: stage,
                failureSummary: report.failureSummary
            )
        )
    }

    func markPassed(
        finalStage: QwenPhase0CanaryStage
    ) throws {
        guard let report = try load() else {
            return
        }

        try write(
            report.updating(
                status: .passed,
                lastCompletedStage: finalStage,
                lastStartedStage: finalStage,
                failureSummary: nil
            )
        )
    }

    func markFailed(
        stage: QwenPhase0CanaryStage,
        error: Error
    ) throws {
        let report = try load()
        try write(
            (report ?? placeholderReport()).updating(
                status: .failedSwiftError,
                lastCompletedStage: report?.lastCompletedStage,
                lastStartedStage: stage,
                failureSummary: error.localizedDescription
            )
        )
    }

    private func write(
        _ report: QwenPhase0CanaryReport
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(
            to: url,
            options: [.atomic]
        )
    }

    private func placeholderReport() -> QwenPhase0CanaryReport {
        QwenPhase0CanaryReport(
            status: .failedSwiftError,
            lastCompletedStage: nil,
            lastStartedStage: nil,
            modelID: "unknown",
            modelRevision: "unknown",
            quantization: "unknown",
            tokenizerRevision: "unknown",
            packageBaseRevision: QwenPhase0CanaryIdentity.packageBaseRevision,
            localPackagePatch: QwenPhase0CanaryIdentity.localPackagePatch,
            appBuild: "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            samplerMode: QwenPhase0CanaryIdentity.samplerMode,
            smokeText: "unknown",
            language: "unknown",
            voiceArgument: nil,
            refAudio: nil,
            refText: nil,
            failureSummary: nil,
            createdAt: Date()
        )
    }
}
