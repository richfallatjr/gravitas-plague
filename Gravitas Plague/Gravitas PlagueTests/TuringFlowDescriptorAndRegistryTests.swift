import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringFlowDescriptorAndRegistryTests:
    XCTestCase {

    func testOutputRouteDecodesUnknownFutureRoute()
        throws {
        let data = Data(
            #""story.rich.dadFrameGlobal""#
                .utf8
        )
        let route = try JSONDecoder()
            .decode(
                TuringVoiceOutputContext.self,
                from: data
            )

        XCTAssertEqual(
            route.rawValue,
            "story.rich.dadFrameGlobal"
        )
    }

    func testThirdCharacterRequiresNoSwitchCase()
        throws {
        let route =
            TuringVoiceOutputContext(
                rawValue:
                    "story.fixture.radio"
            )
        let fixture =
            TuringFlowTestFixtures.character(
                id: "third_character",
                voiceID:
                    "third_character_clone_v1",
                outputRoute: route
            )
        let registry =
            try TuringCharacterRuntimeRegistry(
                definitions: [
                    fixture
                ]
            )

        let loaded =
            try registry.require(
                "third_character"
            )

        XCTAssertEqual(
            loaded.voiceID,
            "third_character_clone_v1"
        )
        XCTAssertTrue(
            loaded.supports(route)
        )
    }

    func testDescriptorRoundTripRetainsGenericPointData()
        throws {
        let route =
            TuringVoiceOutputContext(
                rawValue:
                    "story.rich.toolBench"
            )
        let descriptor =
            TuringFlowTestFixtures.descriptor(
                id:
                    "episode07.scriptPoint146",
                prerecordingID:
                    "episode07.rich.toolBench.146",
                voicePromptID:
                    "episode07.rich.toolBench.followUp.146",
                characterID: "rich",
                outputRoute: route,
                conversationKey:
                    "episode07.toolBench",
                open: false,
                send: false,
                fixedLeadIn: nil,
                gate: .play
            )

        let data = try JSONEncoder()
            .encode(descriptor)
        let decoded = try JSONDecoder()
            .decode(
                TuringFlowDescriptor.self,
                from: data
            )

        XCTAssertEqual(
            decoded.scriptPointID,
            "episode07.scriptPoint146"
        )
        XCTAssertEqual(
            decoded.transmission
                .outputRoute,
            route
        )
        XCTAssertEqual(
            decoded.progression
                .interactionGateAfterCompletion,
            .play
        )
    }

    func testCharacterProcessingRatesAreIndependent()
        throws {
        let bigMike =
            TuringFlowTestFixtures.character(
                id: "big_mike",
                voiceID:
                    "big_mike_base_clone_v1",
                outputRoute:
                    .walkieSpatial
            )
        let baseRich =
            TuringFlowTestFixtures.character(
                id: "rich",
                voiceID:
                    "rich_base_clone_v1",
                outputRoute:
                    .roomGlobal
            )

        let rich =
            TuringCharacterRuntimeDefinition(
                characterID:
                    baseRich.characterID,
                displayName:
                    baseRich.displayName,
                voiceID:
                    baseRich.voiceID,
                cloneProfileResourcePath:
                    baseRich
                        .cloneProfileResourcePath,
                allowedOutputRoutes:
                    baseRich
                        .allowedOutputRoutes,
                outputProcessing: .init(
                    playbackRate: 0.92
                ),
                qwen: baseRich.qwen,
                audio: baseRich.audio
            )

        XCTAssertEqual(
            bigMike.outputProcessing
                .playbackRate,
            0.85,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            rich.outputProcessing
                .playbackRate,
            0.92,
            accuracy: 0.0001
        )
    }
}
