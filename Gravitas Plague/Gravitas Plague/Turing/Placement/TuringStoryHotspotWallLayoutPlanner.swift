import Foundation

actor TuringStoryHotspotWallLayoutPlanner {
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
            "[TuringWallHotspot] Foundation request started freshSession=true responseSchema=hotspotPlusNormalizedPosition"
        )
        let raw = try await runner.runPrompt(
            accepted.prompt,
            purpose: "storyWallHotspotLayoutPlanner"
        )
        print("[TuringWallHotspotRaw] BEGIN\n\(raw)\n[TuringWallHotspotRaw] END")
        await debugArtifacts.writeRawResponse(raw)
        let plan = try await decodeWithOneRepair(
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

    func replan(
        previous: TuringStoryHotspotPlannerResult,
        validationError: String
    ) async throws -> TuringStoryHotspotPlan {
        let template = try loadPrompt(named: "storyWallHotspotLayoutReplan")
        let datasetJSON = try encodeCompact(previous.dataset)
        let prompt = template
            .replacingOccurrences(
                of: "{{previousResponseJSON}}",
                with: previous.rawResponse
            )
            .replacingOccurrences(
                of: "{{validationErrorsJSON}}",
                with: jsonString(validationError)
            )
            .replacingOccurrences(
                of: "{{hotspotDatasetJSON}}",
                with: datasetJSON
            )
        let budget = TuringStoryFoundationPromptBudget.evaluate(
            prompt: prompt,
            hotspotCount: previous.atlas.hotspots.count
        )
        logBudget(budget)
        guard budget.withinBudget else {
            throw TuringStoryHotspotLayoutError.compactHotspotPromptStillTooLarge
        }
        print("[TuringWallHotspot] replan request started freshSession=true")
        let raw = try await runner.runPrompt(
            prompt,
            purpose: "storyWallHotspotLayoutReplan"
        )
        print("[TuringWallHotspotReplanRaw] BEGIN\n\(raw)\n[TuringWallHotspotReplanRaw] END")
        await debugArtifacts.writeRawResponse(raw)
        do { return try strictDecode(raw) }
        catch {
            throw TuringStoryHotspotLayoutError.secondPlanInvalid(error.localizedDescription)
        }
    }

    private func decodeWithOneRepair(
        _ raw: String,
        scanID: String,
        atlas: TuringStoryHotspotAtlas
    ) async throws -> TuringStoryHotspotPlan {
        do { return try strictDecode(raw) }
        catch {
            let grouped = Dictionary(grouping: atlas.hotspots, by: \.propID).mapValues {
                $0.map(\.hotspotID).sorted()
            }
            let repairPrompt = """
            Repair malformed JSON. Return JSON only with exact keys v,scan,a and exact a keys d,w,s,p.
            Each value is null or [hotspotID,u]. Scan must be \(scanID).
            Valid IDs: \(grouped)
            Parse error: \(error.localizedDescription)
            Malformed response: \(raw)
            """
            let repaired = try await runner.runPrompt(
                repairPrompt,
                purpose: "storyWallHotspotLayoutPlanner.jsonRepair"
            )
            return try strictDecode(repaired)
        }
    }

    private func strictDecode(_ raw: String) throws -> TuringStoryHotspotPlan {
        let data = try TuringJSONSanitizer.extractSingleTopLevelObject(from: raw)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let top = object as? [String: Any],
              Set(top.keys) == Set(["v", "scan", "a"]),
              let assignments = top["a"] as? [String: Any],
              Set(assignments.keys) == Set(["d", "w", "s", "p"]) else {
            throw TuringStoryHotspotLayoutError.malformedResponse(
                "Response keys must be exactly v,scan,a and d,w,s,p."
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

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "\"error\"" }
        return string
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
