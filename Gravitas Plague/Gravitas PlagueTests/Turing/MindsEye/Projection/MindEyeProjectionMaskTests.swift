import Foundation
import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionMaskTests: XCTestCase {
    func testMaskIs16BitDeterministicAndFiltersTinyIsland() throws {
        let size = 32
        let bytesPerRow = size * 4
        var bytes = Data(repeating: 0, count: bytesPerRow * size)
        bytes.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for y in 8..<24 {
                for x in 8..<24 {
                    let offset = y * bytesPerRow + x * 4
                    pixels[offset] = 255
                    pixels[offset + 1] = 255
                    pixels[offset + 2] = 255
                    pixels[offset + 3] = 255
                }
            }
            pixels[4] = 255
            pixels[5] = 255
            pixels[6] = 255
            pixels[7] = 255
        }
        let buffer = MindEyeProjectionPixelBuffer(
            width: size,
            height: size,
            bytesPerRow: bytesPerRow,
            bgra8: bytes
        )
        let first = try MindEyeProjectionMaskProcessor.process(buffer, inset: 2, feather: 4)
        let second = try MindEyeProjectionMaskProcessor.process(buffer, inset: 2, feather: 4)
        XCTAssertEqual(first.linear16, second.linear16)
        XCTAssertEqual(first.preview8, second.preview8)
        XCTAssertEqual(first.linear16.count, size * size)
        XCTAssertGreaterThan(first.linear16.max() ?? 0, 255)
        XCTAssertEqual(first.preview8[1], 0)
        XCTAssertFalse(first.metrics.touchesEdge)
    }
}
