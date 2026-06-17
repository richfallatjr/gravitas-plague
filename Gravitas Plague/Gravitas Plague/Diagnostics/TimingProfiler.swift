import Foundation

enum RuntimeDiagnostics {
    static let timingProfilerSummariesEnabled = false
    static let roomSkinningPlaneLogsEnabled = false
    static let hordeRuntimeSummariesEnabled = false
}

final class TimingProfiler {
    struct Metric {
        var totalSeconds: TimeInterval = 0
        var maxSeconds: TimeInterval = 0
        var count: Int = 0

        var averageSeconds: TimeInterval {
            guard count > 0 else {
                return 0
            }

            return totalSeconds / Double(count)
        }
    }

    private let label: String
    private let summaryIntervalSeconds: TimeInterval

    private var metrics: [String: Metric] = [:]
    private var counters: [String: Int] = [:]
    private var lastSummaryTime = TimingProfiler.now()

    init(
        label: String,
        summaryIntervalSeconds: TimeInterval = 1.0
    ) {
        self.label = label
        self.summaryIntervalSeconds = summaryIntervalSeconds
    }

    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    @discardableResult
    func measure<T>(
        _ name: String,
        _ body: () throws -> T
    ) rethrows -> T {
        let start = Self.now()

        do {
            let result = try body()
            record(
                name,
                duration: Self.now() - start
            )
            return result
        } catch {
            record(
                name,
                duration: Self.now() - start
            )
            throw error
        }
    }

    func record(
        _ name: String,
        startTime: TimeInterval
    ) {
        record(
            name,
            duration: Self.now() - startTime
        )
    }

    func record(
        _ name: String,
        duration: TimeInterval
    ) {
        var metric = metrics[name] ?? Metric()
        metric.totalSeconds += max(0, duration)
        metric.maxSeconds = max(metric.maxSeconds, duration)
        metric.count += 1
        metrics[name] = metric
    }

    func setCounter(
        _ name: String,
        _ value: Int
    ) {
        counters[name] = value
    }

    func incrementCounter(
        _ name: String,
        by amount: Int = 1
    ) {
        counters[name, default: 0] += amount
    }

    func printSummaryIfNeeded(
        now: TimeInterval = TimingProfiler.now(),
        force: Bool = false
    ) {
        guard force || now - lastSummaryTime >= summaryIntervalSeconds else {
            return
        }

        lastSummaryTime = now

        guard RuntimeDiagnostics.timingProfilerSummariesEnabled || force else {
            metrics.removeAll()
            return
        }

        let sortedMetrics = metrics.sorted {
            if $0.value.totalSeconds == $1.value.totalSeconds {
                return $0.key < $1.key
            }

            return $0.value.totalSeconds > $1.value.totalSeconds
        }

        let metricLines = sortedMetrics.prefix(12).map { name, metric in
            let totalMS = metric.totalSeconds * 1000
            let averageMS = metric.averageSeconds * 1000
            let maxMS = metric.maxSeconds * 1000

            return "  \(name): total=\(formatMS(totalMS)) avg=\(formatMS(averageMS)) max=\(formatMS(maxMS)) count=\(metric.count)"
        }

        let counterLines = counters
            .sorted { $0.key < $1.key }
            .map { "  \($0.key): \($0.value)" }

        print(
            """
            [TimingProfiler] summary
              label: \(label)
            counters:
            \(counterLines.isEmpty ? "  none" : counterLines.joined(separator: "\n"))
            timings:
            \(metricLines.isEmpty ? "  none" : metricLines.joined(separator: "\n"))
            """
        )

        metrics.removeAll()
    }

    private func formatMS(
        _ value: Double
    ) -> String {
        String(format: "%.3fms", value)
    }
}
