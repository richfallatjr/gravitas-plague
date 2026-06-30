import Foundation

enum TuringQwenNativeBaseCloneDecodeTrimmer {
    static let samplesPerCodebookRow = 1_920

    static func trimReferencePrefix(
        from samples: [Float],
        referenceRowCount: Int
    ) throws -> [Float] {
        guard referenceRowCount >= 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Reference row count cannot be negative."
            )
        }
        let trimSamples = min(
            samples.count,
            referenceRowCount * samplesPerCodebookRow
        )
        return Array(samples.dropFirst(trimSamples))
    }
}
