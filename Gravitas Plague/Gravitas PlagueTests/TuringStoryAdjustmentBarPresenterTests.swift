import RealityKit
import XCTest
import simd

@testable import Gravitas_Plague

@MainActor
final class TuringStoryAdjustmentBarPresenterTests: XCTestCase {
    func testCreatesExactlyFourBarsAfterFourPropCommit() {
        let setup = makePresenterSetup()
        setup.presenter.show(activeSlots: setup.activeSlots)

        XCTAssertEqual(setup.presenter.installedBarCount, 4)
    }

    func testEachBarHasCorrectComponentAndOversizedCollisionTarget() {
        let setup = makePresenterSetup()
        setup.presenter.show(activeSlots: setup.activeSlots)

        for propID in TuringStoryPropID.allCases {
            guard let entity = setup.presenter.barEntity(for: propID),
                let component = entity.components[
                    TuringStoryPlacementAdjustmentBarComponent.self
                ],
                let visible = setup.presenter.visibleSize(for: propID),
                let collision = setup.presenter.collisionSize(for: propID)
            else {
                XCTFail("Missing bar for \(propID.rawValue)")
                continue
            }
            XCTAssertEqual(component.propID, propID)
            XCTAssertNotNil(entity.components[InputTargetComponent.self])
            XCTAssertNotNil(entity.components[CollisionComponent.self])
            XCTAssertGreaterThan(collision.y, visible.y)
            XCTAssertGreaterThan(collision.z, visible.z)
        }
    }

    func testBarsUseSwiftUIGlassAttachments() {
        let setup = makePresenterSetup()
        setup.presenter.show(activeSlots: setup.activeSlots)
        setup.presenter.setVisualState(.pinched, propID: .window)

        guard let visual = setup.presenter.visualEntity(for: .window),
            visual.components[ViewAttachmentComponent.self] != nil
        else {
            return XCTFail("Missing SwiftUI glass attachment")
        }
        XCTAssertEqual(
            setup.presenter.visualState(for: .window),
            .pinched
        )
    }

    func testDoorBarIsSixInchesBelowFloor() {
        let setup = makePresenterSetup(floorWorldY: 0.40)
        setup.presenter.show(activeSlots: setup.activeSlots)

        guard let door = setup.presenter.barEntity(for: .door) else {
            return XCTFail("Missing door bar")
        }
        let y = door.transformMatrix(relativeTo: nil).columns.3.y
        XCTAssertEqual(
            y,
            0.40 - TuringStoryAdjustmentBarPoseResolver.doorCenterBelowFloor,
            accuracy: 0.0001
        )
    }

    func testWindowBarUsesHalfOriginalGap() {
        XCTAssertEqual(
            TuringStoryAdjustmentBarPoseResolver.windowBelowVisualOffset,
            0.030,
            accuracy: 0.0001
        )
    }

    func testPosterBarSitsBelowStickerRow() {
        let setup = makePresenterSetup()
        setup.presenter.show(activeSlots: setup.activeSlots)

        guard let poster = setup.presenter.barEntity(for: .poster),
              let slot = setup.activeSlots[.poster],
              case .poster(let placement) = slot.placement else {
            return XCTFail("Missing poster bar")
        }
        let y = poster.transformMatrix(relativeTo: nil).columns.3.y
        let stickerSize = min(
            WallStickerStyle.stickerSizeMeters,
            placement.height * 0.105
        )
        let stickerBottomY = 1.2 + placement.localY
            - placement.height * 0.5 - stickerSize * 1.40
        XCTAssertLessThan(
            y,
            stickerBottomY - 0.039
        )
    }

    func testProductionDragAxisReversesAuthoredWallRight() {
        let setup = makePresenterSetup()
        setup.presenter.show(activeSlots: setup.activeSlots)

        XCTAssertEqual(
            setup.presenter.worldRightAxis(for: .window).x,
            -1,
            accuracy: 0.0001
        )
    }

    func testBarTransformFollowsPreviewedPropWallBasis() {
        let provider = TuringStoryPlacementFakeWallProvider()
        let firstWall = UUID()
        let secondWall = UUID()
        provider.walls[firstWall] = TuringStoryAdjustmentWallBasis(
            wallID: firstWall,
            center: SIMD3<Float>(0, 1, 0),
            right: SIMD3<Float>(1, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            normal: SIMD3<Float>(0, 0, 1),
            floorWorldY: 0
        )
        provider.walls[secondWall] = TuringStoryAdjustmentWallBasis(
            wallID: secondWall,
            center: SIMD3<Float>(2, 1, 0),
            right: SIMD3<Float>(0, 0, -1),
            up: SIMD3<Float>(0, 1, 0),
            normal: SIMD3<Float>(1, 0, 0),
            floorWorldY: 0
        )
        let presenter = TuringStoryPlacementAdjustmentBarPresenter(
            wallProvider: provider
        )
        presenter.install(sceneRoot: Entity())
        let initial = TuringStoryPlacementTestFactory.slot(
            id: "p:initial",
            propID: .poster,
            wallID: firstWall,
            wallOrdinal: 1,
            routeOrder: 1.1
        )
        let preview = TuringStoryPlacementTestFactory.slot(
            id: "p:preview",
            propID: .poster,
            wallID: secondWall,
            wallOrdinal: 2,
            routeOrder: 2.1
        )
        presenter.show(activeSlots: [.poster: initial])

        presenter.preview(slot: preview, duration: 0)

        guard let bar = presenter.barEntity(for: .poster) else {
            return XCTFail("Missing poster bar")
        }
        let matrix = bar.transformMatrix(relativeTo: nil)
        let right = SIMD3<Float>(
            matrix.columns.0.x,
            matrix.columns.0.y,
            matrix.columns.0.z
        )
        XCTAssertLessThan(
            simd_length(right - SIMD3<Float>(0, 0, -1)),
            0.0001
        )
    }

    private struct PresenterSetup {
        let presenter: TuringStoryPlacementAdjustmentBarPresenter
        let provider: TuringStoryPlacementFakeWallProvider
        let activeSlots: [TuringStoryPropID: TuringStoryRuntimeSlot]
    }

    private func makePresenterSetup(
        floorWorldY: Float = 0
    ) -> PresenterSetup {
        let provider = TuringStoryPlacementFakeWallProvider()
        var active: [TuringStoryPropID: TuringStoryRuntimeSlot] = [:]

        for (offset, propID) in TuringStoryPropID.allCases.enumerated() {
            let wallID = UUID()
            provider.walls[wallID] = TuringStoryAdjustmentWallBasis(
                wallID: wallID,
                center: SIMD3<Float>(Float(offset) * 2, 1.2, 0),
                right: SIMD3<Float>(1, 0, 0),
                up: SIMD3<Float>(0, 1, 0),
                normal: SIMD3<Float>(0, 0, 1),
                floorWorldY: floorWorldY
            )
            active[propID] = TuringStoryPlacementTestFactory.slot(
                id: "\(propID.shortID):0",
                propID: propID,
                wallID: wallID,
                wallOrdinal: offset + 1,
                routeOrder: Float(offset + 1) + 0.1,
                localX: 0,
                localY: 1.2,
                width: propID == .door ? 0.95 : 0.65,
                height: propID == .door ? 2.05 : 0.60,
                floorWorldY: floorWorldY
            )
        }

        let presenter = TuringStoryPlacementAdjustmentBarPresenter(
            wallProvider: provider
        )
        presenter.install(sceneRoot: Entity())
        return PresenterSetup(
            presenter: presenter,
            provider: provider,
            activeSlots: active
        )
    }
}
