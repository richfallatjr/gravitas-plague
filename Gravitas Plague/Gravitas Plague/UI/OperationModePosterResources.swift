import Combine
import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import SwiftUI
import UIKit

struct PosterRGBA8: Sendable, Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    static let verifiedCurrentDarkest = PosterRGBA8(
        red: 43,
        green: 43,
        blue: 43,
        alpha: 255
    )

    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: CGFloat(alpha) / 255.0
        )
    }

    var swiftUIColor: Color {
        Color(uiColor: uiColor)
    }
}

struct OperationModePosterAnalysis: Sendable, Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let darkestOpaquePixel: PosterRGBA8
}

enum OperationModePosterAnalyzer {
    static func analyze(
        url: URL
    ) throws -> OperationModePosterAnalysis {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                nil
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: height * bytesPerRow
        )

        try pixels.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw NSError(
                    domain: "OperationModePosterAnalyzer",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Could not create poster analysis context."
                    ]
                )
            }

            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: height
                )
            )
        }

        var darkest = PosterRGBA8.verifiedCurrentDarkest
        var darkestLuminance = Int.max

        for index in stride(
            from: 0,
            to: pixels.count,
            by: bytesPerPixel
        ) {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            let alpha = pixels[index + 3]

            guard alpha >= 250 else {
                continue
            }

            let luminance =
                2_126 * Int(red) +
                7_152 * Int(green) +
                722 * Int(blue)

            if luminance < darkestLuminance {
                darkestLuminance = luminance
                darkest = PosterRGBA8(
                    red: red,
                    green: green,
                    blue: blue,
                    alpha: alpha
                )
            }
        }

        return OperationModePosterAnalysis(
            pixelWidth: width,
            pixelHeight: height,
            darkestOpaquePixel: darkest
        )
    }
}

@MainActor
final class OperationModePosterResources: ObservableObject {
    static let shared = OperationModePosterResources()

    @Published private(set) var image: UIImage?
    @Published private(set) var analysis: OperationModePosterAnalysis?

    private(set) var posterTexture: TextureResource?

    private init() {}

    var lockUIColor: UIColor {
        (
            analysis?.darkestOpaquePixel
                ?? .verifiedCurrentDarkest
        ).uiColor
    }

    var lockColor: Color {
        (
            analysis?.darkestOpaquePixel
                ?? .verifiedCurrentDarkest
        ).swiftUIColor
    }

    func loadIfNeeded() {
        if image != nil,
           analysis != nil,
           posterTexture != nil {
            return
        }

        guard let url = Bundle.main.url(
            forResource: OperationModePosterLayout.assetName,
            withExtension: OperationModePosterLayout.assetExtension
        ) else {
            print(
                """
                [PlagueMenu] ERROR missing single poster resource
                  asset: \(OperationModePosterLayout.assetName).\(OperationModePosterLayout.assetExtension)
                """
            )
            return
        }

        do {
            image = UIImage(contentsOfFile: url.path)
            analysis = try OperationModePosterAnalyzer.analyze(
                url: url
            )
            posterTexture = try TextureResource.load(
                contentsOf: url
            )

            print(
                """
                [PlagueMenu] single poster resource ready
                  file: \(url.lastPathComponent)
                  pixels: \(analysis?.pixelWidth ?? 0)x\(analysis?.pixelHeight ?? 0)
                  storyRect: \(OperationModePosterLayout.storySourceRect)
                  hordeRect: \(OperationModePosterLayout.hordeSourceRect)
                  sourceImageCount: 1
                """
            )
        } catch {
            print(
                """
                [PlagueMenu] ERROR loading single poster resource
                  error: \(error.localizedDescription)
                  fallbackImages: false
                """
            )
        }
    }
}

enum OperationModeLockReason: String, Sendable {
    case storyLockedForCurrentBuild
}

struct OperationModeAvailability: Sendable, Equatable {
    let isUnlocked: Bool
    let lockReason: OperationModeLockReason?

    static let unlocked = OperationModeAvailability(
        isUnlocked: true,
        lockReason: nil
    )

    static func locked(
        _ reason: OperationModeLockReason
    ) -> OperationModeAvailability {
        OperationModeAvailability(
            isUnlocked: false,
            lockReason: reason
        )
    }
}

struct OperationModeAccessSnapshot: Sendable, Equatable {
    let story: OperationModeAvailability
    let horde: OperationModeAvailability

    subscript(
        mode: PlagueDemoSession.PlagueOperationMode
    ) -> OperationModeAvailability {
        switch mode {
        case .story:
            return story

        case .horde:
            return horde

        case .walkLoop:
            return .unlocked
        }
    }
}

@MainActor
final class OperationModeAccessController: ObservableObject {
    static let shared = OperationModeAccessController()

    @Published private(set) var snapshot = OperationModeAccessSnapshot(
        story: .locked(.storyLockedForCurrentBuild),
        horde: .unlocked
    )

    private init() {}

    func refresh() {
        snapshot = OperationModeAccessSnapshot(
            story: .locked(.storyLockedForCurrentBuild),
            horde: .unlocked
        )
    }
}
