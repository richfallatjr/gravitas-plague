import Foundation

actor TuringStoryHotspotDebugArtifacts {
    private struct HotspotRecord: Codable {
        let hotspotID: String
        let propID: String
        let wallID: String
        let minimumLocalX: Float
        let maximumLocalX: Float
        let recommendedLocalX: Float
        let exactPlacementIDs: [String]
        let deterministicQuality: Float
    }

    private struct ExactSummary: Codable {
        let total: Int
        let byProp: [String: Int]
        let minimumQuality: Float
        let maximumQuality: Float
    }

    private struct ValidationRecord: Codable {
        let scanID: String
        let accepted: Bool
        let error: String?
    }

    private struct FailureRecord: Codable {
        let scanID: String
        let stage: String
        let reason: String
        let fallbackUsed: Bool
    }

    func writePerimeter(_ perimeter: TuringStoryRoomPerimeter) {
        let rows = perimeter.wallsClockwise.map { wall in
            [
                wall.wallID,
                "\(wall.startXZ.x)", "\(wall.startXZ.y)",
                "\(wall.endXZ.x)", "\(wall.endXZ.y)"
            ]
        }
        writeJSON(rows, named: "last_perimeter.json")
    }

    func writeExactSummary(_ catalog: TuringStoryExactPlacementCatalog) {
        let qualities = catalog.placements.map(\.deterministicQuality)
        writeJSON(
            ExactSummary(
                total: catalog.placements.count,
                byProp: Dictionary(uniqueKeysWithValues: TuringStoryPropID.allCases.map { prop in
                    (prop.rawValue, catalog.placements(for: prop).count)
                }),
                minimumQuality: qualities.min() ?? 0,
                maximumQuality: qualities.max() ?? 0
            ),
            named: "last_exact_placement_summary.json"
        )
    }

    func writeAtlas(_ atlas: TuringStoryHotspotAtlas) {
        writeJSON(
            atlas.hotspots.map {
                HotspotRecord(
                    hotspotID: $0.hotspotID,
                    propID: $0.propID.rawValue,
                    wallID: $0.wallID,
                    minimumLocalX: $0.minimumLocalX,
                    maximumLocalX: $0.maximumLocalX,
                    recommendedLocalX: $0.recommendedLocalX,
                    exactPlacementIDs: $0.exactPlacementIDs,
                    deterministicQuality: $0.deterministicQuality
                )
            },
            named: "last_hotspot_atlas.json"
        )
    }

    func writeDataset(_ dataset: TuringStoryHotspotPromptDataset) {
        writeJSON(dataset, named: "last_compact_dataset.json")
    }

    func writePrompt(_ prompt: String) {
        writeText(prompt, named: "last_rendered_prompt.txt")
    }

    func writeBudget(_ budget: TuringStoryFoundationPromptBudget.Result) {
        writeJSON(budget, named: "last_prompt_budget.json")
    }

    func writeRawResponse(_ response: String) {
        writeText(response, named: "last_raw_response.txt")
    }

    func writeValidation(scanID: String, error: String?) {
        writeJSON(
            ValidationRecord(scanID: scanID, accepted: error == nil, error: error),
            named: "last_validation.json"
        )
    }

    func writeAcceptedPlan(_ plan: TuringStoryHotspotPlan) {
        writeJSON(plan, named: "last_accepted_plan.json")
    }

    func writeFailure(scanID: String, stage: String, reason: String) {
        writeJSON(
            FailureRecord(scanID: scanID, stage: stage, reason: reason, fallbackUsed: false),
            named: "last_failure.json"
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, named fileName: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try write(encoder.encode(value), named: fileName)
        } catch {
            print("[TuringWallHotspot] artifact write failed file=\(fileName) error=\(error.localizedDescription)")
        }
    }

    private func writeText(_ value: String, named fileName: String) {
        do { try write(Data(value.utf8), named: fileName) }
        catch {
            print("[TuringWallHotspot] artifact write failed file=\(fileName) error=\(error.localizedDescription)")
        }
    }

    private func write(_ data: Data, named fileName: String) throws {
        let manager = FileManager.default
        let directory = try manager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TuringWallHotspotLayoutLogs", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = directory.appendingPathComponent(fileName)
        let temporary = directory.appendingPathComponent("\(fileName).tmp")
        try? manager.removeItem(at: temporary)
        try data.write(to: temporary)
        if manager.fileExists(atPath: final.path) { try manager.removeItem(at: final) }
        try manager.moveItem(at: temporary, to: final)
    }
}
