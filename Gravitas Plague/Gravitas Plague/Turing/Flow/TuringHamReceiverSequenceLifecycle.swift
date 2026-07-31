import Foundation

actor TuringHamReceiverSequenceLifecycle:
    TuringFlowSequenceLifecycleControlling
{
    private let bed:
        any TuringHamReceiverBedControlling

    private var activeSequenceID:
        UUID?
    private var activeOwnerID:
        String?

    init(
        bed:
            any TuringHamReceiverBedControlling
    ) {
        self.bed = bed
    }

    func begin(
        sequenceID: UUID,
        initialDescriptor:
            TuringFlowDescriptor
    ) async throws {
        guard activeSequenceID == nil,
              activeOwnerID == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Ham-receiver sequence audio already has an owner."
            )
        }

        guard initialDescriptor
            .transmission
            .effectiveInteractionSurface ==
                .hamReceiver else {
            throw TuringRuntimeError.invalidConfig(
                "Ham sequence lifecycle requires the hamReceiver surface."
            )
        }

        let ownerID =
            "hamReceiver.sequence.\(sequenceID.uuidString)"

        activeSequenceID = sequenceID
        activeOwnerID = ownerID

        do {
            try await bed.beginSession(
                ownerID: ownerID
            )
        } catch {
            activeSequenceID = nil
            activeOwnerID = nil
            throw error
        }

        print("""
        [TuringHamSequence] began
          sequenceID: \(sequenceID.uuidString)
          ownerID: \(ownerID)
          initialScriptPointID: \(initialDescriptor.scriptPointID)
        """)
    }

    func pointWillBegin(
        sequenceID: UUID,
        descriptor:
            TuringFlowDescriptor
    ) async throws {
        guard activeSequenceID == sequenceID,
              activeOwnerID != nil else {
            throw TuringRuntimeError.invalidConfig(
                "Ham sequence point began without its active sequence owner."
            )
        }

        guard descriptor
            .transmission
            .effectiveInteractionSurface ==
                .hamReceiver else {
            throw TuringRuntimeError.invalidConfig(
                "Every point in the ham sequence must use hamReceiver."
            )
        }

        print("""
        [TuringHamSequence] point began
          sequenceID: \(sequenceID.uuidString)
          scriptPointID: \(descriptor.scriptPointID)
          characterID: \(descriptor.transmission.characterID)
          outputRoute: \(descriptor.transmission.outputRoute.rawValue)
          ambientOwnerUnchanged: true
        """)
    }

    func pointDidFinish(
        sequenceID: UUID,
        descriptor:
            TuringFlowDescriptor,
        succeeded: Bool,
        hasAutomaticSuccessor:
            Bool
    ) async {
        guard activeSequenceID == sequenceID else {
            return
        }

        print("""
        [TuringHamSequence] point completed
          sequenceID: \(sequenceID.uuidString)
          scriptPointID: \(descriptor.scriptPointID)
          actualPlaybackCompleted: \(succeeded)
          automaticSuccessor: \(hasAutomaticSuccessor)
          interactionGate: \(descriptor.progression.interactionGateAfterCompletion.rawValue)
        """)
    }

    func end(
        sequenceID: UUID,
        finalDescriptor:
            TuringFlowDescriptor?,
        succeeded: Bool,
        reason: String
    ) async {
        guard activeSequenceID == sequenceID,
              let ownerID =
                activeOwnerID else {
            return
        }

        activeSequenceID = nil
        activeOwnerID = nil

        await bed.endSession(
            ownerID: ownerID,
            reason: reason
        )

        print("""
        [TuringHamSequence] ended
          sequenceID: \(sequenceID.uuidString)
          finalScriptPointID: \(finalDescriptor?.scriptPointID ?? "none")
          succeeded: \(succeeded)
          reason: \(reason)
          ambientReleased: true
        """)
    }
}
