# Turing Foundation Prompt Audit

Status: current production baseline audit  
Repository: `/Users/richardfallat/Projects/dev/gravitas-plague`  
Scope: every Apple Foundation Models prompt submission in the app target, including repair and diagnostic paths

## Submission Boundary

Every Foundation request enters through:

`Gravitas Plague/Gravitas Plague/Turing/Foundation/TuringFoundationModelsRunner.swift`

The gateway currently does three things to every prompt:

1. Replaces the case-insensitive whole word `shit` with `stuff`.
2. Logs and writes the exact post-sanitization prompt.
3. Creates one fresh `FoundationModels.LanguageModelSession`, submits one prompt, and releases the session scope.

There are no other `LanguageModelSession` construction sites in the app target.

The exact device prompt is written under:

`Library/Caches/TuringFoundationLogs/last_<purpose>_prompt.txt`

## Production Prompt Inventory

| Purpose | Active caller | Template/source | Runtime data inserted |
| --- | --- | --- | --- |
| `voicePrompt_characterIntent` | `TuringDialogueService.generateVoicePrompt` | `Turing/Prompts/voicePrompt_characterIntent.txt` | full character profile, authored promptVoice seed, current ScriptPoint PR transcript |
| `conversationPrompt_playerTurn_noBible` | `TuringDialogueService.generateConversationNoBible` | `Turing/Prompts/conversationPrompt_playerTurn_noBible.txt` | full character profile, authored promptVoice seed, current ScriptPoint PR transcript, current user dictation |
| `turingDialogue_jsonRepair` | dialogue JSON repair service | Swift multiline string in `TuringDialogueService.swift` | required schema, parser error, entire invalid model response |
| `voiceScript_audiobookSourceSectionSegmentation` | `TuringPhase1AudiobookRunner.prepareSection` | `Turing/Prompts/voiceScript_audiobookSourceSectionSegmentation.txt` | section index and one mechanically selected source section |
| `voiceScript_audiobookSourceSectionSegmentationRepair` | `TuringPhase1AudiobookRunner` | Swift multiline string | section index, parser error, full source section; the invalid response itself is not included |
| `storyWallSliceLayoutPlanner` | `TuringStoryWallSliceLayoutPlanner.plan` | `Turing/Prompts/storyWallSliceLayoutPlanner.txt` | compact measured slice dataset containing `id`, `options`, `wall`, and normalized wall-area `score` |

The active room-placement path makes one Foundation request. It does not make a Foundation retry. Any rejected or incomplete plan goes to the deterministic scored wall-distribution fallback.

## VoicePrompt Contract

The rendered prompt contains exactly these runtime sources:

```text
full authored character profile
authored promptVoice seed
current ScriptPoint prerecording transcript
```

It does not insert dialogue history, continuation state, room state, prior generated turns, user dictation, or the generated `conversationSeed` from an earlier response.

The full character block is built as:

```text
<displayName> (<characterID>)
Voice: <defaultVoiceID>
<complete Characters/<character>.json writeup>
```

The shared template currently also requires a generated `conversationSeed` object in every voicePrompt response. The runtime validates that object but does not use it as the later conversationPrompt input. The actual later input is the deterministic authored `TuringPromptVoiceSeed`.

### ScriptPoint01

Character: full `big_mike.json` profile  
PR: `prologue.walkie.bigMike.richContact.001`  
Context is synthesized by `TuringPromptVoiceSeedBuilder.standard`:

```text
Story intent:
You are asking if Rich can hear you. You are worried because you have not heard from Rich at your regular cadence and something may be wrong. Continue after the authored radio contact without repeating it. Give Rich a believable, direct reason to answer.

Emotional tone:
worried, controlled, protective
```

### ScriptPoint02

Character: full `rich.json` profile  
PR: `prologue.walkie.rich.scriptPoint02.001`  
Context is synthesized:

```text
Story intent:
Continue Rich's same outgoing transmission after the authored PR. Say that the receive side appears alive but the transmitter is still uncertain. Ask Big Mike what he personally saw and what stimulus the woman reacted to: sound, light, movement, or voice. Use no more than one brief dry observation. Do not repeat the whole PR, narrate Rich's actions, or write Big Mike's lines.

Emotional tone:
relieved to hear Mike, tired, skeptical, quick, controlled, increasingly alert
```

### ScriptPoint03

Character: full `big_mike.json` profile  
PR: `prologue.walkie.bigMike.scriptPoint03.001`  
Context is synthesized:

```text
Story intent:
You are Mike. You are relieved Rich is okay but need to communicate the danger he may be in with infected wandering the area. Tell Rich to locate and quietly prepare his ham-radio equipment without transmitting. Keep Mike direct, protective, skeptical, and under pressure.

Emotional tone:
protective, tactical, breath controlled after immediate danger, skeptical and urgent
```

### ScriptPoint04

Character: full `rich.json` profile  
PR: `prologue.walkie.rich.scriptPoint04.001`  
Literal context override:

```text
Story Intent:
I can't believe this thing is laying in my room. It's not a person anymore it's a monster. I am still freaking out. We need the police. But police services have been down for weeks. I need to get this thing out of here
```

### ScriptPoint05

Character: full `big_mike.json` profile  
PR: `prologue.walkie.bigMike.scriptPoint05.001`  
Literal context override:

```text
Story Intent:
I'm trying to support Rich but he may have messed up. You can't just neutralize anything you please. I'll just let him know he did what he had to do. Drag that thing out into the woods. I read this article to change the subject but nobody's buying that.
```

ScriptPoint05 correctly uses its PR transcript for promptVoice. It does not insert the headline ScriptVoice source into promptVoice.

## ConversationPrompt Contract

The active conversation path resolves four values:

```text
current user dictation
full authored character profile
deterministic authored promptVoice seed for the current Turing Flow
current ScriptPoint PR transcript
```

`TuringFlowConversationRunner` reads the promptVoice seed and PR transcript from `TuringConversationSeedStore`. The generated `conversationSeed` returned by voicePrompt is not read here. No dialogue history is stored or submitted.

Current template labels are:

```text
Character:
Prompt context:
This is what you last said:
User input:
```

This differs from the newer voicePrompt labels (`Character Profile`, literal `Story Intent`, and `What you just said earlier`). The data sources are correct, but the wrapper language is not standardized.

All ScriptPoints currently share the same conversation key:

`dialogue.big_mike.rich`

Starting a point overwrites the PR for that key. Completing its promptVoice overwrites the promptVoice seed. If a new point updates the PR and then fails before updating its seed, the store can temporarily contain a new PR paired with the previous point's seed.

## ScriptVoice / Audiobook Contract

The production ScriptPoint05 ScriptVoice stage uses the same Foundation section planner as the audiobook path:

```text
mechanically normalize source
mechanically create source sections
send one section to a fresh Foundation session
accept section speech segments
publish accepted batches to Fresh2
```

Foundation receives only:

```text
section index
source section text
segmentation instructions and JSON schema
```

It does not receive a character profile, Story Intent, PR transcript, promptVoice seed, prior section tail, next section head, or conversation history.

Current defect: `TuringAudiobookSegmentationParser` accepts the returned `spokenText` and logs `semanticValidation: disabled`. The prompt asks Foundation to cover and preserve order, but does not explicitly prohibit paraphrasing, additions, or omissions, and code does not compare accepted speech against the source section. Therefore ScriptVoice is not currently guaranteed to preserve the authored source exactly.

The repair prompt receives the source section and parser error, but not the malformed response it is nominally repairing. It asks Foundation to produce a replacement segmentation from the source.

## Room-Placement Contract

The active room prompt is `storyWallSliceLayoutPlanner.txt`.

Foundation receives rows shaped as JSON objects:

```json
{"id":"92","options":"D2,B1,W1,W2,S1,P1","wall":9,"score":1.0}
```

It does not receive transforms, exact placement objects, occupancy geometry, room center, spin direction, wall endpoints, wall dimensions, or floor measurements. `score` is wall surface area divided by the largest wall surface area.

Current defects in the prompt:

1. It says `return the same SLICE_ID for different object`, directly contradicting the surrounding no-reuse rules.
2. It says IDs must appear as `sliceID` in `Room.slices`, but the actual row key is `id`.
3. It calls option codes both "suggested" and mandatory.
4. It requires numeric slice IDs to be at least 10 apart, which is a wall-block convention rather than a physical-distance measurement.
5. It contains hostile prose that has no placement semantics and consumes prompt budget.

The resolver no longer enforces option compatibility. Unknown numeric slice IDs are projected to the nearest known slice on the inferred wall. Missing props or insufficient distinct walls cause deterministic fallback, not a second Foundation request.

## Repair Prompts

### Dialogue JSON repair

Used after malformed voicePrompt or conversationPrompt JSON. It includes:

```text
expected response schema
parser error text
entire invalid Foundation response
```

For voicePrompt, the repair schema still requires the unused `conversationSeed` object.

### Audiobook section repair

Used after malformed section JSON. It includes:

```text
section index
parser error text
entire source section
```

It does not include the invalid response, despite being named a repair.

## Diagnostic-Only Prompts

The following prompts are reachable only from the native Qwen debug canary, not the production Turing Flow:

| Purpose | Resource |
| --- | --- |
| `voiceScript_exactSegmentation` | `Turing/Prompts/voiceScript_exactSegmentation.txt` |
| `voiceScript_jsonRepair` | `Turing/Prompts/voiceScript_jsonRepair.txt` |

Unlike the production audiobook prompt, the diagnostic exact-segmentation prompt explicitly forbids paraphrasing, additions, removals, reordering, and punctuation changes. It also performs a normalized exact-coverage comparison.

## Dormant / Orphaned Prompts

`TuringStoryHotspotWallLayoutPlanner` and its primary prompt compile, but no production owner constructs the planner. The active coordinator constructs `TuringStoryWallSliceLayoutPlanner` instead.

Dormant resources/code:

```text
Turing/Prompts/storyWallHotspotLayoutPlanner.txt
Turing/Prompts/storyWallHotspotLayoutReplan.txt
TuringStoryHotspotWallLayoutPlanner.swift
```

The replan resource has no code reference at all. The dormant hotspot planner contains an inline JSON-repair prompt, but spatial replan is disabled.

## Qwen TTS Boundary

Foundation output speech text and emotion become Qwen segment input. Qwen does not receive the Foundation character profile, Story Intent, PR transcript, user dictation, room data, or Foundation response schema. The base-clone path receives the accepted segment text plus the selected immutable clone profile/reference artifacts.

## Audit Findings

### High priority

1. The active room-placement prompt contains mutually exclusive output instructions.
2. Production ScriptVoice accepts semantic rewrites because exact source coverage is disabled.
3. VoicePrompt requires an unused generated `conversationSeed`, spending response budget and making the model produce state that the established conversation contract does not consume.

### Medium priority

4. ScriptPoints01-03 synthesize additional `Emotional tone` prompt prose; ScriptPoints04-05 use literal Story Intent. The five points do not share one prompt-context contract.
5. ConversationPrompt still uses generic wrapper labels rather than the explicit authored labels used by voicePrompt.
6. The shared conversation key can pair a newly stored PR with an older promptVoice seed if a point fails between those two writes.
7. The global word sanitizer mutates every Foundation payload, including user input, exact ScriptVoice source text, repair payloads, and character profiles. This is intentional for Foundation safety, but it means "exact source" is exact only after sanitization.

### Cleanup

8. Dormant hotspot prompt code and an entirely unreferenced replan resource remain in the target.
9. Prompt contract tests check selected phrases and placeholders, but there is no single inventory test that fails when a new Foundation purpose or prompt resource is added without review.

## Recommended Cleanup Order

1. Correct the active wall-slice prompt contradictions without changing the deterministic fallback.
2. Decide whether production ScriptVoice must preserve exact authored text; if yes, use the exact-segmentation requirements and enforce coverage in code.
3. Remove `conversationSeed` from the voicePrompt response schema and parser if it is permanently non-authoritative.
4. Convert all five promptVoice descriptors to literal reviewed `Story Intent` blocks.
5. Rename conversation wrapper labels without changing its four approved data inputs.
6. Make stored conversation context atomic per ScriptPoint or store a single versioned `{PR, promptVoiceSeed}` pair.
7. Add a repository test that inventories every Foundation purpose, template, inline repair prompt, and active/dormant status.
8. Delete dormant hotspot prompt code/resources after confirming no planned migration depends on them.
