import Foundation

@MainActor
final class StoryInteractionPresentationCoordinator {
    static let shared = StoryInteractionPresentationCoordinator()

    private final class WeakSurface {
        weak var value: (any StoryInteractionSurfacePresenting)?

        init(_ value: any StoryInteractionSurfacePresenting) {
            self.value = value
        }
    }

    private let arbiter: StoryInteractionArbiter
    private var surfaces: [WeakSurface] = []
    private var observationTask: Task<Void, Never>?

    init(arbiter: StoryInteractionArbiter = .shared) {
        self.arbiter = arbiter
    }

    func register(_ surface: any StoryInteractionSurfacePresenting) {
        surfaces.removeAll { $0.value == nil }
        guard surfaces.contains(where: { $0.value === surface }) == false else {
            return
        }
        surfaces.append(WeakSurface(surface))
    }

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await arbiter.snapshots()
            for await snapshot in stream {
                guard Task.isCancelled == false else { return }
                surfaces.removeAll { $0.value == nil }
                for surface in surfaces {
                    surface.value?.applyInteractionSnapshot(snapshot)
                }
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        surfaces.removeAll(keepingCapacity: false)
    }
}
