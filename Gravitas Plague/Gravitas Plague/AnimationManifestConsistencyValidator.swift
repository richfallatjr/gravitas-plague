import Foundation

struct AnimationManifestClipConsistencyIssue {
    let summaryClipID: String
    let relativePath: String
    let payloadClipID: String?
    let issue: String
}

struct JockAnimPayloadPeek: Decodable {
    let clipID: String

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
    }

    static func peekClipID(data: Data) -> String? {
        try? JSONDecoder().decode(JockAnimPayloadPeek.self, from: data).clipID
    }
}

enum AnimationManifestConsistencyValidator {
    static func validate(
        manifest: JockAnimationManifest,
        animationLibraryRoot: URL
    ) -> [AnimationManifestClipConsistencyIssue] {
        var issues: [AnimationManifestClipConsistencyIssue] = []
        var relativePathToClipIDs: [String: [String]] = [:]

        for summary in manifest.clips {
            relativePathToClipIDs[summary.relativePath, default: []].append(summary.clipID)

            let url = animationLibraryRoot
                .appendingPathComponent(summary.relativePath)

            guard let data = try? Data(contentsOf: url) else {
                issues.append(
                    AnimationManifestClipConsistencyIssue(
                        summaryClipID: summary.clipID,
                        relativePath: summary.relativePath,
                        payloadClipID: nil,
                        issue: "missing sidecar file"
                    )
                )
                continue
            }

            let payloadClipID = JockAnimPayloadPeek.peekClipID(data: data)

            if payloadClipID != summary.clipID {
                issues.append(
                    AnimationManifestClipConsistencyIssue(
                        summaryClipID: summary.clipID,
                        relativePath: summary.relativePath,
                        payloadClipID: payloadClipID,
                        issue: "manifest clip_id does not match sidecar payload clip_id"
                    )
                )
            }
        }

        for (relativePath, clipIDs) in relativePathToClipIDs where clipIDs.count > 1 {
            for clipID in clipIDs {
                issues.append(
                    AnimationManifestClipConsistencyIssue(
                        summaryClipID: clipID,
                        relativePath: relativePath,
                        payloadClipID: nil,
                        issue: "duplicate manifest relative_path used by multiple clip IDs: \(clipIDs.joined(separator: ", "))"
                    )
                )
            }
        }

        if issues.isEmpty {
            print("[AnimationManifestValidator] manifest consistency passed")
        } else {
            print(
                """
                [AnimationManifestValidator] ERROR manifest consistency issues
                  count: \(issues.count)
                """
            )

            for issue in issues {
                print(
                    """
                    [AnimationManifestValidator] issue
                      summaryClipID: \(issue.summaryClipID)
                      relativePath: \(issue.relativePath)
                      payloadClipID: \(issue.payloadClipID ?? "nil")
                      issue: \(issue.issue)
                    """
                )
            }
        }

        return issues
    }
}
