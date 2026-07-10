import Foundation

struct TuringStoryFeasibilityVector: Codable, Sendable, Hashable {
    let door: Int
    let window: Int
    let walkieShelf: Int
    let poster: Int

    var compactArray: [Int] { [door, window, walkieShelf, poster] }
}

struct TuringStoryHotspotFeasibility: Sendable {
    func maximumLexicographicVector(
        catalog: TuringStoryExactPlacementCatalog
    ) -> TuringStoryFeasibilityVector {
        let props = TuringStoryPropID.allCases.sorted { $0.priority < $1.priority }
        let candidates = Dictionary(uniqueKeysWithValues: props.map { propID in
            (
                propID,
                catalog.placements(for: propID).sorted {
                    if $0.deterministicQuality != $1.deterministicQuality {
                        return $0.deterministicQuality > $1.deterministicQuality
                    }
                    return $0.placementID < $1.placementID
                }
            )
        })
        let vector = search(
            index: 0,
            props: props,
            candidates: candidates,
            chosen: []
        )
        return TuringStoryFeasibilityVector(
            door: vector[0],
            window: vector[1],
            walkieShelf: vector[2],
            poster: vector[3]
        )
    }

    private func search(
        index: Int,
        props: [TuringStoryPropID],
        candidates: [TuringStoryPropID: [TuringStoryExactPlacement]],
        chosen: [TuringStoryExactPlacement]
    ) -> [Int] {
        guard index < props.count else { return [] }
        let propID = props[index]
        var bestSuffix = Array(repeating: 0, count: props.count - index)
        for placement in candidates[propID] ?? [] where compatible(placement, chosen: chosen) {
            let suffix = index + 1 < props.count
                ? search(
                    index: index + 1,
                    props: props,
                    candidates: candidates,
                    chosen: chosen + [placement]
                )
                : []
            let candidate = [1] + suffix
            if lexicographicallyGreater(candidate, than: bestSuffix) {
                bestSuffix = candidate
            }
            if bestSuffix.allSatisfy({ $0 == 1 }) { return bestSuffix }
        }
        let omittedSuffix = index + 1 < props.count
            ? [0] + search(
                index: index + 1,
                props: props,
                candidates: candidates,
                chosen: chosen
            )
            : [0]
        if lexicographicallyGreater(omittedSuffix, than: bestSuffix) {
            bestSuffix = omittedSuffix
        }
        return bestSuffix
    }

    private func compatible(
        _ placement: TuringStoryExactPlacement,
        chosen: [TuringStoryExactPlacement]
    ) -> Bool {
        !chosen.contains {
            $0.wallID == placement.wallID &&
                $0.semanticRect.overlaps(placement.semanticRect)
        }
    }

    private func lexicographicallyGreater(
        _ lhs: [Int],
        than rhs: [Int]
    ) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
            return lhs[index] > rhs[index]
        }
        return lhs.count > rhs.count
    }
}
