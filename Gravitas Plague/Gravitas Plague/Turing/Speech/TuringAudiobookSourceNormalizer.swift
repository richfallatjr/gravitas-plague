import Foundation

enum TuringAudiobookSourceNormalizer {
    static func normalize(_ raw: String) -> String {
        let lf = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let collapsedNewlines = lf.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        let rawBlocks = collapsedNewlines.components(separatedBy: "\n\n")
        let normalizedBlocks = rawBlocks.compactMap { block -> String? in
            let collapsedSpaces = block.replacingOccurrences(
                of: "[ \t]+",
                with: " ",
                options: .regularExpression
            )
            let trimmed = collapsedSpaces.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        }

        return normalizedBlocks.joined(separator: "\n\n")
    }
}
