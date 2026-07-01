import Foundation

struct TuringOrderedSegmentEmitter {
    func emitOrdered(
        chunkResults: [Int: [TuringExactSpeechSegment]]
    ) throws -> [TuringExactSpeechSegment] {
        var output: [TuringExactSpeechSegment] = []
        var globalIndex = 0

        for chunkIndex in chunkResults.keys.sorted() {
            guard let chunkSegments = chunkResults[chunkIndex] else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Missing ordered chunk \(chunkIndex)."
                )
            }

            for segment in chunkSegments {
                output.append(
                    TuringExactSpeechSegment(
                        globalIndex: globalIndex,
                        chunkIndex: segment.chunkIndex,
                        localIndex: segment.localIndex,
                        absoluteStartUTF16: segment.absoluteStartUTF16,
                        absoluteEndUTF16: segment.absoluteEndUTF16,
                        text: segment.text,
                        emotion: segment.emotion
                    )
                )
                globalIndex += 1
            }
        }

        return output
    }
}
