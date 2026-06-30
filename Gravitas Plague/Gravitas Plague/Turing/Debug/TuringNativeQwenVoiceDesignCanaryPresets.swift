#if DEBUG || GR_TURING_DIAGNOSTICS
import Foundation

struct TuringNativeQwenVoiceDesignCanaryInput: Sendable {
    let voiceID: String
    let language: String
    let spokenText: String
    let instruction: String

    var estimatedCombinedTokens: Int {
        max(1, (spokenText + "\n" + instruction).utf16.count / 4)
    }
}

enum TuringNativeQwenVoiceDesignCanaryPreset: String, CaseIterable, Identifiable, Sendable {
    case rowBudgetProbe1
    case rowBudgetProbe2
    case rowBudgetProbe4
    case rowBudgetProbe8
    case rowBudgetProbe16
    case rowBudgetProbe24
    case rowBudgetProbe32
    case rowBudgetProbe40
    case fixtureDecode
    case bigMikeShortDynamic
    case bigMikeBroadcastSegment1Dynamic
    case bigMikeBroadcastLongformDynamic

    // Legacy aliases kept for older local audit/debug scripts.
    case sourceTruthHelloWorldFixture
    case bigMikeHello
    case bigMikeBroadcast450

    var id: String { rawValue }

    var isFixtureDecode: Bool {
        switch self {
        case .rowBudgetProbe1,
             .rowBudgetProbe2,
             .rowBudgetProbe4,
             .rowBudgetProbe8,
             .rowBudgetProbe16,
             .rowBudgetProbe24,
             .rowBudgetProbe32,
             .rowBudgetProbe40:
            return false
        case .fixtureDecode,
             .sourceTruthHelloWorldFixture:
            return true
        default:
            return false
        }
    }

    var isLongform: Bool {
        switch self {
        case .rowBudgetProbe1,
             .rowBudgetProbe2,
             .rowBudgetProbe4,
             .rowBudgetProbe8,
             .rowBudgetProbe16,
             .rowBudgetProbe24,
             .rowBudgetProbe32,
             .rowBudgetProbe40:
            return false
        case .bigMikeBroadcastLongformDynamic,
             .bigMikeBroadcast450:
            return true
        default:
            return false
        }
    }

    var maxNewTokens: Int {
        switch self {
        case .rowBudgetProbe1:
            return 1
        case .rowBudgetProbe2:
            return 2
        case .rowBudgetProbe4:
            return 4
        case .rowBudgetProbe8:
            return 8
        case .rowBudgetProbe16:
            return 16
        case .rowBudgetProbe24:
            return 24
        case .rowBudgetProbe32:
            return 32
        case .rowBudgetProbe40:
            return 40
        case .fixtureDecode,
             .sourceTruthHelloWorldFixture:
            return 7
        case .bigMikeShortDynamic,
             .bigMikeHello:
            return 16
        case .bigMikeBroadcastSegment1Dynamic:
            return 40
        case .bigMikeBroadcastLongformDynamic,
             .bigMikeBroadcast450:
            return 20
        }
    }

    var estimatedAudioSeconds: Double {
        Double(maxNewTokens) * 1920.0 / 24_000.0
    }

    var isUsefulSpeechLength: Bool {
        maxNewTokens >= Self.minimumUsefulSpeechRows
    }

    static let secondsPerGeneratedRow = 1920.0 / 24_000.0
    static let minimumUsefulSpeechRows = 38
    static let minimumUsefulSpeechSeconds = Double(minimumUsefulSpeechRows) * secondsPerGeneratedRow

    var segments: [String] {
        switch self {
        case .bigMikeBroadcastLongformDynamic,
             .bigMikeBroadcast450:
            return Self.bigMikeBroadcastRuntimeSegments
        default:
            return [input.spokenText]
        }
    }

    var input: TuringNativeQwenVoiceDesignCanaryInput {
        switch self {
        case .rowBudgetProbe1,
             .rowBudgetProbe2,
             .rowBudgetProbe4,
             .rowBudgetProbe8,
             .rowBudgetProbe16,
             .rowBudgetProbe24,
             .rowBudgetProbe32,
             .rowBudgetProbe40:
            return TuringNativeQwenVoiceDesignCanaryInput(
                voiceID: "big_mike_vd_v1",
                language: "english",
                spokenText: Self.bigMikeHelloText,
                instruction: Self.bigMikeVoiceDNA + "\n\n" + Self.bigMikeHelloPerformance
            )

        case .fixtureDecode,
             .sourceTruthHelloWorldFixture:
            return TuringNativeQwenVoiceDesignCanaryInput(
                voiceID: "big_mike_vd_v1",
                language: "english",
                spokenText: Self.bigMikeBroadcastText,
                instruction: Self.bigMikeVoiceDNA + "\n\n" + Self.bigMikeBroadcastPerformance
            )

        case .bigMikeShortDynamic,
             .bigMikeHello:
            return TuringNativeQwenVoiceDesignCanaryInput(
                voiceID: "big_mike_vd_v1",
                language: "english",
                spokenText: Self.bigMikeHelloText,
                instruction: Self.bigMikeVoiceDNA + "\n\n" + Self.bigMikeHelloPerformance
            )

        case .bigMikeBroadcastSegment1Dynamic:
            return TuringNativeQwenVoiceDesignCanaryInput(
                voiceID: "big_mike_vd_v1",
                language: "english",
                spokenText: Self.bigMikeBroadcastSegment1Text,
                instruction: Self.bigMikeVoiceDNA + "\n\n" + Self.bigMikeBroadcastPerformance
            )

        case .bigMikeBroadcastLongformDynamic,
             .bigMikeBroadcast450:
            return TuringNativeQwenVoiceDesignCanaryInput(
                voiceID: "big_mike_vd_v1",
                language: "english",
                spokenText: Self.bigMikeBroadcastText,
                instruction: Self.bigMikeVoiceDNA + "\n\n" + Self.bigMikeBroadcastPerformance
            )
        }
    }

    private static let bigMikeVoiceDNA = #"""
Voice ID: BIG_MIKE_VD_V1.

Male, mid-forties, Black American. Large grounded presence like a retired college football lineman. Low male pitch 2/7. Vocal weight 6/7. Chest resonance 6/7. Brightness 2/7. Warmth 5/7. Warm gravel 5/7. Slight lived-in rasp 3/7. Breath 4/7: heavy but controlled. Nasality 1/7. Articulation 5/7: clear but casual. Pace 3/7: measured, unhurried, a little lazy. Regional edge 3/7: subtle Baltimore. Energy 3/7: restrained, unimpressed, protective underneath. Streetwise, intelligent, tired, emotionally grounded. Former military, former athlete, security guard. Real neighbor voice, not polished, theatrical, announcer-like, villainous, or cartoonish. Keep this identity.
"""#

    private static let bigMikeHelloPerformance = #"""
Performance:
Casual radio check. Tired, dry, lazy, low voice, warm gravel, not performing, not shouting. Keep BIG_MIKE_VD_V1 stable; change delivery only.
"""#

    private static let bigMikeBroadcastPerformance = #"""
Performance:
Reading to Rich like, “Rich, listen to this shit.” Tired, lazy, unimpressed, a little disgusted by official wording. Protective underneath, not panicked. Low volume, dry delivery, heavy breath, restrained intensity, no shouting. Keep BIG_MIKE_VD_V1 stable; change delivery only.
"""#

    private static let bigMikeHelloText = #"""
Rich, listen to this shit.
"""#

    private static let bigMikeBroadcastSegment1Text = #"""
Rich, listen to this shit. The Gravitas Plague spreads.
"""#

    private static let bigMikeBroadcastText = #"""
Rich, listen to this shit.

THE GRAVITAS PLAGUE SPREADS

Officials are warning residents to stay indoors after new cases of the Gravitas Plague were confirmed across the city.

Doctors say the illness attacks the brain’s fear response. Early victims may seem confused, sleepless, or strangely calm. Later symptoms include cloudy eyes, broken speech, fixation on movement, and sudden violence.

One hospital worker said, “They look awake, but unreachable.”

The infected are not dead. They are living hosts with severe brain damage.

Residents are advised to lock doors, avoid contact with aggressive animals, and report any bite or fluid exposure immediately.

If someone you know appears infected, do not open the door.

If the eyes cloud, isolate.

If speech fails, do not negotiate.
"""#

    private static let bigMikeBroadcastRuntimeSegments = [
        "Rich, listen to this shit. The Gravitas Plague spreads.",
        "Officials are warning residents to stay indoors after new cases were confirmed across the city.",
        "Doctors say the illness attacks the brain’s fear response.",
        "Early victims may seem confused, sleepless, or strangely calm.",
        "Later symptoms include cloudy eyes, broken speech, fixation on movement, and sudden violence.",
        "One hospital worker said, ‘They look awake, but unreachable.’",
        "The infected are not dead. They are living hosts with severe brain damage.",
        "Residents are advised to lock doors, avoid aggressive animals, and report any bite or fluid exposure immediately.",
        "If someone you know appears infected, do not open the door.",
        "If the eyes cloud, isolate. If speech fails, do not negotiate."
    ]
}
#endif
