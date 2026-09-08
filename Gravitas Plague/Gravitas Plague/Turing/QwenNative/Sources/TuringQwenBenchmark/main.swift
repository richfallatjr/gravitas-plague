import Foundation
import TuringQwenNative

@main
struct TuringQwenBenchmarkCommand {
    static func main() async {
        await TuringQwenBenchmarkCLI.run()
    }
}

private enum TuringQwenBenchmarkCLI {
    static func run() async {
        do {
            let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
            if arguments.help {
                print(Arguments.usage)
                return
            }

            let baseline: TuringQwenOptimizationBenchmarkReport?
            if let baselineURL = arguments.baselineURL {
                baseline = try JSONDecoder().decode(
                    TuringQwenOptimizationBenchmarkReport.self,
                    from: Data(contentsOf: baselineURL)
                )
            } else {
                baseline = nil
            }

            let revision = arguments.gitRevision
                ?? discoverGitRevision(startingAt: arguments.bundleRoot)
            let report = await TuringQwenOptimizationBenchmarkRunner.run(
                options: TuringQwenOptimizationBenchmarkOptions(
                    modelRoot: arguments.modelRoot,
                    bundleRoot: arguments.bundleRoot,
                    suite: arguments.suite,
                    label: arguments.label,
                    gitRevision: revision,
                    baseline: baseline
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            try FileManager.default.createDirectory(
                at: arguments.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: arguments.outputURL, options: .atomic)
            print("Turing Qwen benchmark report: \(arguments.outputURL.path)")
            if report.completion.status == .fail {
                fputs("turing-qwen-benchmark: FAIL\n", stderr)
                Foundation.exit(EXIT_FAILURE)
            }
        } catch {
            fputs("turing-qwen-benchmark: \(error.localizedDescription)\n", stderr)
            fputs("\(Arguments.usage)\n", stderr)
            Foundation.exit(EX_USAGE)
        }
    }

    private static func discoverGitRevision(startingAt url: URL) -> String? {
        var candidate = url.standardizedFileURL
        for _ in 0..<10 {
            let gitMarker = candidate.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitMarker.path) {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", candidate.path, "rev-parse", "HEAD"]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { return nil }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    return String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    return nil
                }
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }
}

private struct Arguments {
    let modelRoot: URL
    let bundleRoot: URL
    let outputURL: URL
    let suite: TuringQwenBenchmarkSuite
    let baselineURL: URL?
    let label: String
    let gitRevision: String?
    let help: Bool

    static let usage = """
    Usage:
      turing-qwen-benchmark \\
        --model-root PATH \\
        --bundle-root PATH \\
        --output PATH \\
        [--suite quick|full] \\
        [--baseline PREVIOUS_REPORT.json] \\
        [--label LABEL] \\
        [--git-revision SHA]

    `quick` runs one representative short, medium, and long case. `full` runs
    the locked 10 short, 10 medium, 10 long, and three multi-minute scripts.
    A baseline report enables automatic before/after/delta comparison.
    """

    static func parse(_ raw: [String]) throws -> Self {
        if raw == ["--help"] || raw == ["-h"] {
            let placeholder = URL(fileURLWithPath: "/")
            return Self(
                modelRoot: placeholder,
                bundleRoot: placeholder,
                outputURL: placeholder,
                suite: .quick,
                baselineURL: nil,
                label: "help",
                gitRevision: nil,
                help: true
            )
        }

        var values: [String: String] = [:]
        var index = 0
        while index < raw.count {
            let key = raw[index]
            guard key.hasPrefix("--") else {
                throw CLIError("Unexpected positional argument: \(key)")
            }
            guard index + 1 < raw.count else {
                throw CLIError("Missing value for \(key)")
            }
            guard values[key] == nil else {
                throw CLIError("Duplicate argument: \(key)")
            }
            values[key] = raw[index + 1]
            index += 2
        }

        let allowed = Set([
            "--model-root",
            "--bundle-root",
            "--output",
            "--suite",
            "--baseline",
            "--label",
            "--git-revision"
        ])
        if let unknown = values.keys.first(where: { !allowed.contains($0) }) {
            throw CLIError("Unknown argument: \(unknown)")
        }
        guard let modelPath = values["--model-root"],
              let bundlePath = values["--bundle-root"],
              let outputPath = values["--output"] else {
            throw CLIError("--model-root, --bundle-root, and --output are required")
        }
        let suiteText = values["--suite"] ?? TuringQwenBenchmarkSuite.quick.rawValue
        guard let suite = TuringQwenBenchmarkSuite(rawValue: suiteText) else {
            throw CLIError("--suite must be quick or full")
        }
        let modelRoot = fileURL(modelPath)
        let bundleRoot = fileURL(bundlePath)
        let outputURL = fileURL(outputPath)
        guard FileManager.default.fileExists(atPath: modelRoot.path) else {
            throw CLIError("Model root does not exist: \(modelRoot.path)")
        }
        guard FileManager.default.fileExists(atPath: bundleRoot.path) else {
            throw CLIError("Bundle root does not exist: \(bundleRoot.path)")
        }
        if let baselinePath = values["--baseline"] {
            let baselineURL = fileURL(baselinePath)
            guard FileManager.default.fileExists(atPath: baselineURL.path) else {
                throw CLIError("Baseline report does not exist: \(baselineURL.path)")
            }
        }
        return Self(
            modelRoot: modelRoot,
            bundleRoot: bundleRoot,
            outputURL: outputURL,
            suite: suite,
            baselineURL: values["--baseline"].map(fileURL),
            label: values["--label"] ?? "current",
            gitRevision: values["--git-revision"],
            help: false
        )
    }

    private static func fileURL(_ value: String) -> URL {
        URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            .standardizedFileURL
    }
}

private struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
