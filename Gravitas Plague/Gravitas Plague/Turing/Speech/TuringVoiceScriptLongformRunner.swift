import Foundation

struct TuringVoiceScriptLongformRunner: Sendable {
    private let segmentationService: TuringParallelExactSegmentationService

    init(
        segmentationService: TuringParallelExactSegmentationService = TuringParallelExactSegmentationService()
    ) {
        self.segmentationService = segmentationService
    }

    func segmentStream(
        request: TuringLongformVoiceScriptRequest
    ) -> AsyncThrowingStream<TuringExactSpeechSegment, Error> {
        segmentationService.segmentStream(request: request)
    }

    func segmentAll(
        request: TuringLongformVoiceScriptRequest
    ) async throws -> [TuringExactSpeechSegment] {
        try await segmentationService.segmentAll(request: request)
    }
}
