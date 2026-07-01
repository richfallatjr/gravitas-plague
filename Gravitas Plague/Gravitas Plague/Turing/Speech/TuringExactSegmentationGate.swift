import Foundation

enum TuringExactSegmentationGate {
    static func gate(
        payload: TuringExactSegmentationPayload,
        job: TuringExactSegmentationJob,
        defaultEmotion: String
    ) throws -> [TuringExactSpeechSegment] {
        guard payload.version == 1 else {
            throw gateError("version must be 1.")
        }
        guard payload.chunkIndex == job.index,
              payload.focusStartUTF16 == job.focusStartUTF16,
              payload.focusEndUTF16 == job.focusEndUTF16 else {
            throw gateError("payload chunk identity did not match job.")
        }
        guard payload.targetSeconds == 4.0,
              payload.maxSeconds == 5.0 else {
            throw gateError("targetSeconds/maxSeconds must be 4.0/5.0.")
        }
        guard payload.segments.isEmpty == false else {
            throw gateError("segments must not be empty.")
        }

        for (expectedIndex, segment) in payload.segments.enumerated() {
            guard segment.index == expectedIndex else {
                throw gateError(
                    "segment index \(segment.index) did not match \(expectedIndex)."
                )
            }
            guard segment.spokenText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false else {
                throw gateError("segment \(expectedIndex) text was empty.")
            }
        }

        let normalizedFocus = normalizeForCoverage(job.focusText)
        let normalizedSegments = normalizeForCoverage(
            payload.segments.map(\.spokenText).joined(separator: " ")
        )
        guard normalizedFocus == normalizedSegments else {
            throw gateError("concatenated segment text did not match focus text.")
        }

        var searchStart = job.focusText.startIndex
        return try payload.segments.map { segment in
            let trimmed = segment.spokenText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard let range = job.focusText[searchStart...].range(of: trimmed) else {
                throw gateError(
                    "segment \(segment.index) could not be mapped into focus text."
                )
            }

            searchStart = range.upperBound
            let localStart = range.lowerBound.utf16Offset(in: job.focusText)
            let localEnd = range.upperBound.utf16Offset(in: job.focusText)

            return TuringExactSpeechSegment(
                globalIndex: 0,
                chunkIndex: job.index,
                localIndex: segment.index,
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
