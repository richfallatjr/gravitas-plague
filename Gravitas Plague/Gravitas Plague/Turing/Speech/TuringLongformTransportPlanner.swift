import Foundation

enum TuringLongformTransportPlanner {
    static func makeJobs(
        sourceText: String,
        maxPromptTokens: Int = 2000,
        targetFocusTokens: Int = 1200,
        contextTokensEachSide: Int = 160
    ) -> [TuringExactSegmentationJob] {
        let source = sourceText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let totalUTF16 = source.utf16.count
        guard totalUTF16 > 0 else {
            return []
        }

        let maxPromptUTF16 = max(1, maxPromptTokens) * 4
        let contextUTF16 = max(0, contextTokensEachSide) * 4
        let requestedFocusUTF16 = max(1, targetFocusTokens) * 4
        let focusUTF16 = max(
            1,
            min(requestedFocusUTF16, maxPromptUTF16 - (contextUTF16 * 2))
        )

        var jobs: [TuringExactSegmentationJob] = []
        var focusStart = 0
        var index = 0

        while focusStart < totalUTF16 {
            let rawFocusEnd = min(totalUTF16, focusStart + focusUTF16)
            let focusEnd = validUTF16Offset(
                in: source,
                atOrBefore: rawFocusEnd,
                lowerBound: focusStart + 1
            )
            let contextStart = validUTF16Offset(
                in: source,
                atOrBefore: max(0, focusStart - contextUTF16),
                lowerBound: 0
            )
            let contextEnd = validUTF16Offset(
                in: source,
                atOrAfter: min(totalUTF16, focusEnd + contextUTF16),
                upperBound: totalUTF16
            )

            jobs.append(
                TuringExactSegmentationJob(
                    index: index,
                    focusStartUTF16: focusStart,
                    focusEndUTF16: focusEnd,
                    contextStartUTF16: contextStart,
                    contextEndUTF16: contextEnd,
                    prefixContext: substring(
                        source,
                        startUTF16: contextStart,
                        endUTF16: focusStart
                    ),
                    focusText: substring(
                        source,
                        startUTF16: focusStart,
                        endUTF16: focusEnd
                    ),
                    suffixContext: substring(
                        source,
                        startUTF16: focusEnd,
                        endUTF16: contextEnd
                    )
                )
            )

            focusStart = focusEnd
            index += 1
        }

        return jobs
    }

    static func estimatedTokens(_ text: String) -> Int {
        max(1, text.utf16.count / 4)
    }

    private static func substring(
        _ source: String,
        startUTF16: Int,
        endUTF16: Int
    ) -> String {
        guard startUTF16 < endUTF16 else {
            return ""
        }

        let start = stringIndex(
            in: source,
            utf16Offset: startUTF16
        )
        let end = stringIndex(
            in: source,
            utf16Offset: endUTF16
        )
        return String(source[start..<end])
    }

    private static func validUTF16Offset(
        in source: String,
        atOrBefore offset: Int,
        lowerBound: Int
    ) -> Int {
        var candidate = min(max(offset, lowerBound), source.utf16.count)
        while candidate > lowerBound,
              !isValidBoundary(in: source, utf16Offset: candidate) {
            candidate -= 1
        }
        return candidate
    }

    private static func validUTF16Offset(
        in source: String,
        atOrAfter offset: Int,
        upperBound: Int
    ) -> Int {
        var candidate = min(max(offset, 0), upperBound)
        while candidate < upperBound,
              !isValidBoundary(in: source, utf16Offset: candidate) {
            candidate += 1
        }
        return candidate
    }

    private static func isValidBoundary(
        in source: String,
        utf16Offset: Int
    ) -> Bool {
        if utf16Offset == source.utf16.count {
            return true
        }
        let utf16Index = source.utf16.index(
            source.utf16.startIndex,
            offsetBy: utf16Offset
        )
        return String.Index(utf16Index, within: source) != nil
    }

    private static func stringIndex(
        in source: String,
        utf16Offset: Int
    ) -> String.Index {
        if utf16Offset == source.utf16.count {
            return source.endIndex
        }

        let utf16Index = source.utf16.index(
            source.utf16.startIndex,
            offsetBy: utf16Offset
        )
        return String.Index(utf16Index, within: source) ?? source.endIndex
    }
}
