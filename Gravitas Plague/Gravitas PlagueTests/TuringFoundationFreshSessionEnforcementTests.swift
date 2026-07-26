import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringFoundationFreshSessionEnforcementTests:
    XCTestCase {

    func testFoundationPromptSanitizerReplacesWholeWordBeforeSubmission() {
        XCTAssertEqual(
            TuringFoundationPromptSanitizer.sanitize(
                "This shit, SHIT, and Shit must be replaced."
            ),
            "This stuff, stuff, and stuff must be replaced."
        )
        XCTAssertEqual(
            TuringFoundationPromptSanitizer.sanitize(
                "Shitake and bullshit are different words."
            ),
            "Shitake and bullshit are different words."
        )
    }

    func testPromptVoiceUsesPermissiveContentTransformationGuardrails() {
        XCTAssertEqual(
            TuringFoundationPromptPurposePolicy.guardrailMode(
                for: "voicePrompt_characterIntent"
            ),
            .permissiveContentTransformations
        )
        XCTAssertEqual(
            TuringFoundationPromptPurposePolicy.guardrailMode(
                for: "storyWallSliceLayoutPlanner"
            ),
            .standard
        )
        XCTAssertEqual(
            TuringFoundationPromptPurposePolicy.guardrailMode(
                for: "dialogueJSONRepair"
            ),
            .standard
        )
    }

    func testGuardrailClassifierUsesReflectedErrorCase() {
        enum SyntheticLanguageModelError: Error {
            case guardrailViolation
        }

        XCTAssertTrue(
            TuringFoundationGuardrailPolicy.isGuardrailError(
                SyntheticLanguageModelError.guardrailViolation
            )
        )
    }

    func testOnlyGatewayMayReferenceLanguageModelSession()
        throws {
        let sourceRoot = try appSourceRoot()
        let files = try swiftFiles(
            below: sourceRoot
        )

        let runnerPath =
            "Turing/Foundation/TuringFoundationModelsRunner.swift"
        let fencePath =
            "Turing/Foundation/TuringFoundationModelsAccessFence.swift"

        var SDKSessionCreationCount = 0

        for file in files {
            let relativePath = file.path
                .replacingOccurrences(
                    of: sourceRoot.path + "/",
                    with: ""
                )
            let source = try String(
                contentsOf: file,
                encoding: .utf8
            )

            switch relativePath {
            case runnerPath:
                SDKSessionCreationCount +=
                    source.components(
                        separatedBy:
                            "FoundationModels.LanguageModelSession("
                    ).count - 1

                XCTAssertTrue(
                    source.contains(
                        "let session = FoundationModels.LanguageModelSession("
                    ),
                    "The gateway must create its session locally."
                )
                XCTAssertTrue(
                    source.contains(
                        "private static func respondUsingFreshSession"
                    )
                )
                XCTAssertFalse(
                    source.contains(
                        "static let session"
                    )
                )
                XCTAssertFalse(
                    source.contains(
                        "static var session"
                    )
                )
                XCTAssertFalse(
                    source.contains(
                        "private let session"
                    )
                )
                XCTAssertFalse(
                    source.contains(
                        "private var session"
                    )
                )
                XCTAssertFalse(
                    source.contains(
                        "lazy var session"
                    )
                )

            case fencePath:
                XCTAssertTrue(
                    source.contains(
                        "typealias LanguageModelSession"
                    )
                )
                XCTAssertTrue(
                    source.contains(
                        "unavailable"
                    )
                )
                XCTAssertFalse(
                    source.contains(
                        "LanguageModelSession()"
                    )
                )

            default:
                XCTAssertFalse(
                    source.contains(
                        "LanguageModelSession"
                    ),
                    """
                    \(relativePath) bypasses the fresh-session gateway.
                    Call TuringFoundationQueryRunning.runPrompt instead.
                    """
                )

                if source.contains(
                    "import FoundationModels"
                ) {
                    XCTAssertFalse(
                        source.contains(
                            ".respond(to:"
                        ),
                        """
                        \(relativePath) submits directly to Foundation Models.
                        All requests must use the fresh-session gateway.
                        """
                    )
                    XCTAssertFalse(
                        source.contains(
                            ".streamResponse("
                        ),
                        """
                        \(relativePath) streams directly from Foundation Models.
                        Add a fresh-session gateway method before using streaming.
                        """
                    )
                }
            }
        }

        XCTAssertEqual(
            SDKSessionCreationCount,
            1,
            """
            The app target must contain exactly one SDK session-construction
            site, inside TuringFoundationModelsRunner.
            """
        )
    }

    func testRunnerIsStatelessAndOneSubmissionPerSession()
        throws {
        let sourceRoot = try appSourceRoot()
        let runnerURL = sourceRoot
            .appendingPathComponent(
                "Turing/Foundation/TuringFoundationModelsRunner.swift"
            )
        let source = try String(
            contentsOf: runnerURL,
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                "struct TuringFoundationModelsRunner"
            )
        )
        XCTAssertTrue(
            source.contains(
                "let session = FoundationModels.LanguageModelSession("
            )
        )

        let responseSubmissionCount =
            source.components(
                separatedBy:
                    "let response = try await session.respond"
            ).count - 1

        XCTAssertEqual(
            responseSubmissionCount,
            1,
            "A fresh session submits exactly one prompt."
        )
    }

    private func appSourceRoot() throws -> URL {
        let testFile = URL(
            fileURLWithPath: #filePath
        )
        let projectContainer = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = projectContainer
            .appendingPathComponent(
                "Gravitas Plague",
                isDirectory: true
            )

        guard FileManager.default
            .fileExists(
                atPath: sourceRoot.path
            ) else {
            throw NSError(
                domain:
                    "TuringFoundationFreshSessionEnforcementTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not locate app source root at \(sourceRoot.path)."
                ]
            )
        }

        return sourceRoot
    }

    private func swiftFiles(
        below root: URL
    ) throws -> [URL] {
        guard let enumerator =
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey
                    ],
                    options: [
                        .skipsHiddenFiles,
                        .skipsPackageDescendants
                    ]
                ) else {
            throw NSError(
                domain:
                    "TuringFoundationFreshSessionEnforcementTests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not enumerate \(root.path)."
                ]
            )
        }

        return enumerator.compactMap {
            item -> URL? in

            guard let url = item as? URL,
                  url.pathExtension == "swift",
                  (try? url.resourceValues(
                    forKeys: [
                        .isRegularFileKey
                    ]
                  ).isRegularFile) == true else {
                return nil
            }

            return url
        }
    }
}
