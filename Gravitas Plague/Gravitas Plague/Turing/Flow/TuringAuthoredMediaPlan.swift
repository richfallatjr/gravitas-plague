import Foundation

nonisolated struct TuringAuthoredMediaItem: Sendable, Equatable {
    enum Role: String, Sendable, Equatable {
        case openingCue
        case primaryPrerecording
        case authoredBridge
        case closingBumper
    }

    let id: String
    let role: Role
    let fileURL: URL
}

nonisolated struct TuringAuthoredMediaPlan: Sendable, Equatable {
    let scriptPointID: String
    let items: [TuringAuthoredMediaItem]
}

struct TuringAuthoredMediaPlanResolver: Sendable {
    private let prerecordingStore: any TuringPrerecordingLoading

    init(
        prerecordingStore: any TuringPrerecordingLoading =
            TuringPrerecordingStore()
    ) {
        self.prerecordingStore = prerecordingStore
    }

    func resolve(
        descriptor: TuringFlowDescriptor,
        treatment: StoryPlayModeTreatment
    ) throws -> TuringAuthoredMediaPlan {
        let ids: [(String, TuringAuthoredMediaItem.Role)]
        switch treatment.authoredMediaPolicy {
        case .standard:
            var ordered: [(String, TuringAuthoredMediaItem.Role)] = [
                (descriptor.transmission.prerecordingID, .primaryPrerecording)
            ]
            if let stages = descriptor.transmission.generationPipeline?.stages {
                ordered.append(contentsOf: stages.compactMap { stage in
                    stage.authoredPrerecordingAfterStageID.map {
                        ($0, .authoredBridge)
                    }
                })
            }
            ids = ordered
        case .replaceWithPrerecordings(let replacements):
            ids = replacements.map { ($0, .authoredBridge) }
        }

        var seen = Set<String>()
        let items = try ids.compactMap { id, role -> TuringAuthoredMediaItem? in
            guard id != "none", seen.insert(id).inserted else { return nil }
            let recording = try prerecordingStore.descriptor(id: id)
            return TuringAuthoredMediaItem(
                id: id,
                role: role,
                fileURL: try prerecordingStore.audioURL(for: recording)
            )
        }
        guard items.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Play mode found no authored media for \(descriptor.scriptPointID)."
            )
        }
        return TuringAuthoredMediaPlan(
            scriptPointID: descriptor.scriptPointID,
            items: items
        )
    }
}

