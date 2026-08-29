import Foundation
import XCTest

@testable import Gravitas_Plague

actor TuringPhase1PresentationRecorder:
    TuringSpokenPresentationEventPublishing
{
    private var recorded: [TuringSpokenPresentationEvent] = []

    func emit(_ event: TuringSpokenPresentationEvent) {
        recorded.append(event)
    }

    func snapshot() -> [TuringSpokenPresentationEvent] {
        recorded
    }
}

@MainActor
private final class TuringPhase1LifecycleRecorder:
    TuringFlowPlaybackLifecycleSink
{
    private(set) var events: [TuringFlowPlaybackLifecycleEvent] = []

    func receivePlaybackLifecycleEvent(
        _ event: TuringFlowPlaybackLifecycleEvent
    ) async {
        events.append(event)
    }
}

private actor TuringPhase1TimestampEndpoint:
    TuringAudioPlaybackEndpoint
{
    let origin: ContinuousClock.Instant
    let pauseInstant: ContinuousClock.Instant
    let resumeInstant: ContinuousClock.Instant

    private let eventHub = TuringAudioEventHub()
    private var activeHandle: TuringAudioPlaybackHandle?
    private var requests: [TuringAudioPlaybackRequest] = []
    private var failNextStartMessage: String?

    init(origin: ContinuousClock.Instant) {
        self.origin = origin
        self.pauseInstant = origin.advanced(by: .seconds(2))
        self.resumeInstant = origin.advanced(by: .seconds(5))
    }

    func play(
        _ request: TuringAudioPlaybackRequest
    ) async throws -> TuringAudioPlaybackHandle {
        requests.append(request)
        if let message = failNextStartMessage {
            failNextStartMessage = nil
            await eventHub.yield(
                .failed(
                    requestID: request.requestID,
                    runID: request.runID,
                    message: message
                )
            )
            throw TuringRuntimeError.invalidConfig(message)
        }

        let handle = TuringAudioPlaybackHandle(
            id: UUID(),
            requestID: request.requestID,
            runID: request.runID,
            route: request.route
        )
        activeHandle = handle
        await eventHub.yield(
            .started(handle: handle, clockOrigin: origin)
        )
        await Task.yield()
        return handle
    }

    func pause(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async throws {
        guard activeHandle == handle else {
            throw TuringRuntimeError.invalidConfig("Stale pause handle.")
        }
        await eventHub.yield(
            .paused(
                handle: handle,
                instant: pauseInstant,
                reason: reason
            )
        )
    }

    func resume(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async throws {
        guard activeHandle == handle else {
            throw TuringRuntimeError.invalidConfig("Stale resume handle.")
        }
        await eventHub.yield(
            .resumed(
                handle: handle,
                instant: resumeInstant,
                reason: reason
            )
        )
    }

    func stop(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async {
        if activeHandle == handle {
            activeHandle = nil
        }
        await eventHub.yield(.cancelled(handle, reason: reason))
    }

    func events() async -> AsyncStream<TuringAudioPlaybackEvent> {
        await eventHub.stream()
    }

    func completeActive(successfully: Bool = true) async {
        guard let activeHandle else { return }
        self.activeHandle = nil
        await eventHub.yield(
            .completed(activeHandle, successfully: successfully)
        )
    }

    func currentHandle() -> TuringAudioPlaybackHandle? {
        activeHandle
    }

    func emitStaleEvents(for handle: TuringAudioPlaybackHandle) async {
        await eventHub.yield(
            .paused(
                handle: handle,
                instant: pauseInstant,
                reason: "stale"
            )
        )
        await eventHub.yield(
            .resumed(
                handle: handle,
                instant: resumeInstant,
                reason: "stale"
            )
        )
        await eventHub.yield(.completed(handle, successfully: true))
        await eventHub.yield(.cancelled(handle, reason: "stale"))
    }

    func failNextStart(_ message: String) {
        failNextStartMessage = message
    }

    func capturedRequests() -> [TuringAudioPlaybackRequest] {
        requests
    }
}

@MainActor
final class TuringStoryPlaybackPhase1LifecycleTests: XCTestCase {
    func testPrimaryStartRaceAndCompletionAreSymmetric() async {
        let fixture = makeFixture(character: .bigMike)
        let sink = TuringPhase1LifecycleRecorder()
        await fixture.coordinator.setPlaybackLifecycleSink(sink)

        await startRun(fixture)
        await fixture.coordinator.expectPrerecordingBeforeGenerated()
        await fixture.coordinator.enqueuePrerecording(
            makeItem(identity: fixture.identity, speaker: .bigMike)
        )
        await settle()

        let globalAfterStart = await fixture.publisher.snapshot()
        let starts = globalAfterStart.compactMap { event -> TuringSpokenPresentationContext? in
            guard case .started(let context) = event else { return nil }
            return context
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.speakerCharacterID, .bigMike)
        XCTAssertEqual(starts.first?.interactionSurface, .walkie)
        XCTAssertEqual(starts.first?.clockOrigin, fixture.origin)
        XCTAssertEqual(
            starts.first?.source,
            .authored(
                prerecordingID: fixture.identity.prerecordingID,
                role: .primaryPrerecording
            )
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .authoredMediaStarted = $0 { return true }
                return false
            }.count,
            1
        )

        await fixture.endpoint.completeActive()
        await fixture.coordinator.qwenComputeAllFinished()
        await fixture.coordinator.waitUntilPlaybackFinished()
        await settle()

        let global = await fixture.publisher.snapshot()
        XCTAssertEqual(
            global.filter {
                if case .authoredItemCompleted = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .authoredMediaCompleted = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testAuthoredBridgePreservesRoleAndLifecycle() async {
        let fixture = makeFixture(character: .bigMike)
        let sink = TuringPhase1LifecycleRecorder()
        await fixture.coordinator.setPlaybackLifecycleSink(sink)
        await startRun(fixture)

        await fixture.coordinator.enqueueAuthoredBridge(
            makeItem(
                identity: fixture.identity,
                speaker: .bigMike,
                role: .authoredBridge
            ),
            beforeGeneratedSegmentIndex: 0
        )
        await settle()
        await fixture.endpoint.completeActive()
        await fixture.coordinator.qwenComputeAllFinished()
        await fixture.coordinator.waitUntilPlaybackFinished()
        await settle()

        let global = await fixture.publisher.snapshot()
        let bridgeSources = global.compactMap { event -> TuringSpokenPresentationSource? in
            guard case .started(let context) = event else { return nil }
            return context.source
        }
        XCTAssertEqual(
            bridgeSources,
            [.authored(prerecordingID: fixture.identity.prerecordingID, role: .authoredBridge)]
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .authoredMediaStarted = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .authoredMediaCompleted = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testPauseResumeUsesEndpointInstantsAndPreservesLocalLifecycle()
        async throws {
        let fixture = makeFixture(character: .bigMike)
        let sink = TuringPhase1LifecycleRecorder()
        await fixture.coordinator.setPlaybackLifecycleSink(sink)
        await startRun(fixture)
        await fixture.coordinator.expectPrerecordingBeforeGenerated()
        await fixture.coordinator.enqueuePrerecording(
            makeItem(
                identity: fixture.identity,
                speaker: .bigMike,
                entry: makeEntry(speaker: .bigMike, target: .rich)
            )
        )
        await settle()

        let receipt = try await fixture.coordinator.pauseCurrentSpokenMedia(
            interruptionID: UUID()
        )
        await settle()
        try await fixture.coordinator.resumeCurrentSpokenMedia(receipt)
        await settle()

        let global = await fixture.publisher.snapshot()
        let pauses = global.compactMap { event -> (
            ContinuousClock.Instant,
            TuringPauseAwarePlaybackClock
        )? in
            guard case .paused(_, let instant, let clock, _) = event else {
                return nil
            }
            return (instant, clock)
        }
        let resumes = global.compactMap { event -> (
            ContinuousClock.Instant,
            TuringPauseAwarePlaybackClock
        )? in
            guard case .resumed(_, let instant, let clock, _) = event else {
                return nil
            }
            return (instant, clock)
        }
        XCTAssertEqual(pauses.count, 1)
        XCTAssertEqual(pauses.first?.0, fixture.origin.advanced(by: .seconds(2)))
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(resumes.first?.0, fixture.origin.advanced(by: .seconds(5)))
        XCTAssertEqual(resumes.first?.1.accumulatedPausedDuration, .seconds(3))
        XCTAssertEqual(
            resumes.first?.1.elapsed(
                at: fixture.origin.advanced(by: .seconds(10))
            ),
            .seconds(7)
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .authoredMediaPaused = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .authoredMediaResumed = $0 { return true }
                return false
            }.count,
            1
        )

        await fixture.endpoint.completeActive()
        await fixture.coordinator.qwenComputeAllFinished()
        await fixture.coordinator.waitUntilPlaybackFinished()
    }

    func testGeneratedSegmentCompletesLocallyAndGloballyThenResponseCompletes()
        async {
        let fixture = makeFixture(character: .bigMike)
        let sink = TuringPhase1LifecycleRecorder()
        await fixture.coordinator.setPlaybackLifecycleSink(sink)
        await startRun(fixture)

        await fixture.coordinator.qwenComputeStarted(segmentIndex: 0)
        await fixture.coordinator.qwenComputeFinished(
            segmentIndex: 0,
            audio: generatedAudio(index: 0)
        )
        await fixture.coordinator.sealGeneratedInput(
            finalExpectedSegmentCount: 1
        )
        await settle()
        await fixture.endpoint.completeActive()
        await fixture.coordinator.waitUntilPlaybackFinished()
        await settle()

        let global = await fixture.publisher.snapshot()
        let generatedStarts = global.compactMap { event -> TuringSpokenPresentationContext? in
            guard case .started(let context) = event,
                  case .generated = context.source else { return nil }
            return context
        }
        XCTAssertEqual(generatedStarts.count, 1)
        XCTAssertEqual(generatedStarts.first?.speakerCharacterID, .bigMike)
        XCTAssertEqual(generatedStarts.first?.interactionSurface, .walkie)
        XCTAssertEqual(
            global.filter {
                if case .generatedSegmentCompleted = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            global.filter {
                if case .responseCompleted = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .generatedSegmentStarted = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .generatedSegmentCompleted = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            sink.events.filter {
                if case .generatedPlaybackCompleted = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testStartFailureAndCancellationAreNotDuplicated() async {
        let failureFixture = makeFixture(character: .bigMike)
        let failureSink = TuringPhase1LifecycleRecorder()
        await failureFixture.coordinator.setPlaybackLifecycleSink(failureSink)
        await startRun(failureFixture)
        await failureFixture.coordinator.expectPrerecordingBeforeGenerated()
        await failureFixture.endpoint.failNextStart("controlled failure")
        await failureFixture.coordinator.enqueuePrerecording(
            makeItem(identity: failureFixture.identity, speaker: .bigMike)
        )
        await settle()

        let failureEvents = await failureFixture.publisher.snapshot()
        XCTAssertEqual(
            failureEvents.filter {
                if case .failed = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            failureSink.events.filter {
                if case .failed = $0 { return true }
                return false
            }.count,
            1
        )

        let cancelFixture = makeFixture(character: .bigMike)
        await startRun(cancelFixture)
        await cancelFixture.coordinator.expectPrerecordingBeforeGenerated()
        await cancelFixture.coordinator.enqueuePrerecording(
            makeItem(identity: cancelFixture.identity, speaker: .bigMike)
        )
        await settle()
        await cancelFixture.coordinator.runCancelled(reason: "controlled cancel")
        await settle()

        let cancellationEvents = await cancelFixture.publisher.snapshot()
        XCTAssertEqual(
            cancellationEvents.filter {
                if case .cancelled = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testFillerStartFailureDoesNotEnterSpokenPresentationStream()
        async throws {
        let origin = ContinuousClock.now
        let endpoint = TuringPhase1TimestampEndpoint(origin: origin)
        let publisher = TuringPhase1PresentationRecorder()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fillerDirectory = rootURL.appendingPathComponent(
            "filler",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fillerDirectory,
            withIntermediateDirectories: true
        )
        try Data([0]).write(
            to: fillerDirectory.appendingPathComponent("filler_1.wav")
        )
        var policy = TuringStoryWalkiePlaybackCoordinator.Policy()
        policy.firstSegmentPrerollFillerCount = 1
        policy.chainFillerFromPrerecordingToFirstGenerated = false
        policy.chainFillerWhileComputeWithoutSpeech = false
        policy.deadAirAfterFillerEnabled = false
        policy.fillerDirectoryCandidates = [fillerDirectory.path]
        let coordinator = TuringStoryWalkiePlaybackCoordinator(
            policy: policy,
            rootURL: rootURL,
            endpoint: endpoint,
            spokenPresentationPublisher: publisher
        )
        let identity = makeIdentity(character: .bigMike)
        await coordinator.configureFlowIdentity(identity)
        await coordinator.beginRun(
            runID: identity.playbackRunID,
            expectedSegmentCount: 1
        )
        await endpoint.failNextStart("controlled filler failure")
        await coordinator.qwenComputeStarted(segmentIndex: 0)
        await coordinator.qwenComputeFinished(
            segmentIndex: 0,
            audio: generatedAudio(index: 0)
        )
        await settle()

        let events = await publisher.snapshot()
        XCTAssertTrue(events.isEmpty)
        await coordinator.runCancelled(reason: "test complete")
    }

    func testConversationVoiceUsesGeneratedTargetWithoutAuthoredLeak()
        async {
        let fixture = makeFixture(character: .catEye81)
        await startRun(fixture)
        await fixture.coordinator.expectPrerecordingBeforeGenerated()
        await fixture.coordinator.enqueuePrerecording(
            makeItem(identity: fixture.identity, speaker: .rich)
        )
        await settle()
        await fixture.endpoint.completeActive()
        await fixture.coordinator.qwenComputeStarted(segmentIndex: 0)
        await fixture.coordinator.qwenComputeFinished(
            segmentIndex: 0,
            audio: generatedAudio(index: 0)
        )
        await fixture.coordinator.sealGeneratedInput(
            finalExpectedSegmentCount: 1
        )
        await settle()
        await fixture.endpoint.completeActive()
        await fixture.coordinator.waitUntilPlaybackFinished()
        await settle()

        let speakers = (await fixture.publisher.snapshot()).compactMap {
            event -> TuringConversationCharacterID? in
            guard case .started(let context) = event else { return nil }
            return context.speakerCharacterID
        }
        XCTAssertEqual(speakers, [.rich, .catEye81])
    }

    func testSpeakerMismatchSuppressesPresentationButAudioStillCompletes() async {
        let fixture = makeFixture(character: .rich)
        let sink = TuringPhase1LifecycleRecorder()
        await fixture.coordinator.setPlaybackLifecycleSink(sink)
        await startRun(fixture)
        await fixture.coordinator.expectPrerecordingBeforeGenerated()
        await fixture.coordinator.enqueuePrerecording(
            makeItem(
                identity: fixture.identity,
                speaker: .rich,
                entry: makeEntry(speaker: .bigMike, target: .rich)
            )
        )
        await settle()
        await fixture.endpoint.completeActive()
        await fixture.coordinator.qwenComputeAllFinished()
        await fixture.coordinator.waitUntilPlaybackFinished()
        await settle()

        let presentationEvents = await fixture.publisher.snapshot()
        XCTAssertTrue(presentationEvents.isEmpty)
        XCTAssertEqual(
            sink.events.filter {
                if case .authoredMediaCompleted = $0 { return true }
                return false
            }.count,
            1
        )
        let requests = await fixture.endpoint.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testStaleEventsCannotMutateReplacementPresentation() async {
        let first = makeFixture(character: .bigMike)
        await startRun(first)
        await first.coordinator.expectPrerecordingBeforeGenerated()
        await first.coordinator.enqueuePrerecording(
            makeItem(identity: first.identity, speaker: .bigMike)
        )
        await settle()
        guard let staleHandle = await first.endpoint.currentHandle() else {
            return XCTFail("Expected first handle.")
        }
        await first.coordinator.runCancelled(reason: "replace")

        let replacementIdentity = makeIdentity(
            character: .bigMike,
            runID: "phase1.replacement.run"
        )
        await first.coordinator.configureFlowIdentity(replacementIdentity)
        await first.coordinator.beginRun(
            runID: replacementIdentity.playbackRunID,
            expectedSegmentCount: 0
        )
        await first.coordinator.expectPrerecordingBeforeGenerated()
        await first.coordinator.enqueuePrerecording(
            makeItem(identity: replacementIdentity, speaker: .bigMike)
        )
        await settle()
        let replacementHandle = await first.endpoint.currentHandle()
        await first.endpoint.emitStaleEvents(for: staleHandle)
        await settle()

        let activeHandle = await first.endpoint.currentHandle()
        XCTAssertEqual(activeHandle, replacementHandle)
        let starts = (await first.publisher.snapshot()).filter {
            if case .started = $0 { return true }
            return false
        }
        XCTAssertEqual(starts.count, 2)

        await first.endpoint.completeActive()
        await first.coordinator.qwenComputeAllFinished()
        await first.coordinator.waitUntilPlaybackFinished()
    }

    private typealias Fixture = (
        coordinator: TuringStoryWalkiePlaybackCoordinator,
        endpoint: TuringPhase1TimestampEndpoint,
        publisher: TuringPhase1PresentationRecorder,
        identity: TuringFlowIdentity,
        origin: ContinuousClock.Instant
    )

    private func makeFixture(
        character: TuringConversationCharacterID
    ) -> Fixture {
        let origin = ContinuousClock.now
        let endpoint = TuringPhase1TimestampEndpoint(origin: origin)
        let publisher = TuringPhase1PresentationRecorder()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var policy = TuringStoryWalkiePlaybackCoordinator.Policy()
        policy.firstSegmentPrerollFillerCount = 0
        policy.chainFillerFromPrerecordingToFirstGenerated = false
        policy.chainFillerWhileComputeWithoutSpeech = false
        policy.deadAirAfterFillerEnabled = false
        policy.fillerDirectoryCandidates = []
        let coordinator = TuringStoryWalkiePlaybackCoordinator(
            policy: policy,
            rootURL: rootURL,
            endpoint: endpoint,
            spokenPresentationPublisher: publisher
        )
        return (
            coordinator,
            endpoint,
            publisher,
            makeIdentity(character: character),
            origin
        )
    }

    private func startRun(_ fixture: Fixture) async {
        await fixture.coordinator.configureFlowIdentity(fixture.identity)
        await fixture.coordinator.beginRun(
            runID: fixture.identity.playbackRunID,
            expectedSegmentCount: 0
        )
    }

    private func makeIdentity(
        character: TuringConversationCharacterID,
        runID: String? = nil
    ) -> TuringFlowIdentity {
        TuringFlowIdentity(
            scriptPointID: "phase1.test.scriptPoint",
            characterID: character.rawValue,
            prerecordingID: "phase1.test.pr",
            voicePromptID: "phase1.test.prompt",
            interactionSurface: .walkie,
            playbackRunID: runID ?? "phase1.test.run.\(UUID().uuidString)"
        )
    }

    private func makeItem(
        identity: TuringFlowIdentity,
        speaker: TuringConversationCharacterID,
        role: TuringAuthoredMediaItem.Role = .primaryPrerecording,
        entry: TuringLiveConversationCatalog.Entry? = nil
    ) -> TuringAuthoredMediaItem {
        TuringAuthoredMediaItem(
            scriptPointID: identity.scriptPointID,
            id: identity.prerecordingID,
            role: role,
            fileURL: URL(fileURLWithPath: "/tmp/phase1-test-pr.wav"),
            speakerCharacterID: speaker.rawValue,
            liveConversationCatalogEntry: entry
        )
    }

    private func makeEntry(
        speaker: TuringConversationCharacterID,
        target: TuringConversationCharacterID
    ) -> TuringLiveConversationCatalog.Entry {
        TuringLiveConversationCatalog.Entry(
            momentID: "phase1.test.moment",
            segmentID: "phase1.test.segment",
            narrativeOrdinal: 0,
            scriptPointID: "phase1.test.scriptPoint",
            authoredPrerecordingID: "phase1.test.pr",
            voicePromptSource: .init(
                kind: .transmission,
                stageID: nil,
                voicePromptID: "phase1.test.prompt"
            ),
            interactionSurface: .walkie,
            speakerCharacterID: speaker,
            conversationTargetCharacterID: target,
            retention: .currentAuthoredItem
        )
    }

    private func generatedAudio(
        index: Int
    ) -> TuringComputeGapGeneratedAudio {
        TuringComputeGapGeneratedAudio(
            segmentIndex: index,
            samples: Array(repeating: 0.01, count: 480),
            sampleRate: 24_000,
            channelCount: 1
        )
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
