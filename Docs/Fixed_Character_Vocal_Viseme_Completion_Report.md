# Fixed-Character Vocal Visemes — Completion Report

Status: **READY FOR VISION PRO FUNCTIONAL ACCEPTANCE**. The implementation,
offline authoring, Debug build, Release build, and built-app resource audits pass.
This report does not claim an in-headset result.

## Scope

The Angel-grade authored all-phone pipeline now drives every physical character
that has an owner-authored vocal-close blendshape:

- Dad
- Grandma
- Spouse
- Biker
- Neighbor

Angel retains its existing authored pipeline and is the mandatory golden reference
for the shared compiler. The authoring gate regenerates Angel and requires the exact
run hash:

```text
6a48f84827b2842fb3199c1bf4965113b3a65f8c55eedd7c0b23772c983b4a8a
```

## Shipped data

Each fixed character ships one catalog and nine distinct 60-fps pose tracks:

```text
1 presence/breathing loop
4 damage vocals
4 death vocals
```

Total: five catalogs, 45 manifests, 152,997 bytes of JSON. All 45 manifest
basenames are globally unique because Xcode flattens synchronized resources into
the app-bundle root. The shared `dad_breathing.wav` therefore uses these manifest
names:

```text
dad_breathing.visemes.json
grandma-dad_breathing.visemes.json
spouse-dad_breathing.visemes.json
biker-dad_breathing.visemes.json
neighbor-dad_breathing.visemes.json
```

No WAV is copied into a viseme folder. Audio identity remains the exact audible WAV.

## Production runtime

- All five characters route exclusively through `CharacterVocalVisemeTrackStore`.
- The former runtime amplitude/energy analyzer and compatibility store are deleted.
- Gameplay performs no WAV decoding, PCM retention, PocketSphinx work, RMS/energy
  analysis, or pose generation.
- Audio begins independently of visual readiness. A late manifest joins at the
  current `ContinuousClock` phase instead of restarting the audio or animation.
- Exact source, playback, character, archetype, role, filename, and looping identity
  protect against cross-character and stale-event attachment.
- A catalog explicitly rejects a manifest owned by another character, including the
  otherwise hash-identical shared breathing asset.
- Damage overrides the continuing presence loop. When damage completes, presence
  resumes at its current modulo phase.
- Death overrides all other vocal animation, rejects later damage, and settles to
  the closed/rest sculpt permanently for that source.
- The physical source and portal mirror receive one shared scalar and one clock.
- Missing/stale visual data fails closed without altering audio, combat, Jock
  animation, portal behavior, or story progression.

The locked anatomical mapping is unchanged for every character:

```text
rest / teeth  = 1.00 closed sculpt
small / round = 0.50
wide          = 0.00 original open basis
```

## Offline authoring

Use the generic command (all five characters by default):

```text
Scripts/build_fixed_character_vocal_visemes.sh --check
Scripts/build_fixed_character_vocal_visemes.sh --write
```

Repeated `--character <id>` arguments limit a run to selected characters. The
compiler uses pinned PocketSphinx 5.1.1 all-phone alignment, the Angel phone-to-pose
map, coarticulation and minimum-hold rules, and compact contiguous runs. Nonverbal
character clips use PocketSphinx non-silence phone intervals for boundaries; pose
identity is still exclusively phone-derived.

## Verification completed

- Generic authoring check: PASS, Angel golden exact, 5 catalogs / 45 manifests.
- Deterministic isolated regeneration: PASS; independent two-run output is
  byte-identical, stably ordered, timestamp-free, and matches production.
- Authoring tests: 14/14 PASS.
- Shared runtime contracts: 19/19 PASS.
- Grandma, Spouse, Biker, and Neighbor geometry/integration suites: 20/20 PASS.
- Dynamic authority tests: PASS for loop wrap, damage override and phase-correct
  resume, terminal death, stale callbacks, exact 1.25-second late join, and all-five
  character isolation.
- Static production audit: no runtime analyzer, amplitude, RMS, PCM, or AVAudio
  analysis path anywhere under `CharacterPerformance`.
- Generic visionOS Debug app build with signing disabled: PASS.
- Generic visionOS Release app build with signing disabled: PASS.
- Debug and Release bundle audits: exactly 5 catalogs and 45 manifests; all are
  source-identical, all basenames are unique, and no authoring tool or intermediate
  leaked into the app.
- `git diff --check` and Swift syntax parsing: PASS.

The project-wide hosted XCTest launch remains blocked by pre-existing Turing test
support actor-isolation errors. Those unrelated sources were not changed. Focused
runtime behavior is covered by the pure authority reducer and its executable tests.

## Remaining device acceptance

Run Dad, Grandma, Spouse, Biker, and Neighbor in their story/Horde appearances and
confirm:

1. Breathing animates while idle and in the window/portal presentation.
2. Every damage recording overrides breathing and returns at the continuing phase.
3. Every death recording ends closed and remains terminal.
4. Physical and portal copies remain visually synchronized.
5. Rapid replacement, cancellation, Continue, and a second run do not accept stale
   events.
6. No visual failure affects audio, combat, character animation, or progression.

## Source-control state

The implementation remains unstaged and uncommitted in the existing dirty worktree.
New catalogs, manifests, runtime sources, tools, tests, descriptors, offset payloads,
and character USDZs are intentionally not ignored, but must be included when the
owner creates the delivery commit. No unrelated owner changes were reset, cleaned,
staged, or committed.
