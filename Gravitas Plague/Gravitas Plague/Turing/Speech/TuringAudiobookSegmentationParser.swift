import Foundation

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
