#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation

nonisolated struct MindEyeProjectionProcessedMask: Sendable {
    let linear16: [UInt16]
    let preview8: [UInt8]
    let metrics: MindEyeProjectionValidation.MaskMetrics
}

nonisolated enum MindEyeProjectionMaskProcessor {
    static func process(
        _ buffer: MindEyeProjectionPixelBuffer,
        inset: Float,
        feather: Float,
        foregroundIsDark: Bool = false
    ) throws -> MindEyeProjectionProcessedMask {
        let width = buffer.width
        let height = buffer.height
        let binary = isolatedForeground(
            buffer,
            foregroundIsDark: foregroundIsDark
        )
        return try process(
            binary: binary,
            width: width,
            height: height,
            inset: inset,
            feather: feather
        )
    }

    /// Converts a flat mask AOV into one isolated receiver region. The
    /// owner-authored Angel mask uses black for the facial receiver and white
    /// for the surrounding mesh, so that case selects the component containing
    /// the locked camera center instead of the much larger black background.
    static func isolatedForeground(
        _ buffer: MindEyeProjectionPixelBuffer,
        foregroundIsDark: Bool
    ) -> [Bool] {
        let width = buffer.width
        let height = buffer.height
        var binary = [Bool](repeating: false, count: width * height)
        buffer.bgra8.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                let row = bytes + y * buffer.bytesPerRow
                for x in 0..<width {
                    let pixel = row + x * 4
                    let luminance = max(pixel[0], max(pixel[1], pixel[2]))
                    binary[y * width + x] = foregroundIsDark
                        ? luminance < 128
                        : luminance >= 128
                }
            }
        }
        return foregroundIsDark
            ? keepCenterComponent(binary, width: width, height: height)
            : keepLargestComponent(binary, width: width, height: height)
    }

    private static func process(
        binary: [Bool],
        width: Int,
        height: Int,
        inset: Float,
        feather: Float
    ) throws -> MindEyeProjectionProcessedMask {
        let insideSquared = squaredDistance(toValue: false, binary: binary, width: width, height: height)
        let outsideSquared = squaredDistance(toValue: true, binary: binary, width: width, height: height)
        var linear16 = [UInt16](repeating: 0, count: binary.count)
        var preview = [UInt8](repeating: 0, count: binary.count)
        var nonzero = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        var touchesEdge = false
        for index in binary.indices {
            let signed = binary[index]
                ? sqrt(Float(insideSquared[index]))
                : -sqrt(Float(outsideSquared[index]))
            let value = smootherstep(-feather, inset, signed)
            linear16[index] = UInt16((value * 65_535).rounded())
            preview[index] = UInt8((value * 255).rounded())
            if value > 0 {
                nonzero += 1
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { touchesEdge = true }
            }
        }
        guard nonzero > 0 else { throw MindEyeProjectionError.invalidCapture("mask is empty") }
        let centerX = Double(minX + maxX) * 0.5
        let centerY = Double(minY + maxY) * 0.5
        let metrics = MindEyeProjectionValidation.MaskMetrics(
            coverageFraction: Double(nonzero) / Double(width * height),
            boundingBox: [minX, minY, maxX - minX + 1, maxY - minY + 1],
            centerErrorPixels: [centerX - Double(width - 1) * 0.5, centerY - Double(height - 1) * 0.5],
            touchesEdge: touchesEdge
        )
        return MindEyeProjectionProcessedMask(linear16: linear16, preview8: preview, metrics: metrics)
    }

    private static func keepCenterComponent(
        _ input: [Bool],
        width: Int,
        height: Int
    ) -> [Bool] {
        let center = (height / 2) * width + width / 2
        guard input.indices.contains(center), input[center] else {
            return [Bool](repeating: false, count: input.count)
        }
        var output = [Bool](repeating: false, count: input.count)
        var queue = [center]
        var head = 0
        output[center] = true
        while head < queue.count {
            let value = queue[head]
            head += 1
            let x = value % width
            let y = value / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let next = ny * width + nx
                if input[next] && !output[next] {
                    output[next] = true
                    queue.append(next)
                }
            }
        }
        return output
    }

    private static func smootherstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let u = min(1, max(0, (value - edge0) / max(edge1 - edge0, 0.000_001)))
        return u * u * u * (u * (u * 6 - 15) + 10)
    }

    private static func keepLargestComponent(_ input: [Bool], width: Int, height: Int) -> [Bool] {
        var visited = [Bool](repeating: false, count: input.count)
        var largest: [Int] = []
        for start in input.indices where input[start] && !visited[start] {
            var queue = [start], head = 0, component: [Int] = []
            visited[start] = true
            while head < queue.count {
                let value = queue[head]; head += 1; component.append(value)
                let x = value % width, y = value / width
                let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                for (nx, ny) in neighbors where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let next = ny * width + nx
                    if input[next] && !visited[next] { visited[next] = true; queue.append(next) }
                }
            }
            if component.count > largest.count { largest = component }
        }
        var output = [Bool](repeating: false, count: input.count)
        for index in largest { output[index] = true }
        return output
    }

    // Felzenszwalb/Huttenlocher exact squared Euclidean distance transform.
    private static func squaredDistance(
        toValue target: Bool,
        binary: [Bool],
        width: Int,
        height: Int
    ) -> [Int] {
        let infinity = 1_000_000_000
        var intermediate = [Int](repeating: infinity, count: binary.count)
        var output = [Int](repeating: infinity, count: binary.count)
        for x in 0..<width {
            var f = [Int](repeating: infinity, count: height)
            for y in 0..<height where binary[y * width + x] == target { f[y] = 0 }
            let d = distanceTransform1D(f)
            for y in 0..<height { intermediate[y * width + x] = d[y] }
        }
        for y in 0..<height {
            let f = Array(intermediate[(y * width)..<((y + 1) * width)])
            let d = distanceTransform1D(f)
            for x in 0..<width { output[y * width + x] = d[x] }
        }
        return output
    }

    private static func distanceTransform1D(_ f: [Int]) -> [Int] {
        let n = f.count
        var sites = [Int](repeating: 0, count: n)
        var boundaries = [Double](repeating: 0, count: n + 1)
        var d = [Int](repeating: 0, count: n)
        var k = 0
        sites[0] = 0; boundaries[0] = -.infinity; boundaries[1] = .infinity
        for q in 1..<n {
            var intersection: Double
            repeat {
                let p = sites[k]
                intersection = Double((f[q] + q * q) - (f[p] + p * p)) / Double(2 * (q - p))
                if intersection <= boundaries[k] { k -= 1 }
            } while intersection <= boundaries[k]
            k += 1; sites[k] = q; boundaries[k] = intersection; boundaries[k + 1] = .infinity
        }
        k = 0
        for q in 0..<n {
            while boundaries[k + 1] < Double(q) { k += 1 }
            let delta = q - sites[k]
            d[q] = delta * delta + f[sites[k]]
        }
        return d
    }
}
#endif
