import Foundation

actor TuringStoryWallSliceLayoutPlanner {
    private static let hardPromptTokens = 2_300
    private static let maximumPromptUTF8Bytes = 8_500
    private let runner: any TuringFoundationQueryRunning
    private let artifacts: TuringStoryWallSliceDebugArtifacts

    init(
        runner: any TuringFoundationQueryRunning = TuringFoundationModelsRunner(),
        artifacts: TuringStoryWallSliceDebugArtifacts = TuringStoryWallSliceDebugArtifacts()
    ) {
        self.runner = runner
        self.artifacts = artifacts
    }

    func plan(map: TuringStoryWallSliceMap) async throws -> TuringStoryWallSlicePlannerResult {
        let dataset = TuringStoryWallSlicePromptDataset.make(from: map)
        let datasetJSON = try encode(dataset)
        let template = try loadPrompt(named: "storyWallSliceLayoutPlanner")
        let prompt = template.replacingOccurrences(
            of: "{{wallSliceDatasetJSON}}",
            with: datasetJSON
        )
        try preflight(prompt)
        await artifacts.writeDataset(dataset)
        await artifacts.writePrompt(prompt)
        print("[TuringWallSlices] prompt started freshSession=true")
        let raw = try await runner.runPrompt(
            prompt,
            purpose: "storyWallSliceLayoutPlanner"
        )
        await artifacts.writeRaw(raw)
        print("[TuringWallSlicesRaw] BEGIN\n\(raw)\n[TuringWallSlicesRaw] END")
        do {
            let decoded = try decode(raw)
            await artifacts.writePlan(decoded)
            return TuringStoryWallSlicePlannerResult(
                plan: decoded,
                rawResponse: raw,
                dataset: dataset,
                datasetJSON: datasetJSON,
                renderedPrompt: prompt
            )
        } catch {
            print(
                """
                [TuringWallSlices] primary response rejected
                  reason: \(error.localizedDescription)
                  foundationRetryUsed: false
                  nextAction: deterministicFallback
                """
            )
            throw error
        }
    }

    private func decode(_ raw: String) throws -> TuringStoryWallSlicePlan {
        let data = try TuringJSONSanitizer.extractSingleTopLevelObject(from: raw)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(["d", "w", "s", "p"]) else {
            throw TuringStoryWallSliceError.malformedResponse(
                "Keys must be exactly d,w,s,p."
            )
        }
        return try JSONDecoder().decode(TuringStoryWallSlicePlan.self, from: data)
    }

    private func preflight(_ prompt: String) throws {
        let budget = TuringStoryWallSlicePromptBudget.evaluate(prompt)
        print(
            "[TuringWallSlices] prompt budget promptTokens=\(budget.promptTokens) promptUTF8Bytes=\(budget.promptUTF8Bytes) reservedTokens=\(budget.reservedTokens) tokenCountMode=\(budget.tokenCountMode) withinBudget=\(budget.withinBudget)"
        )
        guard budget.withinBudget,
              budget.promptTokens <= Self.hardPromptTokens,
              budget.promptUTF8Bytes <= Self.maximumPromptUTF8Bytes else {
            throw TuringStoryWallSliceError.promptTooLarge
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func loadPrompt(named name: String) throws -> String {
        let url = Bundle.main.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "Turing/Prompts"
        ) ?? Bundle.main.url(forResource: name, withExtension: "txt")
        guard let url else {
            throw TuringStoryWallSliceError.malformedResponse("Missing prompt \(name).txt")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
