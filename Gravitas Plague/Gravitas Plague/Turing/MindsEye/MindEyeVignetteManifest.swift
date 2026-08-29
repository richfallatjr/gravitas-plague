import Foundation

nonisolated struct MindEyeVignetteManifest:
    Codable,
    Sendable,
    Equatable
{
    struct Layers: Codable, Sendable, Equatable {
        struct Eyes: Codable, Sendable, Equatable {
            let open: [String]
            let closed: [String]
        }

        struct Mouths: Codable, Sendable, Equatable {
            let rest: [String]
            let small: [String]
            let wide: [String]
            let round: [String]
            let teeth: [String]

            func files(for pose: MindEyeMouthPose) -> [String] {
                switch pose {
                case .rest: rest
                case .small: small
                case .wide: wide
                case .round: round
                case .teeth: teeth
                }
            }

            var allFiles: [String] {
                MindEyeMouthPose.allCases.flatMap(files(for:))
            }
        }

        let background: String
        let characterBase: String
        let featherMask: String
        let eyes: Eyes
        let mouths: Mouths
    }

    let schemaVersion: Int
    let vignetteID: String
    let characterID: TuringConversationCharacterID
    let sourceSize: MindEyePixelSize
    let viewportSize: MindEyePixelSize
    let viewportRect: MindEyePixelRect
    let layers: Layers
    let depth: MindEyeDepthTuning
    let motion: MindEyeMotionTuning
    let blink: MindEyeBlinkTuning
    let placement: MindEyePlacementTuning?
}

nonisolated enum MindEyeManifestValidationCode:
    String,
    Sendable,
    Equatable,
    Hashable
{
    case unsupportedVersion
    case invalidVignetteID
    case characterMismatch
    case wrongSourceSize
    case wrongViewportSize
    case wrongViewportRect
    case unsafePath
    case wrongFileExtension
    case duplicateAssetReference
    case missingEyeOpen
    case missingEyeClosed
    case missingMouthRest
    case missingMouthSmall
    case missingMouthWide
    case missingMouthRound
    case missingMouthTeeth
    case invalidDepth
    case invalidMotion
    case invalidBlink
    case invalidPlacement
}

nonisolated struct MindEyeManifestValidationIssue:
    Sendable,
    Equatable,
    Hashable
{
    let code: MindEyeManifestValidationCode
    let field: String
    let message: String
}

nonisolated enum MindEyeSafeRelativePath {
    static func validates(
        _ path: String,
        requiredExtension: String? = nil
    ) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.contains("\0"),
              !path.contains("://"),
              let decoded = path.removingPercentEncoding,
              !decoded.isEmpty,
              !decoded.hasPrefix("/"),
              !decoded.hasPrefix("~"),
              !decoded.contains("\\"),
              !decoded.contains("\0"),
              !decoded.contains("://") else {
            return false
        }

        let components = decoded.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }

        if let requiredExtension {
            let suffix = "." + requiredExtension.lowercased()
            guard decoded.lowercased().hasSuffix(suffix) else {
                return false
            }
        }
        return true
    }
}

nonisolated enum MindEyeVignetteManifestValidator {
    static func issues(
        manifest: MindEyeVignetteManifest,
        expectedVignetteID: String,
        expectedCharacterID: TuringConversationCharacterID
    ) -> [MindEyeManifestValidationIssue] {
        var issues: [MindEyeManifestValidationIssue] = []

        func append(
            _ code: MindEyeManifestValidationCode,
            _ field: String,
            _ message: String
        ) {
            issues.append(
                MindEyeManifestValidationIssue(
                    code: code,
                    field: field,
                    message: message
                )
            )
        }

        if manifest.schemaVersion != MindEyeDescriptorConstants.vignetteSchemaVersion {
            append(.unsupportedVersion, "schemaVersion", "Unsupported vignette schema version.")
        }
        if manifest.vignetteID != expectedVignetteID ||
            !validID(manifest.vignetteID) {
            append(.invalidVignetteID, "vignetteID", "Vignette ID is invalid or does not match its catalog entry.")
        }
        if manifest.characterID != expectedCharacterID {
            append(.characterMismatch, "characterID", "Manifest character does not match its catalog entry.")
        }
        if manifest.sourceSize != MindEyeDescriptorConstants.expectedSourceSize {
            append(.wrongSourceSize, "sourceSize", "Source size must be 2304 x 1296.")
        }
        if manifest.viewportSize != MindEyeDescriptorConstants.expectedViewportSize {
            append(.wrongViewportSize, "viewportSize", "Viewport size must be 1920 x 1080.")
        }
        if manifest.viewportRect != MindEyeDescriptorConstants.expectedViewportRect {
            append(.wrongViewportRect, "viewportRect", "Viewport rect must be the centered 1920 x 1080 crop.")
        }

        let groupedPaths: [(String, [String])] = [
            ("layers.background", [manifest.layers.background]),
            ("layers.characterBase", [manifest.layers.characterBase]),
            ("layers.featherMask", [manifest.layers.featherMask]),
            ("layers.eyes.open", manifest.layers.eyes.open),
            ("layers.eyes.closed", manifest.layers.eyes.closed),
            ("layers.mouths.rest", manifest.layers.mouths.rest),
            ("layers.mouths.small", manifest.layers.mouths.small),
            ("layers.mouths.wide", manifest.layers.mouths.wide),
            ("layers.mouths.round", manifest.layers.mouths.round),
            ("layers.mouths.teeth", manifest.layers.mouths.teeth)
        ]

        for (field, paths) in groupedPaths {
            var local = Set<String>()
            for path in paths {
                if !MindEyeSafeRelativePath.validates(path) {
                    append(.unsafePath, field, "Asset path is not a safe package-relative path: \(path)")
                } else if !MindEyeSafeRelativePath.validates(path, requiredExtension: "png") {
                    append(.wrongFileExtension, field, "Asset must use the PNG extension: \(path)")
                }
                if !local.insert(path).inserted {
                    append(.duplicateAssetReference, field, "Asset is repeated in one semantic role: \(path)")
                }
            }
        }

        var assignedPaths = Set<String>()
        for (field, paths) in groupedPaths {
            for path in paths where !assignedPaths.insert(path).inserted {
                append(.duplicateAssetReference, field, "Asset is assigned to more than one semantic role: \(path)")
            }
        }

        if manifest.layers.eyes.open.isEmpty {
            append(.missingEyeOpen, "layers.eyes.open", "At least one open-eye variant is required.")
        }
        if manifest.layers.eyes.closed.isEmpty {
            append(.missingEyeClosed, "layers.eyes.closed", "At least one closed-eye variant is required.")
        }
        let missingMouthCodes: [(MindEyeMouthPose, MindEyeManifestValidationCode)] = [
            (.rest, .missingMouthRest),
            (.small, .missingMouthSmall),
            (.wide, .missingMouthWide),
            (.round, .missingMouthRound),
            (.teeth, .missingMouthTeeth)
        ]
        for (pose, code) in missingMouthCodes
            where manifest.layers.mouths.files(for: pose).isEmpty {
            append(code, "layers.mouths.\(pose.rawValue)", "At least one \(pose.rawValue) mouth variant is required.")
        }

        if !allFinite([
            manifest.depth.cameraToCharacterMeters,
            manifest.depth.cameraToBackgroundMeters
        ]) || manifest.depth.cameraToCharacterMeters <= 0 ||
            manifest.depth.cameraToBackgroundMeters <= manifest.depth.cameraToCharacterMeters {
            append(.invalidDepth, "depth", "Depth values must be finite, positive, and background must be farther than character.")
        }

        let motion = manifest.motion
        let motionValues = [
            motion.sharedDriftMaxPixels.x,
            motion.sharedDriftMaxPixels.y,
            motion.sharedRollMaxDegrees,
            motion.sharedScaleMax,
            motion.characterParallaxMaxPixels.x,
            motion.characterParallaxMaxPixels.y,
            motion.backgroundCounterMotion,
            motion.gripCorrectionMaxPixels.x,
            motion.gripCorrectionMaxPixels.y,
            motion.gripCorrectionMaxDegrees
        ]
        let xEnvelope = motion.sharedDriftMaxPixels.x +
            motion.characterParallaxMaxPixels.x +
            motion.gripCorrectionMaxPixels.x
        let yEnvelope = motion.sharedDriftMaxPixels.y +
            motion.characterParallaxMaxPixels.y +
            motion.gripCorrectionMaxPixels.y
        if !allFinite(motionValues) ||
            motionValues.contains(where: { $0 < 0 }) ||
            !(1.0 ... 1.05).contains(motion.sharedScaleMax) ||
            !(0.20 ... 0.35).contains(motion.backgroundCounterMotion) ||
            motion.sharedRollMaxDegrees > 1.5 ||
            motion.gripCorrectionMaxDegrees > 1.0 ||
            xEnvelope > 192 || yEnvelope > 108 {
            append(.invalidMotion, "motion", "Motion tuning exceeds the finite nonnegative overscan envelope.")
        }

        let blink = manifest.blink
        let blinkValues = [
            blink.ordinaryIntervalMinSeconds,
            blink.ordinaryIntervalMaxSeconds,
            blink.doubleBlinkProbability,
            blink.doubleBlinkGapMinSeconds,
            blink.doubleBlinkGapMaxSeconds
        ]
        if !blinkValues.allSatisfy(\.isFinite) ||
            !(0.5 ... 5.0).contains(blink.ordinaryIntervalMinSeconds) ||
            !(0.5 ... 5.0).contains(blink.ordinaryIntervalMaxSeconds) ||
            blink.ordinaryIntervalMaxSeconds < blink.ordinaryIntervalMinSeconds ||
            blink.closedFrameMin <= 0 ||
            blink.closedFrameMax < blink.closedFrameMin ||
            !(0.0 ... 1.0).contains(blink.doubleBlinkProbability) ||
            !(0.5 ... 1.0).contains(blink.doubleBlinkGapMinSeconds) ||
            !(0.5 ... 1.0).contains(blink.doubleBlinkGapMaxSeconds) ||
            blink.doubleBlinkGapMaxSeconds < blink.doubleBlinkGapMinSeconds {
            append(.invalidBlink, "blink", "Blink tuning is outside the supported bounds.")
        }

        if let placement = manifest.placement {
            let values = [
                placement.cardWidthMeters,
                placement.cardHeightMeters,
                placement.verticalLiftMeters,
                placement.forwardOffsetMeters,
                placement.shelfClearanceMeters
            ]
            if !allFinite(values) ||
                placement.cardWidthMeters <= 0 ||
                placement.cardHeightMeters <= 0 ||
                placement.verticalLiftMeters < 0 ||
                placement.forwardOffsetMeters < 0 ||
                placement.shelfClearanceMeters < 0 {
                append(.invalidPlacement, "placement", "Placement dimensions must be finite and clearances nonnegative.")
            }
        }

        return issues
    }

    static func validID(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    private static func allFinite(_ values: [Float]) -> Bool {
        values.allSatisfy(\.isFinite)
    }
}
