import Foundation

enum TuringAudiobookSourceSectioner {
    static func makeSections(
        normalizedSource: String,
        policy: TuringAudiobookSourceSectionPolicy = .init()
    ) throws -> [TuringAudiobookSourceSection] {
        let units = try makeUnits(
            normalizedSource: normalizedSource,
            policy: policy
        )
        guard units.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "audiobookSourceSectioner emptyText"
            )
        }

        var sections: [TuringAudiobookSourceSection] = []
        var currentStart: Int?
        var currentEnd: Int?
        var currentWordCount = 0

        for unit in units {
            if let start = currentStart,
               let end = currentEnd,
               currentWordCount >= policy.minWords,
               shouldStartNewSection(
                   currentStart: start,
                   currentEnd: end,
                   currentWordCount: currentWordCount,
                   nextUnit: unit,
                   policy: policy
               ) {
                sections.append(
                    TuringAudiobookSourceSection(
                        index: sections.count,
                        sourceStartUTF16: start,
                        sourceEndUTF16: end,
                        estimatedWordCount: currentWordCount
                    )
                )
                currentStart = unit.startUTF16
                currentEnd = unit.endUTF16
                currentWordCount = unit.wordCount
            } else {
                if currentStart == nil {
                    currentStart = unit.startUTF16
                }
                currentEnd = unit.endUTF16
                currentWordCount += unit.wordCount
            }
        }

        if let start = currentStart,
           let end = currentEnd {
            sections.append(
                TuringAudiobookSourceSection(
                    index: sections.count,
                    sourceStartUTF16: start,
                    sourceEndUTF16: end,
                    estimatedWordCount: currentWordCount
                )
            )
        }

        return sections
    }

    static func sourceText(
        for section: TuringAudiobookSourceSection,
        in normalizedSource: String
    ) -> String {
        substring(
            normalizedSource,
            startUTF16: section.sourceStartUTF16,
            endUTF16: section.sourceEndUTF16
        )
    }

    private static func makeUnits(
        normalizedSource: String,
        policy: TuringAudiobookSourceSectionPolicy
    ) throws -> [TuringAudiobookSourceUnit] {
        var units: [TuringAudiobookSourceUnit] = []

        for paragraphRange in paragraphRanges(in: normalizedSource) {
            let paragraphText = String(normalizedSource[paragraphRange])
            let paragraphWords = wordCount(paragraphText)

            guard paragraphWords > 0 else {
                continue
            }

            let paragraphChars = paragraphText.utf16.count

            if paragraphWords > policy.maxWords
                || paragraphChars > policy.maxChars {
                let sentenceUnits = sentenceUnits(
                    in: paragraphRange,
                    normalizedSource: normalizedSource
                )

                guard sentenceUnits.isEmpty == false else {
                    print("""
                    [TuringAudiobookSourceSectioner] sentence enumeration failed; keeping paragraph unit
                      startUTF16: \(paragraphRange.lowerBound.utf16Offset(in: normalizedSource))
                      endUTF16: \(paragraphRange.upperBound.utf16Offset(in: normalizedSource))
                    """)
                    let unit = TuringAudiobookSourceUnit(
                        startUTF16: paragraphRange.lowerBound.utf16Offset(
                            in: normalizedSource
                        ),
                        endUTF16: paragraphRange.upperBound.utf16Offset(
                            in: normalizedSource
                        ),
                        wordCount: paragraphWords
                    )
                    try validateUnit(unit, policy: policy)
                    units.append(unit)
                    continue
                }

                for unit in sentenceUnits {
                    try validateUnit(unit, policy: policy)
                    units.append(unit)
                }
            } else {
                let unit = TuringAudiobookSourceUnit(
                    startUTF16: paragraphRange.lowerBound.utf16Offset(
                        in: normalizedSource
                    ),
                    endUTF16: paragraphRange.upperBound.utf16Offset(
                        in: normalizedSource
                    ),
                    wordCount: paragraphWords
                )
                try validateUnit(unit, policy: policy)
                units.append(unit)
            }
        }

        return units
    }

    private static func shouldStartNewSection(
        currentStart: Int,
        currentEnd: Int,
        currentWordCount: Int,
        nextUnit: TuringAudiobookSourceUnit,
        policy: TuringAudiobookSourceSectionPolicy
    ) -> Bool {
        let currentChars = currentEnd - currentStart
        let nextChars = nextUnit.endUTF16 - nextUnit.startUTF16
        return currentWordCount >= policy.targetWords
            || currentWordCount + nextUnit.wordCount > policy.maxWords
            || currentChars + nextChars > policy.maxChars
    }

    private static func validateUnit(
        _ unit: TuringAudiobookSourceUnit,
        policy: TuringAudiobookSourceSectionPolicy
    ) throws {
        let charCount = unit.endUTF16 - unit.startUTF16
        guard unit.wordCount <= policy.maxWords,
              charCount <= policy.maxChars else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "audiobookSourceUnitTooLarge wordCount=\(unit.wordCount) charCount=\(charCount)"
            )
        }
    }

    private static func paragraphRanges(
        in source: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = source.startIndex

        while start < source.endIndex {
            if let separator = source[start...].range(of: "\n\n") {
                ranges.append(start..<separator.lowerBound)
                start = separator.upperBound
            } else {
                ranges.append(start..<source.endIndex)
                break
            }
        }

        return ranges
    }

    private static func sentenceUnits(
        in paragraphRange: Range<String.Index>,
        normalizedSource: String
    ) -> [TuringAudiobookSourceUnit] {
        var units: [TuringAudiobookSourceUnit] = []
        normalizedSource.enumerateSubstrings(
            in: paragraphRange,
            options: [.bySentences, .substringNotRequired]
        ) { _, sentenceRange, _, _ in
            let text = String(normalizedSource[sentenceRange])
            let count = wordCount(text)
            guard count > 0 else {
                return
            }

            units.append(
                TuringAudiobookSourceUnit(
                    startUTF16: sentenceRange.lowerBound.utf16Offset(
                        in: normalizedSource
                    ),
                    endUTF16: sentenceRange.upperBound.utf16Offset(
                        in: normalizedSource
                    ),
                    wordCount: count
                )
            )
        }

        return units
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func substring(
        _ source: String,
        startUTF16: Int,
        endUTF16: Int
    ) -> String {
        guard startUTF16 < endUTF16 else { return "" }
        let start = stringIndex(in: source, utf16Offset: startUTF16)
        let end = stringIndex(in: source, utf16Offset: endUTF16)
        return String(source[start..<end])
    }

    private static func stringIndex(
        in source: String,
        utf16Offset: Int
    ) -> String.Index {
        if utf16Offset == source.utf16.count {
            return source.endIndex
        }

        let index = source.utf16.index(
            source.utf16.startIndex,
            offsetBy: utf16Offset
        )
        return String.Index(index, within: source) ?? source.endIndex
    }
}
