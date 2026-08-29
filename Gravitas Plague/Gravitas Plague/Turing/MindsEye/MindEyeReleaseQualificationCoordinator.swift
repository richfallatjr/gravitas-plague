import Foundation

#if GR_MIND_EYE_QUALIFICATION
@MainActor
final class MindEyeReleaseQualificationCoordinator {
    typealias SnapshotProvider = @MainActor () async -> MindEyeReleaseResourceSnapshot

    private let recorder: MindEyeReleaseQualificationRecorder
    private let snapshotProvider: SnapshotProvider
    private var observationTasks: [Task<Void, Never>] = []
    private var isActive = false

    init(
        recorder: MindEyeReleaseQualificationRecorder = .shared,
        snapshotProvider: @escaping SnapshotProvider
    ) {
        self.recorder = recorder
        self.snapshotProvider = snapshotProvider
    }

    func beginFromLaunchArgumentsIfRequested() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard let scenario = Self.value(prefix: "--mind-eye-qualification-scenario=", in: arguments)
            .flatMap(MindEyeReleaseScenario.init(rawValue:)),
              let configuration = Self.value(prefix: "--mind-eye-qualification-configuration=", in: arguments)
            .flatMap(MindEyeQualificationBuildConfiguration.init(rawValue:)) else {
            return
        }
        let sequence = Self.value(prefix: "--mind-eye-qualification-sequence=", in: arguments)
            .flatMap(Int.init) ?? 0
        let runID = Self.value(prefix: "--mind-eye-qualification-run-id=", in: arguments)
            .flatMap(UUID.init(uuidString:)) ?? UUID()
        try await recorder.begin(run: .init(
            id: runID,
            scenario: scenario,
            configuration: configuration,
            sequenceNumber: sequence
        ))
        isActive = true
    }

    func record(
        _ checkpoint: MindEyeQualificationCheckpoint,
        playbackRunID: String? = nil,
        mediaIdentity: String? = nil,
        speakerCharacterID: String? = nil,
        interactionSurface: String? = nil,
        timing: MindEyeReleaseTimingSnapshot = .empty,
        notes: [String] = []
    ) async {
        guard isActive else { return }
        let resource = await snapshotProvider()
        try? await recorder.record(
            checkpoint: checkpoint,
            playbackRunID: playbackRunID,
            mediaIdentity: mediaIdentity,
            speakerCharacterID: speakerCharacterID,
            interactionSurface: interactionSurface,
            resource: resource,
            timing: timing,
            notes: notes
        )
    }

    func scheduleReleaseObservations() {
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll(keepingCapacity: true)
        let schedule: [(Duration, MindEyeQualificationCheckpoint)] = [
            (.seconds(2), .twoSecondsAfterRelease),
            (.seconds(5), .fiveSecondsAfterRelease),
            (.seconds(15), .fifteenSecondsAfterRelease),
            (.seconds(30), .thirtySecondsAfterRelease)
        ]
        for (delay, checkpoint) in schedule {
            observationTasks.append(Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.record(checkpoint)
            })
        }
    }

    func finishAndExport() async throws -> URL? {
        guard isActive else { return nil }
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll(keepingCapacity: false)
        let report = try await recorder.finish()
        isActive = false
        let data = try report.deterministicJSONData()
        let manager = FileManager.default
        guard let applicationSupport = manager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MindEyeReleaseQualificationError.exportUnavailable
        }
        let directory = applicationSupport.appendingPathComponent(
            "MindEyeQualification",
            isDirectory: true
        )
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "\(report.run.id.uuidString.lowercased()).qualification.json"
        )
        try data.write(to: file, options: .atomic)
        print("[MindEyeQualification] report=\(file.absoluteString)")
        return file
    }

    func cancel() async {
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll(keepingCapacity: false)
        isActive = false
        await recorder.cancel()
    }

    private static func value(prefix: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) }).map {
            String($0.dropFirst(prefix.count))
        }
    }
}
#endif
