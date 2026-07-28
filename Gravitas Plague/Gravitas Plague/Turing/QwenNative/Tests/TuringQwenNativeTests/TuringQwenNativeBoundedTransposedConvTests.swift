import MLX
import Testing
@testable import TuringQwenNative

struct TuringQwenNativeBoundedTransposedConvTests {
    @Test func boundedImplementationMatchesNativeTransposedConvolution() throws {
        let input = MLXArray(
            [
                0.25, -0.50,
                1.00, 0.75,
                -0.25, 0.50
            ] as [Float],
            [1, 3, 2]
        )
        let weight = MLXArray(
            [
                0.10, 0.20,
                0.30, 0.40,
                0.50, 0.60,
                0.70, 0.80,

                -0.10, 0.15,
                -0.20, 0.25,
                -0.30, 0.35,
                -0.40, 0.45,

                0.05, -0.15,
                0.25, -0.35,
                0.45, -0.55,
                0.65, -0.75
            ] as [Float],
            [3, 4, 2]
        )
        let bias = MLXArray([0.01, -0.02, 0.03] as [Float])
        let rightCrop = 2

        var native = convTransposed1d(
            input,
            weight,
            stride: 2,
            padding: 0,
            dilation: 1,
            outputPadding: 0
        ) + bias
        native = native[..<(native.dim(1) - rightCrop), axis: 1]
        eval(native)

        let bounded = try TuringQwenNativeSpeechDecoder
            .boundedTransposedConv1d(
                input,
                weight: weight,
                bias: bias,
                stride: 2,
                rightCrop: rightCrop
            )

        #expect(bounded.shape == native.shape)
        let expected = native.asArray(Float.self)
        let actual = bounded.asArray(Float.self)
        #expect(actual.count == expected.count)
        for (actualValue, expectedValue) in zip(actual, expected) {
            #expect(abs(actualValue - expectedValue) < 0.0001)
        }
    }
}
