#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum MindEyeProjectionPNGWriter {
    static func writeBGRA8(_ buffer: MindEyeProjectionPixelBuffer, to url: URL) throws {
        guard let provider = CGDataProvider(data: buffer.bgra8 as CFData),
              let image = CGImage(
                width: buffer.width,
                height: buffer.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: buffer.bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw MindEyeProjectionError.invalidCapture("could not create BGRA image")
        }
        try write(image, to: url)
    }

    static func writeGray16(_ pixels: [UInt16], width: Int, height: Int, to url: URL) throws {
        var bigEndian = pixels.map(\.bigEndian)
        let data = bigEndian.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: .byteOrder16Big,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw MindEyeProjectionError.invalidCapture("could not create linear16 mask")
        }
        try write(image, to: url)
    }

    static func writeGray8(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw MindEyeProjectionError.invalidCapture("could not create mask preview")
        }
        try write(image, to: url)
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw MindEyeProjectionError.invalidCapture("could not create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MindEyeProjectionError.invalidCapture("could not finalize \(url.lastPathComponent)")
        }
    }
}
#endif
