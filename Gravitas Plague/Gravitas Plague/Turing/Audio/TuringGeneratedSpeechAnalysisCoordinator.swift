import Foundation

nonisolated enum TuringGeneratedSpeechAnalysisSubmission: Sendable {
    case accepted(TuringGeneratedSpeechAnalysisTicket)
    case rejected(TuringGeneratedSpeechAnalysisUnavailableReason)
}

actor TuringGeneratedSpeechAnalysisCoordinator {
    static let shared = TuringGeneratedSpeechAnalysisCoordinator()

    private struct Job: Sendable {
        let ticket: TuringGeneratedSpeechAnalysisTicket
        let samples: [Float]
        let sampleRate: Int
        let channelCount: Int
        let queuedAt: ContinuousClock.Instant
        let cancellation: TuringGeneratedSpeechAnalysisCancellationToken

        var retainedBytes: Int { samples.count * MemoryLayout<Float>.stride }
    }

    private let worker: TuringSerialGeneratedSpeechAnalysisWorker
    private let policy: TuringGeneratedSpeechAnalysisPolicy
    private let eventHub: TuringGeneratedSpeechAnalysisEventHub
    private var queued: [Job] = []
    private var running: Job?
    private var runningTask: Task<Void, Never>?
    private var retainedPCMBytes = 0

    init(
        worker: TuringSerialGeneratedSpeechAnalysisWorker = .init(),
        policy: TuringGeneratedSpeechAnalysisPolicy = .production,
        eventHub: TuringGeneratedSpeechAnalysisEventHub = .shared
    ) {
        self.worker = worker
        self.policy = policy
        self.eventHub = eventHub
    }

    func events() async -> AsyncStream<TuringGeneratedSpeechAnalysisEvent> {
        await eventHub.events()
    }

    func submit(
        runID: String,
        segmentIndex: Int,
        samples: [Float],
        sampleRate: Int,
        channelCount: Int
    ) async -> TuringGeneratedSpeechAnalysisSubmission {
        guard !samples.isEmpty, sampleRate > 0, channelCount > 0,
              samples.count % channelCount == 0 else {
            return .rejected(.invalidInput)
        }
        guard queued.count < policy.maximumQueuedJobCount else {
            return .rejected(.queueCapacityExceeded)
        }
        let bytes = samples.count * MemoryLayout<Float>.stride
        guard retainedPCMBytes + bytes <= policy.maximumRetainedPCMBytes else {
            return .rejected(.retainedPCMBudgetExceeded)
        }
        let identity = TuringGeneratedSpeechAnalysisIdentity(
            ticketID: UUID(),
            runID: runID,
            segmentIndex: segmentIndex
        )
        let ticket = TuringGeneratedSpeechAnalysisTicket(
            identity: identity,
            resultBox: TuringGeneratedSpeechAnalysisResultBox()
        )
        let job = Job(
            ticket: ticket,
            samples: samples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            queuedAt: .now,
            cancellation: TuringGeneratedSpeechAnalysisCancellationToken()
        )
        retainedPCMBytes += job.retainedBytes
        queued.append(job)
        await eventHub.publish(.queued(identity: identity))
        print(
            "[TuringGeneratedSpeech] queued ticket=\(identity.ticketID.uuidString) " +
                "segmentIndex=\(segmentIndex) retainedPCMBytes=\(retainedPCMBytes)"
        )
        launchNextIfNeeded()
        return .accepted(ticket)
    }

    func cancel(
        identity: TuringGeneratedSpeechAnalysisIdentity,
        reason: String
    ) async {
        if let index = queued.firstIndex(where: { $0.ticket.identity == identity }) {
            let job = queued.remove(at: index)
            retainedPCMBytes -= job.retainedBytes
            job.cancellation.cancel()
            job.ticket.resultBox.store(.unavailable(reason: .cancelled))
            await eventHub.publish(.cancelled(identity: identity, reason: reason))
            return
        }
        if running?.ticket.identity == identity {
            running?.cancellation.cancel()
        }
    }

    func cancelRun(runID: String, reason: String) async {
        let identities = queued
            .filter { $0.ticket.identity.runID == runID }
            .map { $0.ticket.identity }
        for identity in identities { await cancel(identity: identity, reason: reason) }
        if let identity = running?.ticket.identity, identity.runID == runID {
            await cancel(identity: identity, reason: reason)
        }
    }

    private func launchNextIfNeeded() {
        guard running == nil, !queued.isEmpty else { return }
        let job = queued.removeFirst()
        running = job
        let worker = worker
        let policy = policy
        let hub = eventHub
        runningTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await worker.analyze(
                processedAudio: job.samples,
                sampleRate: job.sampleRate,
                channelCount: job.channelCount,
                queuedAt: job.queuedAt,
                policy: policy,
                cancellation: job.cancellation,
                started: { queueDelay in
                    Task {
                        await hub.publish(.started(
                            identity: job.ticket.identity,
                            queueDelayNanoseconds: queueDelay
                        ))
                    }
                }
            )
            await self?.complete(job: job, workerResult: result)
        }
    }

    private func complete(
        job: Job,
        workerResult: TuringGeneratedSpeechAnalysisWorkerResult
    ) async {
        guard running?.ticket.identity == job.ticket.identity else { return }
        retainedPCMBytes -= job.retainedBytes
        running = nil
        runningTask = nil
        job.ticket.resultBox.store(workerResult.result)
        switch workerResult.result {
        case .ready(let analysis):
            await eventHub.publish(.ready(
                identity: job.ticket.identity,
                analysis: analysis,
                timing: workerResult.timing
            ))
        case .unavailable(let reason):
            await eventHub.publish(.unavailable(
                identity: job.ticket.identity,
                reason: reason,
                timing: workerResult.timing
            ))
        }
        launchNextIfNeeded()
    }
}
