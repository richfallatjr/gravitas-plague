import Foundation

actor TuringStoryWallSliceDebugArtifacts {
    func writeDataset(_ dataset: TuringStoryWallSlicePromptDataset) {
        writeJSON(dataset, name: "last_slice_dataset.json")
    }

    func writePrompt(_ prompt: String) {
        write(Data(prompt.utf8), name: "last_slice_prompt.txt")
    }

    func writeRaw(_ raw: String) {
        write(Data(raw.utf8), name: "last_slice_response.txt")
    }

    func writePlan(_ plan: TuringStoryWallSlicePlan) {
        writeJSON(plan, name: "last_slice_plan.json")
    }

    private func writeJSON<T: Encodable>(_ value: T, name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        write(data, name: name)
    }

    private func write(_ data: Data, name: String) {
        do {
            let manager = FileManager.default
            let directory = try manager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("TuringWallSliceLayoutLogs", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            print("[TuringWallSlices] artifact write failed name=\(name) error=\(error.localizedDescription)")
        }
    }
}
