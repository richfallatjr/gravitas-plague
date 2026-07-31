import Foundation

enum TuringAudiobookSegmentationResponseDecoder {
    private static let toolCallPrefix =
        "tool:call:create_segment_for_text("

    static func decode(
        _ raw: String,
        expectedSectionIndex: Int
    ) throws -> TuringAudiobookSegmentationPayload {
        do {
            let data = try TuringJSONSanitizer.extractSingleTopLevelObject(
                from: raw
            )
            return try JSONDecoder().decode(
                TuringAudiobookSegmentationPayload.self,
                from: data
            )
        } catch {
            guard let payload = decodeToolCalls(
                raw,
                expectedSectionIndex: expectedSectionIndex
            ) else {
                throw error
            }

            print("""
            [TuringFoundation] audiobook tool-call response accepted locally
              sectionIndex: \(expectedSectionIndex)
              segmentCount: \(payload.segments.count)
              foundationRepairRequested: false
            """)
            return payload
        }
    }

    private static func decodeToolCalls(
        _ raw: String,
        expectedSectionIndex: Int
    ) -> TuringAudiobookSegmentationPayload? {
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return nil
        }

        var segments: [TuringAudiobookSegmentationPayload.Segment] = []
        segments.reserveCapacity(lines.count)

        for line in lines {
            guard line.hasPrefix(toolCallPrefix), line.hasSuffix(")") else {
                return nil
            }

            let argumentsStart = line.index(
                line.startIndex,
                offsetBy: toolCallPrefix.count
            )
            let argumentsEnd = line.index(before: line.endIndex)
            let arguments = String(line[argumentsStart..<argumentsEnd])
            let arraySource = "[\(arguments)]"

            guard let data = arraySource.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data)
                    as? [Any],
                  values.count == 3,
                  let rawSpokenText = values[0] as? String,
                  values[1] is NSNumber,
                  let rawEmotion = values[2] as? String else {
                return nil
            }

            let spokenText = rawSpokenText
                .replacingOccurrences(of: #"\""#, with: #"""#)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let emotion = rawEmotion.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            guard !spokenText.isEmpty else {
                return nil
            }

            segments.append(
                TuringAudiobookSegmentationPayload.Segment(
                    index: segments.count,
                    spokenText: spokenText,
                    emotion: emotion.isEmpty ? "narration" : emotion
                )
            )
        }

        return TuringAudiobookSegmentationPayload(
            schemaVersion: 1,
            sectionIndex: expectedSectionIndex,
            segments: segments
        )
    }
}

enum TuringAudiobookDeterministicSegmenter {
    private static let maximumWords = 30
    private static let maximumUTF16 = 190

    static func payload(
        sourceText: String,
        sectionIndex: Int,
        emotion: String = "narration"
    ) -> TuringAudiobookSegmentationPayload {
        let sentences = sentenceTexts(in: sourceText)
        let units = sentences.flatMap(splitOversizedSentence)
        var chunks: [String] = []
        var current = ""

        for unit in units {
            let candidate = current.isEmpty ? unit : "\(current) \(unit)"
            if current.isEmpty || fits(candidate) {
                current = candidate
            } else {
                chunks.append(current)
                current = unit
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        if chunks.isEmpty {
            let trimmed = sourceText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                chunks = [trimmed]
            }
        }

        return TuringAudiobookSegmentationPayload(
            schemaVersion: 1,
            sectionIndex: sectionIndex,
            segments: chunks.enumerated().map { index, text in
                TuringAudiobookSegmentationPayload.Segment(
                    index: index,
                    spokenText: text,
                    emotion: emotion
                )
            }
        )
    }

    private static func sentenceTexts(in sourceText: String) -> [String] {
        var sentences: [String] = []
        sourceText.enumerateSubstrings(
            in: sourceText.startIndex..<sourceText.endIndex,
            options: [.bySentences]
        ) { substring, _, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                sentences.append(trimmed)
            }
        }
        return sentences
    }

    private static func splitOversizedSentence(_ sentence: String) -> [String] {
        guard !fits(sentence) else {
            return [sentence]
        }

        let words = sentence.split(whereSeparator: \Character.isWhitespace)
        var chunks: [String] = []
        var current: [Substring] = []

        for word in words {
            let candidate = (current + [word]).map(String.init)
                .joined(separator: " ")
            if current.isEmpty || fits(candidate) {
                current.append(word)
            } else {
                chunks.append(current.map(String.init).joined(separator: " "))
                current = [word]
            }
        }

        if !current.isEmpty {
            chunks.append(current.map(String.init).joined(separator: " "))
        }
        return chunks
    }

    private static func fits(_ text: String) -> Bool {
        text.split(whereSeparator: \Character.isWhitespace).count <= maximumWords
            && text.utf16.count <= maximumUTF16
    }
}

struct TuringAudiobookSegmentationParser {
    let expectedSection: TuringAudiobookSourceSection
    let globalIndexOffset: Int

    func parseAcceptedSegments(
        _ payload: TuringAudiobookSegmentationPayload
    ) -> [TuringAudiobookSpeechSegment] {
        payload.segments.enumerated().map { localIndex, segment in
            let emotion = segment.emotion?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return TuringAudiobookSpeechSegment(
                globalIndex: globalIndexOffset + localIndex,
                sectionIndex: expectedSection.index,
                localIndex: localIndex,
                spokenText: segment.spokenText,
                emotion: emotion?.isEmpty == false ? emotion! : "narration"
            )
        }
    }

    static func noteGlobalSemanticValidationSkipped(
        _ plan: TuringPhase1AudiobookPlan
    ) {
        print("""
        [TuringPhase1Audiobook] global semantic validation skipped
          semanticValidation: disabled
          segmentCount: \(plan.segmentCount)
        """)
    }
}
