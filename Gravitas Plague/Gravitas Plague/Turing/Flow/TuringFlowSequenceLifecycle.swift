import Foundation

protocol TuringFlowSequenceLifecycleControlling:
    Sendable
{
    func begin(
        sequenceID: UUID,
        initialDescriptor:
            TuringFlowDescriptor
    ) async throws

    func pointWillBegin(
        sequenceID: UUID,
        descriptor:
            TuringFlowDescriptor
    ) async throws

    func pointDidFinish(
        sequenceID: UUID,
        descriptor:
            TuringFlowDescriptor,
        succeeded: Bool,
        hasAutomaticSuccessor:
            Bool
    ) async

    func end(
        sequenceID: UUID,
        finalDescriptor:
            TuringFlowDescriptor?,
        succeeded: Bool,
        reason: String
    ) async
}

actor TuringNoOpSequenceLifecycle:
    TuringFlowSequenceLifecycleControlling
{
    func begin(
        sequenceID: UUID,
        initialDescriptor:
            TuringFlowDescriptor
    ) async throws {
    }

    func pointWillBegin(
        sequenceID: UUID,
        descriptor:
            TuringFlowDescriptor
    ) async throws {
    }

    func pointDidFinish(
        sequenceID: UUID,
        descriptor:
            TuringFlowDescriptor,
        succeeded: Bool,
        hasAutomaticSuccessor:
            Bool
    ) async {
    }

    func end(
        sequenceID: UUID,
        finalDescriptor:
            TuringFlowDescriptor?,
        succeeded: Bool,
        reason: String
    ) async {
    }
}

protocol TuringFlowSequenceLifecycleResolving:
    Sendable
{
    func lifecycle(
        for surface:
            StoryInteractionSurfaceID
    ) async
        -> any
        TuringFlowSequenceLifecycleControlling
}

struct TuringDefaultFlowSequenceLifecycleResolver:
    TuringFlowSequenceLifecycleResolving,
    Sendable
{
    private let noOp:
        TuringNoOpSequenceLifecycle
    private let hamReceiver:
        TuringHamReceiverSequenceLifecycle

    init(
        noOp:
            TuringNoOpSequenceLifecycle =
                TuringNoOpSequenceLifecycle(),
        hamReceiver:
            TuringHamReceiverSequenceLifecycle =
                TuringHamReceiverSequenceLifecycle(
                    bed:
                        TuringHamReceiverBedActor
                            .shared
                )
    ) {
        self.noOp = noOp
        self.hamReceiver = hamReceiver
    }

    func lifecycle(
        for surface:
            StoryInteractionSurfaceID
    ) async
        -> any
        TuringFlowSequenceLifecycleControlling
    {
        if surface == .hamReceiver {
            return hamReceiver
        }
        return noOp
    }
}
