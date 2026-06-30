import Foundation

enum TuringQwenNativeBaseCloneDecodeTrimmer {
    static let samplesPerCodebookRow = 1_920

    static func trimReferencePrefix(
        from samples: [Float],
        referenceRowCount: Int,
        totalRowCount: Int? = nil
    ) throws -> [Float] {
        guard referenceRowCount >= 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Reference row count cannot be negative."
            )
        }
        let trimSamples: Int
        if let totalRowCount,
           totalRowCount > 0 {
            trimSamples = min(
                samples.count,
                Int(Double(referenceRowCount) / Double(totalRowCount) * Double(samples.count))
            )
        } else {
            trimSamples = min(
                samples.count,
                referenceRowCount * samplesPerCodebookRow
            )
        }
        return Array(samples.dropFirst(trimSamples))
    }
}
