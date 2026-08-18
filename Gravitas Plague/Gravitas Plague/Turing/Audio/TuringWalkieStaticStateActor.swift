import Foundation

actor TuringWalkieStaticStateActor {
    private enum Gain {
        static let ambientDB: Float = -23
        static let sendingDB: Float = -16.5
    }

    private let endpoint: any TuringAudioPlaybackEndpoint
    private var ambientHandle: TuringAudioPlaybackHandle?
    private var sendingHandle: TuringAudioPlaybackHandle?
    private var sendingOwnerID: String?
    private var ambientRetentionOwners = Set<String>()

    init(endpoint: any TuringAudioPlaybackEndpoint) {
        self.endpoint = endpoint
    }

    func startAmbient(fileURL: URL, runID: String) async throws {
        guard ambientHandle == nil else { return }
        let handle = try await endpoint.play(
            .init(
                requestID: UUID(),
                runID: runID,
                fileURL: fileURL,
                kind: .ambientStatic,
                route: .storyWalkie,
                label: "ambientStatic",
                gainDB: Gain.ambientDB,
                shouldLoop: true,
                cachePolicy: .bundled
            )
        )
        ambientHandle = handle
        print("""
        [TuringWalkieStatic] ambient started
          runID: \(runID)
          handleID: \(handle.id.uuidString)
          file: \(fileURL.lastPathComponent)
        """)
    }

    func retainAmbient(
        fileURL: URL,
        runID: String,
        ownerID: String
    ) async throws {
        ambientRetentionOwners.insert(ownerID)
        do {
            try await startAmbient(fileURL: fileURL, runID: runID)
        } catch {
            ambientRetentionOwners.remove(ownerID)
            throw error
        }

        print("""
        [TuringWalkieStatic] ambient retained
          ownerID: \(ownerID)
          retentionOwnerCount: \(ambientRetentionOwners.count)
        """)
    }

    func stopAmbient(reason: String) async {
        guard ambientRetentionOwners.isEmpty else {
            print("""
            [TuringWalkieStatic] ambient stop deferred
              reason: \(reason)
              retentionOwners: \(ambientRetentionOwners.sorted())
            """)
            return
        }
        guard let handle = ambientHandle else { return }
        ambientHandle = nil
        await endpoint.stop(handle, reason: reason)
        print("""
        [TuringWalkieStatic] ambient stopped
          handleID: \(handle.id.uuidString)
          reason: \(reason)
        """)
    }

    func releaseAmbient(ownerID: String, reason: String) async {
        guard ambientRetentionOwners.remove(ownerID) != nil else {
            return
        }

        print("""
        [TuringWalkieStatic] ambient retention released
          ownerID: \(ownerID)
          retentionOwnerCount: \(ambientRetentionOwners.count)
          reason: \(reason)
        """)

        await stopAmbient(reason: reason)
    }

    func startSending(fileURL: URL, runID: String) async throws {
        guard sendingHandle == nil else { return }
        sendingHandle = try await endpoint.play(
            .init(
                requestID: UUID(),
                runID: runID,
                fileURL: fileURL,
                kind: .sendingStatic,
                route: .storyWalkie,
                label: "sendingStatic",
                gainDB: Gain.sendingDB,
                shouldLoop: true,
                cachePolicy: .bundled
            )
        )
    }

    func startRetainedSending(
        fileURL: URL,
        runID: String,
        ownerID: String
    ) async throws -> TuringAudioPlaybackHandle {
        if let sendingHandle {
            guard sendingOwnerID == ownerID else {
                throw TuringRuntimeError.invalidConfig(
                    "Walkie sending static belongs to another owner."
                )
            }
            return sendingHandle
        }
        let handle = try await endpoint.play(
            .init(
                requestID: UUID(),
                runID: runID,
                fileURL: fileURL,
                kind: .sendingStatic,
                route: .storyWalkie,
                label: "sendingStatic.liveConversation",
                gainDB: Gain.sendingDB,
                shouldLoop: true,
                cachePolicy: .bundled
            )
        )
        sendingHandle = handle
        sendingOwnerID = ownerID
        return handle
    }

    func stopSending(reason: String) async {
        guard let handle = sendingHandle else { return }
        sendingHandle = nil
        sendingOwnerID = nil
        await endpoint.stop(handle, reason: reason)
    }

    func stopRetainedSending(
        ownerID: String,
        handle: TuringAudioPlaybackHandle,
        reason: String
    ) async {
        guard sendingOwnerID == ownerID,
              sendingHandle == handle else { return }
        await stopSending(reason: reason)
    }

    func stopAll(reason: String) async {
        ambientRetentionOwners.removeAll(keepingCapacity: false)
        await stopSending(reason: reason)
        await stopAmbient(reason: reason)
    }
}
