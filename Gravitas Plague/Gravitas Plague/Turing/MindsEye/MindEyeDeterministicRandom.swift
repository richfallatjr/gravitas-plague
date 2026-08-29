import CryptoKit
import Foundation

nonisolated struct MindEyeDeterministicRandom: Sendable, Equatable {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xA0761D6478BD642F : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func nextUnitDouble() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func nextUnitFloat() -> Float { Float(nextUnitDouble()) }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        let lower = min(range.lowerBound, range.upperBound)
        let upper = max(range.lowerBound, range.upperBound)
        return lower + (upper - lower) * nextUnitFloat()
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let lower = min(range.lowerBound, range.upperBound)
        let upper = max(range.lowerBound, range.upperBound)
        let count = upper - lower + 1
        guard count > 1 else { return lower }
        return lower + Int(nextUInt64() % UInt64(count))
    }

    mutating func centerBiasedSigned() -> Float {
        nextUnitFloat() + nextUnitFloat() - 1
    }

    mutating func centerBiasedUnit() -> Float {
        (nextUnitFloat() + nextUnitFloat()) * 0.5
    }

    mutating func chance(_ probability: Float) -> Bool {
        nextUnitFloat() < min(1, max(0, probability))
    }
}

nonisolated struct MindEyeMotionSeedDescriptor: Sendable, Equatable {
    let vignetteID: String
    let speakerCharacterID: String
    let playbackRunID: String
    let flowInstanceID: UUID
    let sourceIdentity: String
}

nonisolated enum MindEyeMotionSeedFactory {
    static func rootSeed(for descriptor: MindEyeMotionSeedDescriptor) -> UInt64 {
        stableSeed([
            "mind-eye-motion-v1",
            descriptor.vignetteID,
            descriptor.speakerCharacterID,
            descriptor.playbackRunID,
            descriptor.flowInstanceID.uuidString.lowercased(),
            descriptor.sourceIdentity
        ].joined(separator: "|"), fallback: 0xD1B54A32D192ED03)
    }

    static func substreamSeed(root: UInt64, tag: String) -> UInt64 {
        stableSeed("\(root)|\(tag)", fallback: root ^ 0x94D049BB133111EB)
    }

    private static func stableSeed(_ text: String, fallback: UInt64) -> UInt64 {
        let digest = SHA256.hash(data: Data(text.utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        return value == 0 ? fallback : value
    }
}

nonisolated struct MindEyeMotionRandomStreams: Sendable, Equatable {
    var drift: MindEyeDeterministicRandom
    var subject: MindEyeDeterministicRandom
    var grip: MindEyeDeterministicRandom
    var blink: MindEyeDeterministicRandom
    var openEyes: MindEyeDeterministicRandom
    var closedEyes: MindEyeDeterministicRandom

    init(rootSeed: UInt64) {
        drift = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "drift"))
        subject = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "subject"))
        grip = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "grip"))
        blink = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "blink"))
        openEyes = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "open-eyes"))
        closedEyes = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "closed-eyes"))
    }
}

nonisolated struct MindEyeKeepAliveContext: Sendable, Equatable {
    let seedDescriptor: MindEyeMotionSeedDescriptor
    let explicitTestSeed: UInt64?

    init(
        seedDescriptor: MindEyeMotionSeedDescriptor,
        explicitTestSeed: UInt64? = nil
    ) {
        self.seedDescriptor = seedDescriptor
        self.explicitTestSeed = explicitTestSeed
    }

    var resolvedRootSeed: UInt64 {
        explicitTestSeed ?? MindEyeMotionSeedFactory.rootSeed(for: seedDescriptor)
    }
}
