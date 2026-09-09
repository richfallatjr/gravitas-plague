import Foundation

actor TuringPCMStreamProducerStore {
    private static let backpressurePollInterval: Duration =
        .milliseconds(5)
    private static let terminalMetricLimit = 16

    private final class Session {
        let handle: TuringAudioPlaybackHandle
        let configuration: TuringPCMStreamConfiguration
        let buffer: TuringPCMStreamBuffer
        let converter: TuringPCMStreamRateConverter
        var nextSequenceNumber = 0
        var nextSourceFrameOffset = 0
        var appendedSourceFrames = 0
        var convertedOutputFrames = 0
        var appendInProgress = false
        var sealed = false

        init(
            handle: TuringAudioPlaybackHandle,
            configuration: TuringPCMStreamConfiguration,
            buffer: TuringPCMStreamBuffer,
            converter: TuringPCMStreamRateConverter
        ) {
            self.handle = handle
            self.configuration = configuration
            self.buffer = buffer
            self.converter = converter
        }
    }

    private var sessions: [UUID: Session] = [:]
    private var terminalMetrics: [UUID: TuringPCMStreamMetrics] = [:]
    private var terminalMetricOrder: [UUID] = []

    func install(
        handle: TuringAudioPlaybackHandle,
        configuration: TuringPCMStreamConfiguration,
        buffer: TuringPCMStreamBuffer,
        converter: TuringPCMStreamRateConverter
    ) throws {
        guard sessions[handle.id] == nil else {
            throw TuringPCMStreamError.invalidConfiguration(
                "Duplicate PCM stream handle."
            )
        }
        terminalMetrics.removeValue(forKey: handle.id)
        terminalMetricOrder.removeAll { $0 == handle.id }
        sessions[handle.id] = Session(
            handle: handle,
            configuration: configuration,
            buffer: buffer,
            converter: converter
        )
    }

    func containsActive(
        _ handle: TuringAudioPlaybackHandle
    ) -> Bool {
        guard let session = sessions[handle.id] else { return false }
        return session.handle == handle
    }

    func append(
        _ chunk: TuringPCMStreamChunk,
        to handle: TuringAudioPlaybackHandle
    ) async throws -> TuringPCMStreamAppendReceipt {
        let session = try requireActive(handle)
        try validate(chunk, for: session)
        guard !session.appendInProgress else {
            throw TuringPCMStreamError.appendAlreadyInProgress
        }
        session.appendInProgress = true
        defer { session.appendInProgress = false }

        let converted = try session.converter.convert(chunk.samples)
        guard converted.count <= session.buffer.capacityFrames else {
            throw TuringPCMStreamError.chunkExceedsCapacity(
                frameCount: converted.count,
                capacityFrames: session.buffer.capacityFrames
            )
        }
        try await appendWithBackpressure(
            converted,
            session: session
        )

        session.nextSequenceNumber += 1
        session.nextSourceFrameOffset += chunk.sourceFrameCount
        session.appendedSourceFrames += chunk.sourceFrameCount
        session.convertedOutputFrames += converted.count

        return TuringPCMStreamAppendReceipt(
            acceptedSequenceNumber: chunk.sequenceNumber,
            acceptedSourceFrameOffset: chunk.sourceFrameOffset,
            acceptedSourceFrameCount: chunk.sourceFrameCount,
            convertedOutputFrameCount: converted.count,
            bufferedSeconds: Double(session.buffer.availableFrames) /
                Double(TuringPCMStreamBuffer.sampleRate),
            playbackStartRequested:
                session.buffer.hasReachedStartupWatermark
        )
    }

    func seal(
        _ handle: TuringAudioPlaybackHandle
    ) async throws {
        let session = try requireActive(handle)
        guard !session.sealed else { return }
        guard !session.appendInProgress else {
            throw TuringPCMStreamError.appendAlreadyInProgress
        }
        guard session.appendedSourceFrames > 0 else {
            throw TuringPCMStreamError.invalidChunk(
                "A stream cannot be sealed before receiving PCM."
            )
        }
        session.appendInProgress = true
        defer { session.appendInProgress = false }

        let tail = try session.converter.finish()
        guard tail.count <= session.buffer.capacityFrames else {
            throw TuringPCMStreamError.chunkExceedsCapacity(
                frameCount: tail.count,
                capacityFrames: session.buffer.capacityFrames
            )
        }
        try await appendWithBackpressure(tail, session: session)
        session.convertedOutputFrames += tail.count
        session.sealed = true
        session.buffer.seal()
    }

    func metrics(
        _ handle: TuringAudioPlaybackHandle
    ) -> TuringPCMStreamMetrics? {
        if let session = sessions[handle.id],
           session.handle == handle {
            return makeMetrics(session)
        }
        return terminalMetrics[handle.id]
    }

    func finish(_ handle: TuringAudioPlaybackHandle) {
        guard let session = sessions.removeValue(forKey: handle.id),
              session.handle == handle else {
            return
        }
        retainTerminalMetrics(makeMetrics(session), id: handle.id)
    }

    func cancel(_ handle: TuringAudioPlaybackHandle) {
        guard let session = sessions.removeValue(forKey: handle.id),
              session.handle == handle else {
            return
        }
        session.buffer.seal()
        retainTerminalMetrics(makeMetrics(session), id: handle.id)
    }

    func cancelAll() {
        let active = sessions
        sessions.removeAll(keepingCapacity: false)
        for (id, session) in active {
            session.buffer.seal()
            retainTerminalMetrics(makeMetrics(session), id: id)
        }
    }

    private func requireActive(
        _ handle: TuringAudioPlaybackHandle
    ) throws -> Session {
        guard let session = sessions[handle.id],
              session.handle == handle else {
            throw TuringPCMStreamError.staleHandle
        }
        return session
    }

    private func validate(
        _ chunk: TuringPCMStreamChunk,
        for session: Session
    ) throws {
        guard !session.sealed else {
            throw TuringPCMStreamError.appendAfterSeal
        }
        guard chunk.sequenceNumber == session.nextSequenceNumber else {
            throw TuringPCMStreamError.sequenceMismatch(
                expected: session.nextSequenceNumber,
                actual: chunk.sequenceNumber
            )
        }
        guard chunk.sourceFrameOffset == session.nextSourceFrameOffset else {
            throw TuringPCMStreamError.frameOffsetMismatch(
                expected: session.nextSourceFrameOffset,
                actual: chunk.sourceFrameOffset
            )
        }
        guard chunk.sampleRate == session.configuration.sourceSampleRate else {
            throw TuringPCMStreamError.invalidChunk(
                "sampleRate \(chunk.sampleRate) does not match \(session.configuration.sourceSampleRate)."
            )
        }
        guard chunk.channelCount == session.configuration.channelCount,
              chunk.channelCount == 1 else {
            throw TuringPCMStreamError.invalidChunk(
                "channelCount \(chunk.channelCount) does not match the mono stream."
            )
        }
        guard !chunk.samples.isEmpty,
              chunk.samples.count % chunk.channelCount == 0 else {
            throw TuringPCMStreamError.invalidChunk(
                "samples must contain complete, nonempty source frames."
            )
        }
    }

    private func appendWithBackpressure(
        _ samples: ContiguousArray<Float>,
        session: Session
    ) async throws {
        guard !samples.isEmpty else { return }
        while !session.buffer.tryAppend(samples) {
            guard let current = sessions[session.handle.id],
                  current === session,
                  !session.sealed else {
                throw TuringPCMStreamError.staleHandle
            }
            try await Task.sleep(
                for: Self.backpressurePollInterval
            )
        }
    }

    private func makeMetrics(
        _ session: Session
    ) -> TuringPCMStreamMetrics {
        let snapshot = session.buffer.snapshot()
        let sampleRate = Double(TuringPCMStreamBuffer.sampleRate)
        return TuringPCMStreamMetrics(
            capacitySeconds: Double(snapshot.capacityFrames) /
                sampleRate,
            startupWatermarkSeconds:
                Double(session.buffer.startupWatermarkFrames) /
                sampleRate,
            bufferedSeconds: Double(snapshot.availableFrames) /
                sampleRate,
            appendedSourceFrames: session.appendedSourceFrames,
            convertedOutputFrames: session.convertedOutputFrames,
            renderedOutputFrames: snapshot.renderedFrames,
            underrunCount: snapshot.underrunCount,
            underrunFrames: snapshot.underrunFrames,
            nextExpectedSequenceNumber: session.nextSequenceNumber,
            nextExpectedSourceFrameOffset:
                session.nextSourceFrameOffset,
            isSealed: snapshot.isSealed,
            isDrained: snapshot.isDrained,
            hasRenderedPCM: snapshot.firstPCMHostTime != nil
        )
    }

    private func retainTerminalMetrics(
        _ metrics: TuringPCMStreamMetrics,
        id: UUID
    ) {
        terminalMetrics[id] = metrics
        terminalMetricOrder.removeAll { $0 == id }
        terminalMetricOrder.append(id)
        while terminalMetricOrder.count > Self.terminalMetricLimit {
            let removed = terminalMetricOrder.removeFirst()
            terminalMetrics.removeValue(forKey: removed)
        }
    }
}
