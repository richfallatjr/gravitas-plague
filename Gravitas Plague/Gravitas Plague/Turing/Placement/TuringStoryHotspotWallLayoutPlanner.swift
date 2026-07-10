import Foundation

actor TuringStoryHotspotWallLayoutPlanner {
    // Spatial replan is disabled; malformed output is recovered mechanically or by JSON repair.
    private let runner: any TuringFoundationQueryRunning
    private let compressor: TuringStoryPlacementHotspotCompressor
    let debugArtifacts: TuringStoryHotspotDebugArtifacts

    init(
        runner: any TuringFoundationQueryRunning = TuringFoundationModelsRunner(),
        compressor: TuringStoryPlacementHotspotCompressor = TuringStoryPlacementHotspotCompressor(),
        debugArtifacts: TuringStoryHotspotDebugArtifacts = TuringStoryHotspotDebugArtifacts()
    ) {
        self.runner = runner
        self.compressor = compressor
        self.debugArtifacts = debugArtifacts
    }

    func plan(
        context: TuringStoryHotspotPlanningContext
    ) async throws -> TuringStoryHotspotPlannerResult {
        let template = try loadPrompt(named: "storyWallHotspotLayoutPlanner")
        var accepted: (
            atlas: TuringStoryHotspotAtlas,
            dataset: TuringStoryHotspotPromptDataset,
            json: String,
            prompt: String,
            budget: TuringStoryFoundationPromptBudget.Result
        )?

        for maximum in TuringStoryFoundationPromptBudget.hotspotReductionSequence {
            let atlas = try compressor.compress(
                catalog: context.catalog,
                perimeter: context.perimeter,
                maximumTotal: maximum
            )
            let dataset = TuringStoryHotspotPromptDataset.make(
                perimeter: context.perimeter,
                atlas: atlas,
                feasibility: context.feasibility,
                posterSize: context.posterSize
            )
            let json = try encodeCompact(dataset)
            let prompt = template.replacingOccurrences(
                of: "{{hotspotDatasetJSON}}",
                with: json
            )
            let budget = TuringStoryFoundationPromptBudget.evaluate(
                prompt: prompt,
                hotspotCount: atlas.hotspots.count
            )
            logBudget(budget)
            if budget.withinPreferredBudget ||
                (maximum == TuringStoryFoundationPromptBudget.hotspotReductionSequence.last && budget.withinBudget) {
                accepted = (atlas, dataset, json, prompt, budget)
                break
            }
        }
        guard let accepted else {
            throw TuringStoryHotspotLayoutError.compactHotspotPromptStillTooLarge
        }

        await debugArtifacts.writeAtlas(accepted.atlas)
        await debugArtifacts.writeDataset(accepted.dataset)
        await debugArtifacts.writePrompt(accepted.prompt)
        await debugArtifacts.writeBudget(accepted.budget)
        print(
            "[TuringWallHotspot] Foundation request started freshSession=true responseSchema=rankedHotspotCandidates candidateCountPerProp=2"
        )
        let raw = try await runner.runPrompt(
            accepted.prompt,
            purpose: "storyWallHotspotLayoutPlanner"
        )
        print("[TuringWallHotspotRaw] BEGIN\n\(raw)\n[TuringWallHotspotRaw] END")
        await debugArtifacts.writeRawResponse(raw)
        let plan = await decodeRecoveringMalformedJSON(
            raw,
            scanID: context.perimeter.scanID,
            atlas: accepted.atlas
        )
        return TuringStoryHotspotPlannerResult(
            plan: plan,
            rawResponse: raw,
            atlas: accepted.atlas,
            dataset: accepted.dataset,
            renderedPrompt: accepted.prompt,
            budget: accepted.budget
        )
    }

    private func decodeRecoveringMalformedJSON(
        _ raw: String,
        scanID: String,
        atlas: TuringStoryHotspotAtlas
    ) async -> TuringStoryHotspotPlan {
        if let strict = try? strictDecode(raw),
           candidateCount(in: strict) == TuringStoryPropID.allCases.count * 2 {
            return strict
        }

        let normalized = mechanicallyNormalize(
            raw,
            scanID: scanID,
            atlas: atlas
        )
        if normalized.candidateCount == TuringStoryPropID.allCases.count * 2 {
            print(
                "[TuringWallHotspotJSON] response normalized mechanically candidateCount=\(normalized.candidateCount) repairRequired=false"
            )
            return normalized.plan
        }

        let validIDs = Dictionary(uniqueKeysWithValues: TuringStoryPropID.allCases.map { propID in
            (
                propID.shortID,
                atlas.hotspots(for: propID).map(\.hotspotID).sorted()
            )
        })
        let validIDsJSON = (try? encodeCompact(validIDs)) ?? "{}"
        let repairPrompt = """
        Repair a Story wall-placement JSON response without changing its selected hotspot IDs or u values.
        Return JSON only. No markdown and no commentary.
        Use exactly top-level keys "v", "scan", "a", "b". Set "v" to 1 and "scan" to "\(scanID)".
        "a" is candidate one and "b" is candidate two. Both must contain exactly "d", "w", "s", "p".
        Each value is null or [hotspotID,u]. Candidate two must preserve the original second choice when present.
        Valid hotspot IDs by prop: \(validIDsJSON)
        Malformed response:
        \(raw)
        """

        do {
            let repaired = try await runner.runPrompt(
                repairPrompt,
                purpose: "storyWallHotspotLayoutPlanner.jsonRepair"
            )
            print(
                "[TuringWallHotspotJSONRepairRaw] BEGIN\n\(repaired)\n[TuringWallHotspotJSONRepairRaw] END"
            )
            if let strict = try? strictDecode(repaired),
               candidateCount(in: strict) > 0 {
                return strict
            }
            let repairedNormalization = mechanicallyNormalize(
                repaired,
                scanID: scanID,
                atlas: atlas
            )
            if repairedNormalization.candidateCount >= normalized.candidateCount,
               repairedNormalization.candidateCount > 0 {
                print(
                    "[TuringWallHotspotJSON] malformed repair normalized mechanically candidateCount=\(repairedNormalization.candidateCount)"
                )
                return repairedNormalization.plan
            }
        } catch {
            print(
                "[TuringWallHotspotJSON] repair request failed; using mechanically normalized original response error=\(error.localizedDescription)"
            )
        }

        print(
            "[TuringWallHotspotJSON] malformed JSON did not fail placement candidateCount=\(normalized.candidateCount)"
        )
        return normalized.plan
    }

    private func mechanicallyNormalize(
        _ raw: String,
        scanID: String,
        atlas: TuringStoryHotspotAtlas
    ) -> (plan: TuringStoryHotspotPlan, candidateCount: Int) {
        let object: [String: Any]? = {
            guard let data = try? TuringJSONSanitizer.extractSingleTopLevelObject(from: raw),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = json as? [String: Any] else {
                return nil
            }
            return dictionary
        }()
        let primaryValues = normalizeAssignmentContainer(object?["a"])
        let secondaryValues = normalizeAssignmentContainer(object?["b"])

        func selection(
            for propID: TuringStoryPropID,
            values: [String: Any]?,
            siblingFallback: Bool,
            textFallback: Bool
        ) -> TuringHotspotSelection? {
            let validIDs = Set(atlas.hotspots(for: propID).map(\.hotspotID))
            let nestedValue = values?[propID.shortID]
            let siblingValue = siblingFallback ? object?[propID.shortID] : nil
            let hotspotID = extractHotspotID(from: nestedValue, validIDs: validIDs)
                ?? extractHotspotID(from: siblingValue, validIDs: validIDs)
                ?? (textFallback ? firstMentionedHotspotID(in: raw, validIDs: validIDs) : nil)
            guard let hotspotID else { return nil }
            let u = extractNormalizedPosition(from: nestedValue)
                ?? extractNormalizedPosition(from: siblingValue)
                ?? 0.5
            return TuringHotspotSelection(
                hotspotID: hotspotID,
                normalizedPosition: min(1, max(0, u))
            )
        }

        let door = selection(
            for: .door,
            values: primaryValues,
            siblingFallback: true,
            textFallback: true
        )
        let window = selection(
            for: .window,
            values: primaryValues,
            siblingFallback: true,
            textFallback: true
        )
        let walkieShelf = selection(
            for: .walkieShelf,
            values: primaryValues,
            siblingFallback: true,
            textFallback: true
        )
        let poster = selection(
            for: .poster,
            values: primaryValues,
            siblingFallback: true,
            textFallback: true
        )
        let secondaryDoor = selection(
            for: .door,
            values: secondaryValues,
            siblingFallback: false,
            textFallback: false
        )
        let secondaryWindow = selection(
            for: .window,
            values: secondaryValues,
            siblingFallback: false,
            textFallback: false
        )
        let secondaryWalkieShelf = selection(
            for: .walkieShelf,
            values: secondaryValues,
            siblingFallback: false,
            textFallback: false
        )
        let secondaryPoster = selection(
            for: .poster,
            values: secondaryValues,
            siblingFallback: false,
            textFallback: false
        )
        let secondaryAssignments: TuringStoryHotspotPlan.Assignments? = {
            guard [secondaryDoor, secondaryWindow, secondaryWalkieShelf, secondaryPoster]
                .contains(where: { $0 != nil }) else {
                return nil
            }
            return .init(
                d: secondaryDoor,
                w: secondaryWindow,
                s: secondaryWalkieShelf,
                p: secondaryPoster
            )
        }()
        let plan = TuringStoryHotspotPlan(
            v: 1,
            scan: scanID,
            a: .init(
                d: door,
                w: window,
                s: walkieShelf,
                p: poster
            ),
            b: secondaryAssignments
        )
        let candidateCount = [
            door,
            window,
            walkieShelf,
            poster,
            secondaryDoor,
            secondaryWindow,
            secondaryWalkieShelf,
            secondaryPoster
        ]
            .compactMap { $0 }
            .count
        return (plan, candidateCount)
    }

    private func normalizeAssignmentContainer(
        _ value: Any?
    ) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        guard let array = value as? [Any] else { return nil }

        var normalized: [String: Any] = [:]
        var index = 0
        while index < array.count {
            if let pair = array[index] as? [Any],
               let hotspotID = pair.first as? String,
               let propKey = propKey(for: hotspotID) {
                normalized[propKey] = pair
                index += 1
                continue
            }
            guard let hotspotID = array[index] as? String,
                  let propKey = propKey(for: hotspotID) else {
                index += 1
                continue
            }
            if index + 1 < array.count,
               number(from: array[index + 1]) != nil {
                normalized[propKey] = [hotspotID, array[index + 1]]
                index += 2
            } else {
                normalized[propKey] = hotspotID
                index += 1
            }
        }
        return normalized.isEmpty ? nil : normalized
    }

    private func propKey(for hotspotID: String) -> String? {
        guard let first = hotspotID.first else { return nil }
        switch first {
        case "d", "w", "s", "p": return String(first)
        default: return nil
        }
    }

    private func candidateCount(in plan: TuringStoryHotspotPlan) -> Int {
        [
            plan.a.d,
            plan.a.w,
            plan.a.s,
            plan.a.p,
            plan.b?.d,
            plan.b?.w,
            plan.b?.s,
            plan.b?.p
        ]
        .compactMap { $0 }
        .count
    }

    private func extractHotspotID(
        from value: Any?,
        validIDs: Set<String>
    ) -> String? {
        guard let value else { return nil }
        if let string = value as? String, validIDs.contains(string) {
            return string
        }
        if let array = value as? [Any] {
            for item in array {
                if let hotspotID = extractHotspotID(from: item, validIDs: validIDs) {
                    return hotspotID
                }
            }
        }
        if let dictionary = value as? [String: Any] {
            for key in ["hotspotID", "hotspot", "id", "selection"] {
                if let hotspotID = extractHotspotID(
                    from: dictionary[key],
                    validIDs: validIDs
                ) {
                    return hotspotID
                }
            }
        }
        return nil
    }

    private func extractNormalizedPosition(from value: Any?) -> Float? {
        guard let value else { return nil }
        if let array = value as? [Any] {
            if array.count > 1, let number = number(from: array[1]) {
                return number
            }
            return array.compactMap(number(from:)).last
        }
        if let dictionary = value as? [String: Any] {
            for key in ["u", "normalizedPosition", "position"] {
                if let number = number(from: dictionary[key]) {
                    return number
                }
            }
        }
        return number(from: value)
    }

    private func number(from value: Any?) -> Float? {
        if let number = value as? NSNumber {
            return number.floatValue
        }
        if let string = value as? String {
            return Float(string)
        }
        return nil
    }

    private func firstMentionedHotspotID(
        in raw: String,
        validIDs: Set<String>
    ) -> String? {
        validIDs.compactMap { hotspotID -> (String, String.Index)? in
            guard let range = raw.range(of: "\"\(hotspotID)\"") else { return nil }
            return (hotspotID, range.lowerBound)
        }
        .min { $0.1 < $1.1 }?
        .0
    }

    private func strictDecode(_ raw: String) throws -> TuringStoryHotspotPlan {
        let data = try TuringJSONSanitizer.extractSingleTopLevelObject(from: raw)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let top = object as? [String: Any],
              Set(top.keys).isSubset(of: Set(["v", "scan", "a", "b"])),
              Set(top.keys).isSuperset(of: Set(["v", "scan", "a"])),
              let assignments = top["a"] as? [String: Any],
              Set(assignments.keys) == Set(["d", "w", "s", "p"]),
              (top["b"] == nil || (top["b"] as? [String: Any]).map {
                  Set($0.keys) == Set(["d", "w", "s", "p"])
              } == true) else {
            throw TuringStoryHotspotLayoutError.malformedResponse(
                "Response keys must be v,scan,a with optional b; a and b keys must be d,w,s,p."
            )
        }
        return try JSONDecoder().decode(TuringStoryHotspotPlan.self, from: data)
    }

    private func encodeCompact<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw TuringStoryHotspotLayoutError.malformedResponse("Compact JSON was not UTF-8.")
        }
        return string
    }

    private func loadPrompt(named name: String) throws -> String {
        let url = Bundle.main.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "Turing/Prompts"
        ) ?? Bundle.main.url(forResource: name, withExtension: "txt")
        guard let url else {
            throw TuringStoryHotspotLayoutError.malformedResponse("Missing prompt \(name).txt")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func logBudget(_ budget: TuringStoryFoundationPromptBudget.Result) {
        print(
            """
            [TuringWallHotspot] prompt budget
              contextSize: \(budget.contextSize)
              tokenCountMode: \(budget.tokenCountMode)
              promptTokens: \(budget.promptTokens)
              promptUTF8Bytes: \(budget.promptUTF8Bytes)
              hotspotCount: \(budget.hotspotCount)
              reservedTokens: \(budget.reservedTokens)
              withinBudget: \(budget.withinBudget)
            """
        )
    }
}
