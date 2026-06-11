import Foundation

enum HordeAttackAnimationCatalogue {
    static let existingAttackClipIDs: [String] = [
        "charged-slash-left",
        "charged-slash-right"
    ]

    static let newHookClipIDs: [String] = [
        "left_hook_01",
        "right_hook_01"
    ]

    static var allAttackClipIDs: [String] {
        existingAttackClipIDs + newHookClipIDs
    }

    static func validAttackClipIDs(
        clipsByID: [String: JockAnimClip]
    ) -> [String] {
        let valid = allAttackClipIDs.filter { clipID in
            guard let clip = clipsByID[clipID] else {
                print("[AttackCatalogue] ERROR attack clip does not resolve: \(clipID)")
                return false
            }

            guard clip.clipID == clipID else {
                print(
                    """
                    [AttackCatalogue] ERROR attack clip ID mismatch
                      requestedID: \(clipID)
                      payloadClipID: \(clip.clipID)
                    """
                )
                return false
            }

            return true
        }

        if valid.count != allAttackClipIDs.count {
            print(
                """
                [AttackCatalogue] ERROR expected 4 valid attack clips, found \(valid.count)
                  requested: \(allAttackClipIDs.joined(separator: ", "))
                  valid: \(valid.joined(separator: ", "))
                """
            )
        }

        return valid
    }
}

struct ResolvedAttackAnimationClip {
    let clipID: String
    let clip: JockAnimClip
}

@MainActor
final class AttackAnimationRandomizer {
    private var lastAttackClipIDByEnemyID: [UUID: String] = [:]

    func randomAttackClip(
        enemyID: UUID,
        clipsByID: [String: JockAnimClip]
    ) -> ResolvedAttackAnimationClip? {
        let validAttackClipIDs = HordeAttackAnimationCatalogue.validAttackClipIDs(
            clipsByID: clipsByID
        )

        let available = validAttackClipIDs.compactMap { clipID -> ResolvedAttackAnimationClip? in
            guard let clip = clipsByID[clipID],
                  clip.clipID == clipID else {
                return nil
            }

            return ResolvedAttackAnimationClip(
                clipID: clipID,
                clip: clip
            )
        }

        guard !available.isEmpty else {
            print(
                """
                [AttackCatalogue] ERROR no available attack clips
                  requestedIDs: \(HordeAttackAnimationCatalogue.allAttackClipIDs.joined(separator: ", "))
                """
            )

            return nil
        }

        var candidates = available

        if candidates.count > 1,
           let lastClipID = lastAttackClipIDByEnemyID[enemyID] {
            candidates.removeAll { candidate in
                candidate.clipID == lastClipID
            }

            if candidates.isEmpty {
                candidates = available
            }
        }

        guard let selected = candidates.randomElement() else {
            return nil
        }

        lastAttackClipIDByEnemyID[enemyID] = selected.clipID

        print(
            """
            [AttackCatalogue] selected random attack
              enemyID: \(enemyID)
              clipID: \(selected.clipID)
              catalogueCount: \(available.count)
              noImmediateRepeat: \(available.count > 1)
            """
        )

        return selected
    }

    func reset(enemyID: UUID) {
        lastAttackClipIDByEnemyID.removeValue(forKey: enemyID)
    }

    func resetAll() {
        lastAttackClipIDByEnemyID.removeAll()
    }
}

enum RequiredAttackAnimationClipValidator {
    static func validate(
        clipsByID: [String: JockAnimClip]
    ) {
        let clipIDs = HordeAttackAnimationCatalogue.allAttackClipIDs
        let found = HordeAttackAnimationCatalogue.validAttackClipIDs(
            clipsByID: clipsByID
        )
        let missing = clipIDs.filter { !found.contains($0) }

        print(
            """
            [AttackCatalogue] validation
              requiredCount: \(clipIDs.count)
              found: \(found.joined(separator: ", "))
              missing: \(missing.joined(separator: ", "))
            """
        )

        if !missing.isEmpty {
            print(
                """
                [AttackCatalogue] ERROR missing required attack clips
                  missing: \(missing.joined(separator: ", "))
                  expectedTotal: 4
                """
            )
        }
    }
}
