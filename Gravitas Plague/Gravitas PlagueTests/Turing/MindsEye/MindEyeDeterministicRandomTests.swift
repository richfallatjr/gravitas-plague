import XCTest

@testable import Gravitas_Plague

final class MindEyeDeterministicRandomTests: XCTestCase {
    func testLockedSplitMix64Sequence() {
        var random = MindEyeDeterministicRandom(seed: 0x0123_4567_89AB_CDEF)
        let expected: [UInt64] = [
            0x157A_3807_A48F_AA9D,
            0xD573_529B_34A1_D093,
            0x2F90_B72E_996D_CCBE,
            0xA2D4_1933_4C46_67EC,
            0x0140_4CE9_1493_8008,
            0x14BC_574C_2A2B_4C72,
            0xB8FC_5B10_6070_8C05,
            0x8931_545F_4F9E_A651,
            0xF984_DB4E_F14F_DE1B,
            0x2680_D065_CB73_ECE7
        ]
        XCTAssertEqual(expected, expected.map { _ in random.nextUInt64() })
    }

    func testZeroSeedIsRemappedDeterministically() {
        var left = MindEyeDeterministicRandom(seed: 0)
        var right = MindEyeDeterministicRandom(seed: 0)
        XCTAssertNotEqual(left.state, 0)
        XCTAssertEqual(left.nextUInt64(), right.nextUInt64())
    }

    func testGeneratedValuesStayInTheirRequestedBounds() {
        var random = MindEyeDeterministicRandom(seed: 77)
        for _ in 0..<1_000 {
            XCTAssertTrue((0..<1).contains(random.nextUnitDouble()))
            XCTAssertTrue((-4.5...2.25).contains(random.nextFloat(in: -4.5...2.25)))
            XCTAssertTrue((-1...1).contains(random.centerBiasedSigned()))
            XCTAssertTrue((3...9).contains(random.nextInt(in: 3...9)))
        }
        XCTAssertFalse(random.chance(0))
        XCTAssertTrue(random.chance(1))
    }

    func testSeedUsesStableIdentityAndIndependentSubstreams() {
        let descriptor = MindEyeMotionSeedDescriptor(
            vignetteID: "big_mike_current_room",
            speakerCharacterID: "bigMike",
            playbackRunID: "run-a",
            flowInstanceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sourceIdentity: "authored:pr-001"
        )
        let seed = MindEyeMotionSeedFactory.rootSeed(for: descriptor)
        XCTAssertEqual(seed, MindEyeMotionSeedFactory.rootSeed(for: descriptor))
        XCTAssertNotEqual(
            MindEyeMotionSeedFactory.substreamSeed(root: seed, tag: "drift"),
            MindEyeMotionSeedFactory.substreamSeed(root: seed, tag: "blink")
        )
    }
}
