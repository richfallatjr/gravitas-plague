import ARKit
import Combine
import Foundation

@MainActor
final class RoomTrackingManager: ObservableObject {
    @Published private(set) var currentRoomID: UUID?

    private let session = ARKitSession()
    private let roomProvider = RoomTrackingProvider()

    private var roomTask: Task<Void, Never>?

    func startIfSupported() async {
        guard RoomTrackingProvider.isSupported else {
            print("[RoomSkinning] room tracking unsupported; continuing with wall planes only")
            return
        }

        do {
            try await session.run([roomProvider])

            roomTask?.cancel()
            roomTask = Task { [weak self] in
                guard let self else { return }

                for await update in roomProvider.anchorUpdates {
                    await MainActor.run {
                        self.handleRoomAnchorUpdate(update)
                    }
                }
            }

            print("[RoomSkinning] room tracking provider active")

        } catch {
            print("[RoomSkinning] room tracking failed; continuing with wall planes only: \(error.localizedDescription)")
        }
    }

    func stop() {
        roomTask?.cancel()
        roomTask = nil
        session.stop()
    }

    private func handleRoomAnchorUpdate(
        _ update: AnchorUpdate<RoomAnchor>
    ) {
        switch update.event {
        case .added, .updated:
            currentRoomID = update.anchor.id
            print("[RoomSkinning] current room anchor updated id=\(update.anchor.id)")

        case .removed:
            if currentRoomID == update.anchor.id {
                currentRoomID = nil
            }
        }
    }
}
