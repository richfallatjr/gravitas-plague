import Foundation

enum TuringExactSegmentationGate {
    static func gate(
        payload: TuringExactSegmentationPayload,
        job: TuringExactSegmentationJob,
        defaultEmotion: String
    ) throws -> [TuringExactSpeechSegment] {
        let usableSegments = payload.segments.compactMap { segment -> String? in
            let trimmed = segment.spokenText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        }

        guard usableSegments.isEmpty == false else {
            throw gateError("segments must not be empty.")
        }

        let normalizedFocus = normalizeForCoverage(job.focusText)
        let normalizedSegments = normalizeForCoverage(
            usableSegments.joined(separator: " ")
        )
        if normalizedFocus != normalizedSegments {
            print("""
            [TuringPhase1Longform] exact coverage mismatch logged
              chunkIndex: \(job.index)
              focusUTF16: \(job.focusText.utf16.count)
              segmentUTF16: \(usableSegments.joined(separator: " ").utf16.count)
              qwenContinues: true
            """)
        }

        var searchStart = job.focusText.startIndex
        return usableSegments.enumerated().map { localIndex, trimmed in
            let range = job.focusText[searchStart...].range(of: trimmed)
            let localStart: Int
            let localEnd: Int
            if let range {
                searchStart = range.upperBound
                localStart = range.lowerBound.utf16Offset(in: job.focusText)
                localEnd = range.upperBound.utf16Offset(in: job.focusText)
            } else {
                print("""
                [TuringPhase1Longform] segment range mapping failed
                  chunkIndex: \(job.index)
                  localIndex: \(localIndex)
                  qwenContinues: true
                """)
                localStart = searchStart.utf16Offset(in: job.focusText)
                localEnd = min(
                    job.focusText.utf16.count,
                    localStart + trimmed.utf16.count
                )
            }

            return TuringExactSpeechSegment(
                globalIndex: 0,
                chunkIndex: job.index,
                localIndex: localIndex,
                absoluteStartUTF16: job.focusStartUTF16 + localStart,
                absoluteEndUTF16: job.focusStartUTF16 + localEnd,
                text: trimmed,
                emotion: defaultEmotion
            )
        }
    }

    private static func normalizeForCoverage(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func gateError(_ detail: String) -> TuringRuntimeError {
        TuringRuntimeError.foundationJSONGateFailed(detail)
    }
}
