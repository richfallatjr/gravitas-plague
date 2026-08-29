import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

nonisolated protocol MindEyeAssetWorking: Sendable {
    func decodeJSON<T>(
        _ type: T.Type,
        from url: URL
    ) async throws -> T where T: Decodable & Sendable

    func inspectPNG(
        at url: URL,
        request: MindEyeImageInspectionRequest
    ) async throws -> MindEyeImageMetadata
}

nonisolated enum MindEyeImageRole:
    Sendable,
    Equatable,
    Hashable
{
    case background
    case characterBase
    case featherMask
    case eyeOpen(index: Int)
    case eyeClosed(index: Int)
    case mouth(pose: MindEyeMouthPose, index: Int)
}

nonisolated enum MindEyeImageSemanticRule:
    Sendable,
    Equatable
{
    case opaqueRGBA
    case nonemptyRGBAOverlay
    case grayscaleRGBMask
}

nonisolated struct MindEyeImageInspectionRequest:
    Sendable,
    Equatable
{
    let role: MindEyeImageRole
    let resourcePath: String
    let expectedSize: MindEyePixelSize
    let semanticRule: MindEyeImageSemanticRule
}

nonisolated struct MindEyePNGHeader:
    Sendable,
    Equatable
{
    let width: Int
    let height: Int
    let bitDepth: Int
    let colorType: Int
    let compressionMethod: Int
    let filterMethod: Int
    let interlaceMethod: Int
}

nonisolated struct MindEyeImageMetadata:
    Sendable,
    Equatable
{
    let role: MindEyeImageRole
    let resourcePath: String
    let fileURL: URL
    let byteCount: Int
    let sha256: String
    let header: MindEyePNGHeader
    let alphaMinimum: UInt8?
    let alphaMaximum: UInt8?
    let nonzeroAlphaPixelCount: Int?
    let transparentPixelCount: Int?
    let luminanceMinimum: UInt8?
    let luminanceMaximum: UInt8?
    let distinctLuminanceCount: Int?
}

nonisolated struct MindEyeWorkerExecutionObservation: Sendable, Equatable {
    enum Operation: String, Sendable, Equatable {
        case jsonDecode
        case pngInspection
    }

    let operation: Operation
    let isMainThread: Bool
    let queueVerified: Bool
}

nonisolated final class MindEyeSerialAssetWorker:
    @unchecked Sendable,
    MindEyeAssetWorking
{
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1
    private let executionObserver:
        (@Sendable (MindEyeWorkerExecutionObservation) -> Void)?

    init(
        label: String = "com.gravitas.plague.mindseye.asset-worker",
        executionObserver:
            (@Sendable (MindEyeWorkerExecutionObservation) -> Void)? = nil
    ) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.executionObserver = executionObserver
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    func decodeJSON<T>(
        _ type: T.Type,
        from url: URL
    ) async throws -> T where T: Decodable & Sendable {
        try Task.checkCancellation()
        let value: T = try await perform(operation: .jsonDecode) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw MindEyeFailure(
                    code: .assetZeroBytes,
                    characterID: nil,
                    vignetteID: nil,
                    resourcePath: url.lastPathComponent,
                    message: "Mind's Eye JSON resource is empty."
                )
            }
            return try JSONDecoder().decode(type, from: data)
        }
        try Task.checkCancellation()
        return value
    }

    func inspectPNG(
        at url: URL,
        request: MindEyeImageInspectionRequest
    ) async throws -> MindEyeImageMetadata {
        try Task.checkCancellation()
        let metadata = try await perform(operation: .pngInspection) {
            try Self.inspectPNGOnWorker(at: url, request: request)
        }
        try Task.checkCancellation()
        return metadata
    }

    private func perform<T: Sendable>(
        operation: MindEyeWorkerExecutionObservation.Operation,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                dispatchPrecondition(condition: .notOnQueue(.main))
                let queueVerified = DispatchQueue.getSpecific(key: queueKey) == queueValue
                precondition(queueVerified)
                precondition(Thread.isMainThread == false)
                executionObserver?(
                    MindEyeWorkerExecutionObservation(
                        operation: operation,
                        isMainThread: Thread.isMainThread,
                        queueVerified: queueVerified
                    )
                )
                let result: Result<T, Error> = autoreleasepool {
                    Result(catching: body)
                }
                continuation.resume(with: result)
            }
        }
    }

    private static func inspectPNGOnWorker(
        at url: URL,
        request: MindEyeImageInspectionRequest
    ) throws -> MindEyeImageMetadata {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw failure(
                .assetMissing,
                request: request,
                message: "Mind's Eye PNG is missing or unreadable: \(error.localizedDescription)"
            )
        }
        guard !data.isEmpty else {
            throw failure(.assetZeroBytes, request: request, message: "Mind's Eye PNG is zero bytes.")
        }

        let header = try parseHeader(data, request: request)
        guard header.width == request.expectedSize.width,
              header.height == request.expectedSize.height else {
            throw failure(.wrongDimensions, request: request, message: "PNG dimensions do not match its semantic role.")
        }

        switch request.semanticRule {
        case .opaqueRGBA, .nonemptyRGBAOverlay:
            guard header.bitDepth == 8, header.colorType == 6 else {
                throw failure(.invalidPNG, request: request, message: "Source layers must be 8-bit RGBA PNGs.")
            }
        case .grayscaleRGBMask:
            guard header.bitDepth == 8, header.colorType == 2 else {
                throw failure(.invalidFeatherMask, request: request, message: "Feather mask must be an 8-bit truecolor RGB PNG without alpha.")
            }
        }
        guard header.compressionMethod == 0,
              header.filterMethod == 0,
              header.interlaceMethod == 0 || header.interlaceMethod == 1 else {
            throw failure(.invalidPNG, request: request, message: "PNG IHDR methods are unsupported.")
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw failure(.invalidPNG, request: request, message: "ImageIO could not decode PNG.")
        }

        let pixelCount = try checkedProduct(
            header.width,
            header.height,
            request: request
        )
        let byteCount = try checkedProduct(pixelCount, 4, request: request)
        var pixels = [UInt8](repeating: 0, count: byteCount)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw failure(.invalidPNG, request: request, message: "Could not create sRGB color space.")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: header.width,
                    height: header.height,
                    bitsPerComponent: 8,
                    bytesPerRow: header.width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: header.width, height: header.height)
            )
            return true
        }
        guard rendered else {
            throw failure(.invalidPNG, request: request, message: "Could not allocate PNG inspection context.")
        }

        var alphaMinimum = UInt8.max
        var alphaMaximum = UInt8.min
        var nonzeroAlphaPixelCount = 0
        var transparentPixelCount = 0
        var luminanceMinimum = UInt8.max
        var luminanceMaximum = UInt8.min
        var luminances = Set<UInt8>()
        var unequalMaskChannels = false

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            let alpha = pixels[offset + 3]
            alphaMinimum = min(alphaMinimum, alpha)
            alphaMaximum = max(alphaMaximum, alpha)
            if alpha > 0 { nonzeroAlphaPixelCount += 1 }
            if alpha < 255 { transparentPixelCount += 1 }

            if request.semanticRule == .grayscaleRGBMask {
                let differences = [
                    abs(Int(red) - Int(green)),
                    abs(Int(green) - Int(blue)),
                    abs(Int(red) - Int(blue))
                ]
                if differences.contains(where: { $0 > 2 }) {
                    unequalMaskChannels = true
                }
                let luminance = UInt8(
                    (Int(red) + Int(green) + Int(blue)) / 3
                )
                luminanceMinimum = min(luminanceMinimum, luminance)
                luminanceMaximum = max(luminanceMaximum, luminance)
                luminances.insert(luminance)
            }
        }

        switch request.semanticRule {
        case .opaqueRGBA:
            guard alphaMinimum == 255, alphaMaximum == 255 else {
                throw failure(.invalidBackgroundAlpha, request: request, message: "Background alpha is not fully opaque.")
            }
        case .nonemptyRGBAOverlay:
            guard nonzeroAlphaPixelCount > 0 else {
                throw failure(.invalidOverlayAlpha, request: request, message: "Layer must contain visible pixels.")
            }
            if request.role != .characterBase,
               transparentPixelCount == 0 {
                throw failure(.invalidOverlayAlpha, request: request, message: "Eye/mouth overlay must contain transparent pixels.")
            }
        case .grayscaleRGBMask:
            guard alphaMinimum == 255,
                  alphaMaximum == 255,
                  !unequalMaskChannels,
                  luminanceMinimum <= 8,
                  luminanceMaximum >= 247,
                  luminances.count >= 16 else {
                throw failure(.invalidFeatherMask, request: request, message: "Feather mask channels or luminance range are invalid.")
            }
        }

        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let isMask = request.semanticRule == .grayscaleRGBMask
        return MindEyeImageMetadata(
            role: request.role,
            resourcePath: request.resourcePath,
            fileURL: url,
            byteCount: data.count,
            sha256: digest,
            header: header,
            alphaMinimum: isMask ? nil : alphaMinimum,
            alphaMaximum: isMask ? nil : alphaMaximum,
            nonzeroAlphaPixelCount: isMask ? nil : nonzeroAlphaPixelCount,
            transparentPixelCount: isMask ? nil : transparentPixelCount,
            luminanceMinimum: isMask ? luminanceMinimum : nil,
            luminanceMaximum: isMask ? luminanceMaximum : nil,
            distinctLuminanceCount: isMask ? luminances.count : nil
        )
    }

    private static func parseHeader(
        _ data: Data,
        request: MindEyeImageInspectionRequest
    ) throws -> MindEyePNGHeader {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= 33,
              Array(data.prefix(8)) == signature,
              readUInt32(data, at: 8) == 13,
              String(data: data[12 ..< 16], encoding: .ascii) == "IHDR" else {
            throw failure(.invalidPNG, request: request, message: "PNG signature or first IHDR chunk is invalid.")
        }
        return MindEyePNGHeader(
            width: Int(readUInt32(data, at: 16)),
            height: Int(readUInt32(data, at: 20)),
            bitDepth: Int(data[24]),
            colorType: Int(data[25]),
            compressionMethod: Int(data[26]),
            filterMethod: Int(data[27]),
            interlaceMethod: Int(data[28])
        )
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset ..< offset + 4].reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func checkedProduct(
        _ left: Int,
        _ right: Int,
        request: MindEyeImageInspectionRequest
    ) throws -> Int {
        let product = left.multipliedReportingOverflow(by: right)
        guard !product.overflow else {
            throw failure(.invalidPNG, request: request, message: "PNG size calculation overflowed.")
        }
        return product.partialValue
    }

    private static func failure(
        _ code: MindEyeFailureCode,
        request: MindEyeImageInspectionRequest,
        message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: code,
            characterID: nil,
            vignetteID: nil,
            resourcePath: request.resourcePath,
            message: message
        )
    }
}
