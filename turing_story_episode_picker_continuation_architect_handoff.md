# Story Episode Picker and Robust Continuation - Architect Handoff

Status: architecture and implementation handoff. Do not treat this as permission to rewrite Turing Flow, TTS, playback, room placement, Battle01, or prompt design.

Repository:

```text
/Users/richardfallat/Projects/dev/gravitas-plague
```

## Objective

Phase the current Story debug window out of the production path.

Pressing **Story Mode** from either:

```text
SwiftUI operation-mode poster
RealityKit wall poster
```

must open one production SwiftUI episode picker. It must not immediately reset or start the Prologue.

The production picker contains:

```text
Continue

Prologue
They are not human—they are monsters

Episode 1
TBD / locked until authored
```

The picker must use an extensible strip-row system so additional episodes can be added through catalog data rather than another custom view.

Continuation must persist authored logical checkpoints in app storage. Continue reconstructs the last committed logical state after the current physical room has been scanned and the Story props have been placed. It must not serialize RealityKit entities, audio controllers, Tasks, Foundation sessions, Qwen state, or room transforms.

## Non-Negotiable Boundaries

This work must not change:

```text
Qwen generation or Fresh2 scheduling
Big Mike or Rich clone profiles
TTS playback ownership
filler/static cadence
walkie spatial routes
room-scan or wall-placement algorithms
door/window/rolling-bench behavior
Battle01 animation or combat behavior
Foundation fresh-session enforcement
voicePrompt/conversationPrompt input contracts
```

The checkpoint snapshot is application state, not dialogue context. It must never be inserted into a Foundation prompt.

## Current Repository Facts

### Existing episode window

The current window is diagnostic-heavy:

```swift
// Gravitas Plague/Gravitas Plague/GravitasPlagueApp.swift
WindowGroup(id: PlagueWindowID.storyDebug) {
    TuringEpisodePickerView(session: demoSession)
        .frame(minWidth: 520)
}
.defaultSize(width: 560, height: 760)
.windowResizability(.contentSize)
.defaultLaunchBehavior(.suppressed)
.restorationBehavior(.disabled)
```

`TuringEpisodePickerView` currently mixes episode rows with room-scan, Qwen, prerecording, ScriptPoint02, and dictation diagnostics. Do not evolve that mixed surface into the production picker.

Create a production view and retain the existing diagnostics behind debug compilation:

```text
TuringStoryEpisodePickerView      production
TuringEpisodePickerView           existing diagnostics, DEBUG only
```

### Story currently starts too early

`PlagueDemoSession.selectOperationMode(.story)` currently resets flow state and starts the default Prologue immediately:

```swift
case .story:
    experienceMode = .story
    activeMode = .none
    statusMessage = "Starting the Prologue."
    isStoryEpisodePickerPresented = false
    let episodeID = PlagueFeatureFlags.defaultStoryEpisodeID

    Task { @MainActor [weak self] in
        await TuringEpisodeFlowController.shared.resetEpisode(
            reason: "storyModeSelected.\(episodeID.rawValue)"
        )
        guard let self,
              self.selectedOperationMode == .story else { return }
        self.startStoryEpisode(episodeID)
    }
```

Replace that behavior. Selecting Story Mode must only select Story as the operation mode and request presentation of the production episode picker. Starting or continuing an episode happens only after the user chooses a picker action.

### SwiftUI and RealityKit already converge

The RealityKit poster calls:

```swift
func handleWallPosterAction(_ action: WallPosterAction) {
    switch action {
    case .story:
        selectOperationMode(.story)
    case .horde:
        selectOperationMode(.horde)
    }
}
```

The SwiftUI poster also calls `selectOperationMode`. Preserve this convergence. Add one picker-presentation request emitted by `PlagueDemoSession`; do not add separate SwiftUI and RealityKit episode launchers.

### Existing SwiftUI device-button strip style

Reuse the existing in-repo device-control appearance from `PlagueRoomSkinningTopOrnament`. This is the required visual starting point for the episode strips:

```swift
HStack(spacing: 10) {
    Button {
        performAction()
    } label: {
        Image(systemName: "play.fill")
            .font(.system(size: 23, weight: .semibold))
            .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .help("Continue")
    .accessibilityLabel("Continue")
}
.padding(.horizontal, 14)
.padding(.vertical, 8)
.glassBackgroundEffect()
```

Do not invent a card visual language. Episode choices are full-width glass strips using the same plain 44-point device buttons, icon weight, padding, hover behavior, and native glass treatment.

## Production Window Contract

Add IDs without reusing the debug identifier:

```swift
enum PlagueWindowID {
    static let control = "plague-control"
    static let storyEpisodes = "plague-story-episodes"
    static let storyDebug = "plague-story-debug"
    static let leaderboards = "plague-leaderboards"
}
```

Add the production window:

```swift
WindowGroup(id: PlagueWindowID.storyEpisodes) {
    TuringStoryEpisodePickerView(session: demoSession)
        .frame(minWidth: 560, minHeight: 420)
}
.defaultSize(width: 620, height: 560)
.windowResizability(.contentSize)
.defaultLaunchBehavior(.suppressed)
.restorationBehavior(.disabled)
```

Keep diagnostics separately:

```swift
#if DEBUG || GR_TURING_DIAGNOSTICS
WindowGroup(id: PlagueWindowID.storyDebug) {
    TuringEpisodePickerView(session: demoSession)
        .frame(minWidth: 520)
}
#endif
```

## One Presentation Owner

RealityKit code cannot access SwiftUI's `OpenWindowAction`. `PlagueDemoSession` should publish a monotonically increasing presentation request. The root SwiftUI scene observes it and invokes `openWindow`.

```swift
@MainActor
final class PlagueDemoSession: ObservableObject {
    @Published private(set) var storyEpisodePickerRequestRevision = 0

    func requestStoryEpisodePicker(source: String) {
        selectedOperationMode = .story
        experienceMode = .story
        activeMode = .none
        storyEpisodePickerRequestRevision &+= 1

        print("""
        [TuringEpisodePicker] presentation requested
          source: \(source)
          revision: \(storyEpisodePickerRequestRevision)
        """)
    }
}
```

The SwiftUI root owns the environment action:

```swift
struct PlagueOperationModePosterRoot: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .onChange(of: session.storyEpisodePickerRequestRevision) {
                _, _ in
                openWindow(id: PlagueWindowID.storyEpisodes)
            }
    }
}
```

Both Story inputs call the same method:

```swift
// SwiftUI operation-mode action
session.requestStoryEpisodePicker(source: "swiftUIOperationPoster")

// RealityKit wall-poster action
session.requestStoryEpisodePicker(source: "realityKitWallPoster")
```

Do not open the immersive space or reset Turing Flow merely because the picker appeared.

## Extensible Episode Catalog

Extend the catalog rather than hardcoding rows in the view:

```swift
enum TuringEpisodeID: String, Codable, CaseIterable, Identifiable, Sendable {
    case prologue
    case episode01

    nonisolated var id: String { rawValue }
}

struct TuringEpisodeDescriptor: Identifiable, Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case unlocked
        case locked(reason: String)
        case comingSoon
    }

    let id: TuringEpisodeID
    let title: String
    let subtitle: String
    let scriptResourcePath: String?
    let availability: Availability
}

enum TuringEpisodeCatalog {
    static let productionEpisodes: [TuringEpisodeDescriptor] = [
        .init(
            id: .prologue,
            title: "Prologue",
            subtitle: "They are not human—they are monsters",
            scriptResourcePath: "Turing/Scripts/Prologue/prologue.json",
            availability: .unlocked
        ),
        .init(
            id: .episode01,
            title: "Episode 1",
            subtitle: "TBD",
            scriptResourcePath: nil,
            availability: .comingSoon
        )
    ]
}
```

## Persisted Progress Model

Persistence must be a versioned, monotonic snapshot stored as one JSON value. A single value prevents partially updated checkpoint fields.

```swift
import Foundation

enum TuringPrologueCheckpoint: Int, Codable, Sendable, Comparable {
    case notStarted = 0
    case script01PromptVoiceCompleted = 10
    case script01ConversationVoiceCompleted = 20
    case script02PromptVoiceCompleted = 30
    case script03PromptVoiceCompleted = 40

    static func < (
        lhs: TuringPrologueCheckpoint,
        rhs: TuringPrologueCheckpoint
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TuringEpisodeContinuationSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let episodeID: TuringEpisodeID
    let checkpoint: TuringPrologueCheckpoint
    let revision: Int
    let committedAt: Date
    let sourceEventID: UUID

    // Invalidates or migrates saves if authored checkpoint semantics change.
    let contentRevision: String
}
```

Do not store generated Foundation text, player dictation, conversation history, Qwen audio, or prompt payloads in this snapshot.

### App-storage implementation

Use one base64-encoded JSON string because `@AppStorage` has a reliable String representation and `UserDefaults` writes it atomically as one value.

```swift
import Combine
import Foundation

@MainActor
final class TuringStoryProgressStore: ObservableObject {
    static let shared = TuringStoryProgressStore()

    enum Key {
        static let snapshot =
            "turing.story.continuation.snapshot.v1"
    }

    @Published private(set) var snapshot:
        TuringEpisodeContinuationSnapshot?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshot = Self.load(
            defaults: defaults,
            decoder: decoder
        )
    }

    var canContinue: Bool {
        snapshot?.checkpoint != .notStarted
    }

    @discardableResult
    func commit(
        episodeID: TuringEpisodeID,
        checkpoint: TuringPrologueCheckpoint,
        sourceEventID: UUID,
        contentRevision: String
    ) throws -> TuringEpisodeContinuationSnapshot {
        if let current = snapshot,
           current.episodeID == episodeID,
           checkpoint < current.checkpoint {
            print("""
            [TuringContinuation] regressive checkpoint ignored
              current: \(current.checkpoint)
              requested: \(checkpoint)
            """)
            return current
        }

        if let current = snapshot,
           current.sourceEventID == sourceEventID {
            return current
        }

        let next = TuringEpisodeContinuationSnapshot(
            schemaVersion:
                TuringEpisodeContinuationSnapshot.currentSchemaVersion,
            episodeID: episodeID,
            checkpoint: checkpoint,
            revision: (snapshot?.revision ?? 0) + 1,
            committedAt: Date(),
            sourceEventID: sourceEventID,
            contentRevision: contentRevision
        )

        let data = try encoder.encode(next)
        defaults.set(
            data.base64EncodedString(),
            forKey: Key.snapshot
        )
        snapshot = next

        print("""
        [TuringContinuation] checkpoint committed
          episodeID: \(episodeID.rawValue)
          checkpoint: \(checkpoint)
          revision: \(next.revision)
          sourceEventID: \(sourceEventID.uuidString)
        """)
        return next
    }

    func clear(reason: String) {
        defaults.removeObject(forKey: Key.snapshot)
        snapshot = nil
        print("[TuringContinuation] cleared reason=\(reason)")
    }

    private static func load(
        defaults: UserDefaults,
        decoder: JSONDecoder
    ) -> TuringEpisodeContinuationSnapshot? {
        guard let encoded = defaults.string(forKey: Key.snapshot),
              let data = Data(base64Encoded: encoded),
              let value = try? decoder.decode(
                TuringEpisodeContinuationSnapshot.self,
                from: data
              ),
              value.schemaVersion ==
                TuringEpisodeContinuationSnapshot.currentSchemaVersion else {
            return nil
        }
        return value
    }
}
```

The production picker observes `TuringStoryProgressStore.shared`. It may additionally use `@AppStorage(TuringStoryProgressStore.Key.snapshot)` as a String solely to receive cross-scene refreshes, but the typed store remains the only decoder/writer.

## Exact Checkpoint Semantics

### Checkpoint 1

```text
Event:
ScriptPoint01 promptVoice has completed actual generated playback.

Persist:
script01PromptVoiceCompleted

Live state:
microphone icon present

Continue restore:
mark ScriptPoint01 completed
restore ScriptPoint01 authored PR transcript for conversationPrompt
restore pending conversation -> ScriptPoint02 progression
set walkie gate to microphone
show microphone icon
```

Do not checkpoint when Foundation returns, when Qwen finishes, when segment zero becomes ready, or when playback starts.

### Checkpoint 2

```text
Event:
ScriptPoint01 conversationVoice has completed actual generated playback.

Persist:
script01ConversationVoiceCompleted

Live uninterrupted state:
current authored progression may continue to ScriptPoint02

Continue restore:
mark ScriptPoint01 completed
set pending walkie play action to ScriptPoint02
set gate to play
show play icon
play tap starts ScriptPoint02
```

The checkpoint write must complete before ScriptPoint02 is launched. If the process exits between those operations, Continue lands on the ScriptPoint02 play icon.

### Checkpoint 3

```text
Event:
ScriptPoint02 promptVoice has completed actual generated playback.

Persist:
script02PromptVoiceCompleted

Live uninterrupted state:
current authored automatic progression may continue to ScriptPoint03

Continue restore:
mark ScriptPoint01 and ScriptPoint02 completed
set pending walkie play action to ScriptPoint03
set gate to play
show play icon
play tap starts ScriptPoint03
```

The checkpoint write must complete before the automatic ScriptPoint03 launch.

### Checkpoint 4

```text
Event:
ScriptPoint03 promptVoice has completed actual generated playback.

Persist:
script03PromptVoiceCompleted

Live state:
microphone icon present
Battle01 animation starts inside the portal

Continue restore:
mark ScriptPoint01, ScriptPoint02, and ScriptPoint03 completed
set gate to microphone
show microphone icon
start Battle01 inside the portal as soon as Story world readiness is satisfied
do not replay ScriptPoint03 PR or promptVoice
```

Until a later Battle01 checkpoint is authored, exiting during Battle01 resumes from the start of Battle01.

## Completion Event Ownership

The current `TuringEpisodeFlowController` supports only one completion sink:

```swift
private var completionEventSink:
    (any TuringScriptPointCompletionEventSink)?
```

`PlagueImmersiveCoordinator` currently installs `PrologueStoryActionRouter` directly. Continuation also needs these events. Do not let one feature replace the other sink.

Use one ordered Prologue completion coordinator:

```swift
@MainActor
final class TuringPrologueCompletionCoordinator:
    TuringScriptPointCompletionEventSink
{
    private let progress: TuringStoryProgressStore
    private let battleRouter: PrologueStoryActionRouter
    private var handledEventIDs = Set<UUID>()

    init(
        progress: TuringStoryProgressStore = .shared,
        battleRouter: PrologueStoryActionRouter
    ) {
        self.progress = progress
        self.battleRouter = battleRouter
    }

    func scriptPointCompleted(
        _ event: TuringScriptPointCompletionEvent
    ) {
        guard handledEventIDs.insert(event.eventID).inserted else {
            return
        }

        do {
            switch event.scriptPointID {
            case "prologue.scriptPoint01":
                try progress.commit(
                    episodeID: .prologue,
                    checkpoint: .script01PromptVoiceCompleted,
                    sourceEventID: event.eventID,
                    contentRevision: "prologue.v1"
                )

            case "prologue.scriptPoint02":
                try progress.commit(
                    episodeID: .prologue,
                    checkpoint: .script02PromptVoiceCompleted,
                    sourceEventID: event.eventID,
                    contentRevision: "prologue.v1"
                )

            case "prologue.scriptPoint03":
                // Persistence first. Battle trigger second.
                try progress.commit(
                    episodeID: .prologue,
                    checkpoint: .script03PromptVoiceCompleted,
                    sourceEventID: event.eventID,
                    contentRevision: "prologue.v1"
                )
                battleRouter.scriptPointCompleted(event)

            default:
                break
            }
        } catch {
            print("""
            [TuringContinuation] checkpoint write failed
              scriptPointID: \(event.scriptPointID)
              error: \(error.localizedDescription)
            """)
        }
    }
}
```

Checkpoint 2 comes from conversation playback, not `TuringScriptPointCompletionEvent`. Add a dedicated actual-conversation-completion event before progression starts:

```swift
struct TuringConversationPlaybackCompletionEvent: Sendable {
    let eventID: UUID
    let conversationRunID: UUID
    let conversationKey: String
    let parentScriptPointID: String
}
```

In `TuringFlowConversationRunner`, emit it only after this existing boundary:

```swift
await playback.waitUntilPlaybackFinished()

guard report.isCompleteSuccess,
      completed == plan.segments.count else {
    // no checkpoint
    ...
}
```

The required ordering is:

```swift
await route.finish(... succeeded: true)

try await continuationCoordinator
    .conversationPlaybackCompleted(
        parentScriptPointID: "prologue.scriptPoint01",
        conversationRunID: conversationRunID,
        conversationKey: request.conversationKey
    )

// Only after the durable checkpoint:
await TuringEpisodeFlowController.shared
    .conversationPlaybackCompleted(
        conversationKey: request.conversationKey
    )
```

Do not infer the parent point from arbitrary dialogue history. `TuringEpisodeFlowController` already owns `pendingConversationAdvance`; expose the parent identifier in the completion result or provide an explicit checkpoint callback from that owner.

## Generic Play Action

The current production walkie hardcodes every play tap to ScriptPoint01:

```swift
let result = await self.episodeFlow.start(
    scriptPointID: "prologue.scriptPoint01",
    trigger: .userPlay
)
```

Resume requires the same play icon to start ScriptPoint02 or ScriptPoint03. Keep presentation in `TuringFlowInteractionGateController`, but add an explicit action payload owned by the walkie interaction controller:

```swift
enum TuringStoryWalkiePlayAction: Sendable, Equatable {
    case startScriptPoint(
        id: String,
        trigger: TuringFlowTriggerSource
    )
}

@MainActor
final class TuringStoryWalkieInteractionController {
    private var pendingPlayAction:
        TuringStoryWalkiePlayAction?

    func armPlay(
        action: TuringStoryWalkiePlayAction,
        reason: String
    ) {
        pendingPlayAction = action
        gate.forcePlayForRestoration(reason: reason)
        renderGateState(reason: reason)
    }

    func playTapped(source: String) {
        guard walkieReady,
              let action = pendingPlayAction,
              gate.claimPlay(reason: source) else { return }

        pendingPlayAction = nil

        switch action {
        case .startScriptPoint(let id, let trigger):
            playStartTask = Task { [weak self] in
                guard let self else { return }
                let result = await episodeFlow.start(
                    scriptPointID: id,
                    trigger: trigger,
                    allowExplicitReplay: true
                )
                if result.succeeded == false {
                    self.pendingPlayAction = action
                    self.gate.restorePlayAfterFailedClaim(
                        reason: "\(id).failed.\(source)"
                    )
                }
            }
        }
    }
}
```

For a new Prologue, arm:

```swift
.startScriptPoint(id: "prologue.scriptPoint01", trigger: .userPlay)
```

For checkpoint 2, arm ScriptPoint02 using a restoration trigger accepted explicitly by the episode controller. Do not lie that a conversation just completed in the new process. Add `.continuationRestore(checkpoint:)` to `TuringFlowTriggerSource` and validate it only through the continuation coordinator.

## Resume Plan

Do not scatter checkpoint switch statements across SwiftUI, the immersive coordinator, and the walkie controller. Use one resolver:

```swift
enum TuringStoryResumeAction: Sendable, Equatable {
    case armPlay(scriptPointID: String)
    case armMicrophone(
        pendingConversationNextScriptPointID: String?
    )
    case startBattle01AndArmMicrophone
}

struct TuringStoryResumePlan: Sendable, Equatable {
    let episodeID: TuringEpisodeID
    let completedScriptPointIDs: Set<String>
    let action: TuringStoryResumeAction
}

enum TuringStoryResumePlanner {
    static func plan(
        for snapshot: TuringEpisodeContinuationSnapshot
    ) throws -> TuringStoryResumePlan {
        switch snapshot.checkpoint {
        case .notStarted:
            return .init(
                episodeID: .prologue,
                completedScriptPointIDs: [],
                action: .armPlay(
                    scriptPointID: "prologue.scriptPoint01"
                )
            )

        case .script01PromptVoiceCompleted:
            return .init(
                episodeID: .prologue,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01"
                ],
                action: .armMicrophone(
                    pendingConversationNextScriptPointID:
                        "prologue.scriptPoint02"
                )
            )

        case .script01ConversationVoiceCompleted:
            return .init(
                episodeID: .prologue,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01"
                ],
                action: .armPlay(
                    scriptPointID: "prologue.scriptPoint02"
                )
            )

        case .script02PromptVoiceCompleted:
            return .init(
                episodeID: .prologue,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01",
                    "prologue.scriptPoint02"
                ],
                action: .armPlay(
                    scriptPointID: "prologue.scriptPoint03"
                )
            )

        case .script03PromptVoiceCompleted:
            return .init(
                episodeID: .prologue,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01",
                    "prologue.scriptPoint02",
                    "prologue.scriptPoint03"
                ],
                action: .startBattle01AndArmMicrophone
            )
        }
    }
}
```

## World Readiness Before Restore

Continue cannot apply walkie state before the walkie and icon anchor exist. The sequence is:

```text
Continue tapped
open immersive space if needed
start selected Story episode shell
run current room scan and current global prop placement unchanged
wait for placement commit and walkie action-target installation
apply TuringStoryResumePlan
dismiss episode picker
```

Add a continuation callback after the existing `walkieInstalled(...)` call in `PlagueImmersiveCoordinator`. Do not poll with sleeps.

```swift
@MainActor
final class TuringStoryWorldReadinessCoordinator {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markReadyAfterPlacementCommit() {
        ready = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilReady() async {
        if ready { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func reset() {
        ready = false
    }
}
```

Room transforms are intentionally not persisted. A room can change between launches; the app must map the current room and then restore episode logic.

## Restoring Conversation Checkpoint 1

The conversation prompt requires the current authored PR transcript. Rehydrate it from the authored descriptor; do not persist or reconstruct it from generated history.

```swift
let script01 = try descriptorStore.require(
    "prologue.scriptPoint01"
)
let prerecording = try prerecordingStore.require(
    script01.transmission.prerecordingID
)

await seedStore.updatePrerecording(
    id: prerecording.prerecordingID,
    transcript: prerecording.transcript,
    for: script01.transmission.conversationKey
)
```

Despite the current type name `TuringConversationSeedStore`, only the authored PR transcript is needed for the original conversationPrompt contract. Do not inject a seed into Foundation.

Add an explicit restore method to the episode controller:

```swift
func restore(
    completedScriptPointIDs: Set<String>,
    pendingConversationAdvance:
        RestoredPendingConversationAdvance?
) async
```

Do not call `resetEpisode` after restoring, because it clears the completed-set and pending progression.

## Production Episode Picker UI

Use one reusable strip for Continue and episode rows:

```swift
import SwiftUI

struct TuringEpisodeActionStrip<Icon: View>: View {
    let title: String
    let subtitle: String?
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 20)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
    }
}
```

Production picker:

```swift
struct TuringStoryEpisodePickerView: View {
    @ObservedObject var session: PlagueDemoSession
    @ObservedObject private var progress =
        TuringStoryProgressStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace)
    private var openImmersiveSpace

    @State private var activeRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Story Mode")
                .font(.title2.weight(.semibold))

            TuringEpisodeActionStrip(
                title: "Continue",
                subtitle: continueSubtitle,
                enabled: progress.canContinue && !activeRequest,
                action: continueStory
            ) {
                Image(systemName: "play.fill")
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(
                        TuringEpisodeCatalog.productionEpisodes
                    ) { episode in
                        TuringEpisodeActionStrip(
                            title: episode.title,
                            subtitle: episode.subtitle,
                            enabled:
                                episode.availability == .unlocked &&
                                !activeRequest,
                            action: {
                                startFromBeginning(episode)
                            }
                        ) {
                            Image(
                                systemName:
                                    episode.availability == .unlocked
                                    ? "play.circle.fill"
                                    : "lock.fill"
                            )
                        }
                    }
                }
            }
        }
        .padding(24)
    }
}
```

Starting Prologue from its row means start from the beginning. If progress exists, request confirmation before clearing it. Continue never clears progress.

## Locked Original Turing Prompt Design

Continuation must not reintroduce ongoing context, dialogue history, seeds, checkpoint JSON, or previous generated turns into Foundation prompts.

### Restoration from the polluted prompt design

The previous implementation had expanded `voicePrompt_characterIntent.txt` with these dynamic inputs:

```text
dialogueHistoryJSON
authoredPrerecordingJSON
intent
voicePromptSeedIntent
emotion
```

That was not the authored Turing design. In particular, it allowed accumulated dialogue state and an additional seed narrative to change later ScriptPoint prompts.

The restored implementation deliberately removed:

```text
{{dialogueHistoryJSON}}
{{authoredPrerecordingJSON}}
{{voicePromptSeedIntent}}
```

and replaced them with the direct, bounded fields:

```text
{{characterProfile}}
{{promptContext}}
{{prerecordingTranscript}}
```

The conversation prompt was likewise restored to exactly:

```text
{{userInput}}
{{characterProfile}}
{{promptContext}}
{{prerecordingTranscript}}
```

This parity applies to every character and every ScriptPoint. ScriptPoint01, ScriptPoint02, and ScriptPoint03 must all call the same `TuringFlowEngine -> TuringDialogueService -> fresh Foundation session -> TuringCharacterQwenRenderer` machinery. Their only allowed authored differences are:

```text
character/profile ID
voice ID and clone profile
promptContext values from the ScriptPoint voicePrompt descriptor
PR descriptor/transcript
output route
comm/filler sequencing declared by the ScriptPoint descriptor
```

There must be no ScriptPoint02- or ScriptPoint03-specific prompt assembly path. Add a parity test that renders all three requests through `TuringDialogueService` and verifies the same placeholder/input manifest.

### voicePrompt contract

Exactly:

```text
character profile
prompt context
PR transcript from the authored/transcription pipeline
```

Current production replacement map:

```swift
let prompt = try Self.renderPrompt(
    resourcePath:
        "Turing/Prompts/voicePrompt_characterIntent.txt",
    replacements: [
        "{{characterProfile}}":
            profile.voicePromptPromptText,
        "{{promptContext}}":
            request.promptContext,
        "{{prerecordingTranscript}}":
            request.prerecordingTranscript
    ]
)
```

Current request construction:

```swift
VoicePromptRequest(
    id: voicePrompt.voicePromptID,
    characterProfileID:
        voicePrompt.characterProfileID,
    promptContext: """
    Story intent:
    \(voicePrompt.intent)

    Emotional tone:
    \(voicePrompt.emotion)
    """,
    prerecordingTranscript:
        prerecording.transcript
)
```

The log contract must remain:

```text
inputContract: characterProfile,promptContext,prerecordingTranscript
dialogueHistoryIncluded: false
conversationSeedIncluded: false
```

### conversationPrompt contract

Exactly:

```text
user input
character profile
prompt context
PR transcript from the authored/transcription pipeline
```

Current production replacement map:

```swift
let prompt = try Self.renderPrompt(
    resourcePath:
        "Turing/Prompts/conversationPrompt_playerTurn_noBible.txt",
    replacements: [
        "{{characterProfile}}": profile.promptText,
        "{{promptContext}}": request.promptContext,
        "{{prerecordingTranscript}}":
            request.prerecordingTranscript,
        "{{userInput}}": request.userInput
    ]
)
```

The log contract must remain:

```text
inputContract: userInput,characterProfile,promptContext,prerecordingTranscript
dialogueHistoryIncluded: false
conversationSeedIncluded: false
```

### Forbidden prompt inputs

Reject any implementation that adds these to either prompt:

```text
TuringEpisodeContinuationSnapshot
checkpoint names or revision
completedScriptPointIDs
dialogueHistoryJSON
conversationSeedJSON
seedIntent
previous generated promptVoice segments
previous conversationVoice segments
room placement state
Battle01 state
audio state
walkie gate state
```

The existing `TuringDialogueHistoryStore` may remain for diagnostics or be removed in a later isolated cleanup, but its values must not be rendered into Foundation prompts.

The existing `TuringConversationSeedStore` may hold the current authored PR transcript for routing compatibility, but `seed(for:)` must not be rendered into Foundation.

## Failure and Crash Semantics

```text
Foundation/Qwen/playback failure:
  do not advance checkpoint
  restore the action for the last committed checkpoint

App exits during generated playback:
  prior checkpoint remains authoritative

App exits after checkpoint write but before auto-advance:
  Continue restores the newly committed checkpoint

Corrupt or unknown save:
  disable Continue
  log the decode/migration error
  keep episode rows usable

Content revision mismatch:
  migrate explicitly or disable Continue
  never guess a later checkpoint

Room placement failure:
  keep the resume plan pending
  do not arm a walkie action until world readiness succeeds

Duplicate completion callback:
  ignore by sourceEventID

Older checkpoint write arriving late:
  ignore because checkpoints are monotonic
```

## Files to Add

```text
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryEpisodePickerView.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringEpisodeActionStrip.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringEpisodeContinuationSnapshot.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryProgressStore.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryResumePlanner.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryContinuationCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryWorldReadinessCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringPrologueCompletionCoordinator.swift
```

## Files to Modify

```text
Gravitas Plague/Gravitas Plague/GravitasPlagueApp.swift
Gravitas Plague/Gravitas Plague/PlagueDemoSession.swift
Gravitas Plague/Gravitas Plague/PlagueOperationModePosterMenu.swift
Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringEpisodeCatalog.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringEpisodeFlowController.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowConversationRunner.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowDescriptor.swift
Gravitas Plague/Gravitas Plague/Turing/Interaction/TuringStoryWalkieInteractionController.swift
Gravitas Plague/Gravitas Plague/Story/PrologueStoryActionRouter.swift
```

Do not modify the two prompt templates or `TuringDialogueService` as part of continuation unless a test demonstrates that the locked input contract has regressed.

## Required Logs

```text
[TuringEpisodePicker] presentation requested
  source: swiftUIOperationPoster | realityKitWallPoster

[TuringContinuation] checkpoint committed
  episodeID: prologue
  checkpoint: ...
  revision: ...
  sourceEventID: ...

[TuringContinuation] continue requested
  episodeID: prologue
  checkpoint: ...

[TuringContinuation] waiting for Story world

[TuringContinuation] Story world ready
  walkieInstalled: true
  placementCommitted: true

[TuringContinuation] resume plan applied
  completedScriptPointIDs: ...
  action: ...

[TuringPromptContract] verified
  voicePrompt: characterProfile,promptContext,prerecordingTranscript
  conversationPrompt: userInput,characterProfile,promptContext,prerecordingTranscript
  checkpointContextIncluded: false
```

## Tests

### Persistence

```text
round-trip every checkpoint
reject unknown schema
content revision mismatch does not guess
duplicate sourceEventID is idempotent
regressive write is ignored
newer checkpoint replaces older checkpoint
clear removes Continue
```

### Resume planning

```text
notStarted -> ScriptPoint01 play
Script01 promptVoice -> microphone + pending conversation progression
Script01 conversationVoice -> ScriptPoint02 play
Script02 promptVoice -> ScriptPoint03 play
Script03 promptVoice -> microphone + Battle01 start
```

### Completion boundaries

```text
Foundation completion does not save
Qwen completion does not save
segment-zero readiness does not save
playback start does not save
actual full playback completion saves
failed or partial generated playback does not save
conversation checkpoint saves before ScriptPoint02 begins
ScriptPoint02 checkpoint saves before ScriptPoint03 begins
ScriptPoint03 checkpoint saves before Battle01 begins
```

### Prompt contract regression

Render every ScriptPoint01-03 voicePrompt and conversationPrompt fixture and assert:

```text
voicePrompt contains only its three allowed dynamic inputs
conversationPrompt contains only its four allowed dynamic inputs
no dialogue history
no conversation seed
no checkpoint JSON
no prior generated turns
fresh Foundation session per call
```

### UI

```text
SwiftUI Story tap opens production picker
RealityKit Story tap opens the same production picker
neither tap starts Prologue automatically
Continue disabled without a valid snapshot
Continue shows the latest episode/checkpoint summary
Prologue row title/subtitle exact
Episode 1 row present and disabled
debug controls absent from production picker
episode strips reuse device-button sizing and glass style
```

## Headset Acceptance

1. Fresh install and tap Story in SwiftUI: production picker opens; no Story audio begins.
2. Close picker and tap Story on RealityKit poster: same picker opens.
3. Verify Continue disabled before progress exists.
4. Tap Prologue and complete room placement.
5. Verify play icon starts ScriptPoint01.
6. Exit after ScriptPoint01 promptVoice fully finishes.
7. Relaunch, tap Story, tap Continue.
8. After room placement, verify microphone icon appears and no ScriptPoint01 audio replays.
9. Complete conversationVoice and terminate before ScriptPoint02 begins.
10. Continue and verify play icon starts ScriptPoint02.
11. Complete ScriptPoint02 promptVoice and terminate before ScriptPoint03 begins.
12. Continue and verify play icon starts ScriptPoint03.
13. Complete ScriptPoint03 promptVoice and terminate.
14. Continue and verify microphone appears and Grandma/Battle01 begins inside the portal without replaying ScriptPoint03.
15. Confirm every Foundation log still reports the locked prompt contracts.
16. Confirm no checkpoint data appears between Foundation prompt BEGIN/END logs.

## Completion Report Required from Codex

The implementing agent must report:

```text
all files added and changed
exact persistent key and schema
exact checkpoint write call sites
proof each write follows actual playback completion
exact resume action for each checkpoint
proof SwiftUI and RealityKit Story taps open one picker
proof debug controls are absent from production picker
rendered prompt-input manifests for ScriptPoint01-03
unit-test results
visionOS build result
headset tests not performed, if applicable
```
