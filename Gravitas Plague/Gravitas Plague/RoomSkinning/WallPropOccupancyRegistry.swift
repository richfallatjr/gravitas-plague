import Foundation
import simd

enum WallPropOccupancyKind: String, Codable, Hashable {
    case wallPoster
    case hordePortal
    case storyPortal
    case killSwitch
    case other
}

struct WallLocalRect: Codable, Equatable {
    var minX: Float
    var minY: Float
    var maxX: Float
    var maxY: Float

    var width: Float {
        maxX - minX
    }

    var height: Float {
        maxY - minY
    }

    var center: SIMD2<Float> {
        SIMD2<Float>(
            (minX + maxX) * 0.5,
            (minY + maxY) * 0.5
        )
    }

    func expanded(
        by padding: Float
    ) -> WallLocalRect {
        WallLocalRect(
            minX: minX - padding,
            minY: minY - padding,
            maxX: maxX + padding,
            maxY: maxY + padding
        )
    }

    func overlaps(
        _ other: WallLocalRect
    ) -> Bool {
        minX < other.maxX &&
            maxX > other.minX &&
            minY < other.maxY &&
            maxY > other.minY
    }

    func distanceTo(
        _ other: WallLocalRect
    ) -> Float {
        if overlaps(other) {
            return 0
        }

        let dx: Float
        if maxX < other.minX {
            dx = other.minX - maxX
        } else if other.maxX < minX {
            dx = minX - other.maxX
        } else {
            dx = 0
        }

        let dy: Float
        if maxY < other.minY {
            dy = other.minY - maxY
        } else if other.maxY < minY {
            dy = minY - other.maxY
        } else {
            dy = 0
        }

        return sqrt(dx * dx + dy * dy)
    }
}

struct WallPropOccupancyRecord: Identifiable, Codable {
    let id: UUID
    let wallID: UUID
    let kind: WallPropOccupancyKind
    let rect: WallLocalRect
    let padding: Float
    let label: String

    var paddedRect: WallLocalRect {
        rect.expanded(
            by: padding
        )
    }
}

@MainActor
final class WallPropOccupancyRegistry {
    private(set) var recordsByID: [UUID: WallPropOccupancyRecord] = [:]

    func register(
        id: UUID,
        wallID: UUID,
        kind: WallPropOccupancyKind,
        rect: WallLocalRect,
        padding: Float,
        label: String
    ) {
        let record = WallPropOccupancyRecord(
            id: id,
            wallID: wallID,
            kind: kind,
            rect: rect,
            padding: padding,
            label: label
        )

        recordsByID[id] = record

        print(
            """
            [WallOccupancy] registered
              id: \(id)
              wallID: \(wallID)
              kind: \(kind.rawValue)
              label: \(label)
              rect: \(rect)
              padding: \(padding)
            """
        )
    }

    func unregister(
        id: UUID
    ) {
        if let old = recordsByID.removeValue(forKey: id) {
            print(
                """
                [WallOccupancy] unregistered
                  id: \(id)
                  kind: \(old.kind.rawValue)
                  label: \(old.label)
                """
            )
        }
    }

    func records(
        wallID: UUID
    ) -> [WallPropOccupancyRecord] {
        recordsByID.values.filter {
            $0.wallID == wallID
        }
    }

    func hasHardOverlap(
        wallID: UUID,
        candidate: WallLocalRect,
        candidateKind: WallPropOccupancyKind,
        ignoredIDs: Set<UUID> = []
    ) -> Bool {
        for record in records(wallID: wallID) {
            guard !ignoredIDs.contains(record.id) else {
                continue
            }

            let occupied = record.paddedRect

            guard candidate.overlaps(occupied) else {
                continue
            }

            if candidateKind == .hordePortal,
               record.kind == .wallPoster {
                print(
                    """
                    [WallOccupancy] HARD REJECT portal overlaps poster
                      candidateKind: \(candidateKind.rawValue)
                      recordKind: \(record.kind.rawValue)
                      recordLabel: \(record.label)
                      candidate: \(candidate)
                      occupied: \(occupied)
                    """
                )
                return true
            }

            if candidateKind == .hordePortal,
               record.kind == .hordePortal {
                print(
                    """
                    [WallOccupancy] HARD REJECT portal overlaps portal
                      recordLabel: \(record.label)
                      candidate: \(candidate)
                      occupied: \(occupied)
                    """
                )
                return true
            }

            if candidateKind == .wallPoster,
               record.kind == .hordePortal {
                print(
                    """
                    [WallOccupancy] HARD REJECT poster overlaps portal
                      recordLabel: \(record.label)
                      candidate: \(candidate)
                      occupied: \(occupied)
                    """
                )
                return true
            }
        }

        return false
    }

    func nearestDistance(
        wallID: UUID,
        candidate: WallLocalRect,
        kinds: Set<WallPropOccupancyKind>
    ) -> Float {
        let distances = records(wallID: wallID)
            .filter {
                kinds.contains($0.kind)
            }
            .map {
                candidate.distanceTo($0.paddedRect)
            }

        return distances.min() ?? Float.greatestFiniteMagnitude
    }
}
