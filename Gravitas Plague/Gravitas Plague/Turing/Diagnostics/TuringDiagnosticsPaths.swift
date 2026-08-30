import Foundation

enum TuringDiagnosticsPaths {
    static func rootURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport.appendingPathComponent(
            "TuringDiagnostics",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var excludedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(values)
        return root
    }

    static func MLXMetalLastFailureURL() throws -> URL {
        try rootURL().appendingPathComponent("mlx-metal-last-failure.json")
    }

    static func MLXMetalRunURL(runID: String) throws -> URL {
        let safeRunID = runID.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "_"
        }
        return try rootURL().appendingPathComponent(
            "mlx-command-buffers-\(String(safeRunID)).json"
        )
    }
}
