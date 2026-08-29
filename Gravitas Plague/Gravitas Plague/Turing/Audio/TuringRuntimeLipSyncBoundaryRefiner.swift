import Foundation

nonisolated struct TuringRuntimeLipSyncRefinementResult: Sendable, Equatable {
    let phones: [TuringRuntimeLipSyncSourcePhoneSpan]
    let globalOffsetFrames: Int
    let degradedPhoneCount: Int
}

nonisolated struct TuringRuntimeLipSyncBoundaryRefiner: Sendable {
    func refine(
        phones: [TuringRuntimeLipSyncSourcePhoneSpan],
        finalPCM: [Float],
        sampleRate: Int,
        channelCount: Int,
        cancellation: TuringGeneratedSpeechAnalysisCancellationToken,
        deadline: ContinuousClock.Instant
    ) throws -> TuringRuntimeLipSyncRefinementResult {
        guard sampleRate > 0, channelCount > 0,
              finalPCM.count % channelCount == 0 else {
            throw TuringRuntimeLipSyncFailure.invalidInput("Boundary-refinement PCM is invalid.")
        }
        let sampleCount = finalPCM.count / channelCount
        let hop = max(1, sampleRate / 100)
        let window = max(hop, sampleRate * 25 / 1_000)
        var energy: [Double] = []
        var offset = 0
        while offset < sampleCount {
            try check(cancellation, deadline)
            let end = min(sampleCount, offset + window)
            var sum = 0.0
            var count = 0
            for frame in offset..<end {
                var mono = 0.0
                for channel in 0..<channelCount {
                    let value = finalPCM[frame * channelCount + channel]
                    mono += Double(value.isFinite ? max(-1, min(1, value)) : 0)
                }
                mono /= Double(channelCount)
                sum += mono * mono
                count += 1
            }
            energy.append(sqrt(sum / Double(max(1, count))))
            offset += hop
        }
        let sorted = energy.sorted()
        let floor = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count / 5)]
        let peak = sorted.last ?? floor
        let open = floor + max(0.0025, (peak - floor) * 0.16)
        let close = floor + max(0.0015, (peak - floor) * 0.10)
        var active = Array(repeating: false, count: energy.count)
        var gate = false
        for index in energy.indices {
            gate = gate ? energy[index] >= close : energy[index] >= open
            active[index] = gate
        }
        let padding = 2
        // Dilate from the undilated activity mask. Iterating the array while
        // mutating it would recursively spread a single active frame across
        // the entire segment.
        let undilatedActive = active
        for index in undilatedActive.indices where undilatedActive[index] {
            for neighbor in max(0, index - padding)...min(active.count - 1, index + padding) {
                active[neighbor] = true
            }
        }

        let bestOffset = (-12...12).max { lhs, rhs in
            let left = score(phones: phones, active: active, hop: hop, shift: lhs)
            let right = score(phones: phones, active: active, hop: hop, shift: rhs)
            if left != right { return left < right }
            if abs(lhs) != abs(rhs) { return abs(lhs) > abs(rhs) }
            return lhs > rhs
        } ?? 0
        let shiftSamples = bestOffset * hop
        var shifted = phones.map { phone in
            TuringRuntimeLipSyncSourcePhoneSpan(
                phone: phone.phone,
                pose: phone.pose,
                startSample: max(0, min(sampleCount, phone.startSample + shiftSamples)),
                endSampleExclusive: max(0, min(sampleCount, phone.endSampleExclusive + shiftSamples)),
                unknownAllPhoneLabel: phone.unknownAllPhoneLabel
            )
        }.filter { $0.startSample < $0.endSampleExclusive }

        if shifted.count > 1 {
            for index in 0..<(shifted.count - 1) {
                try check(cancellation, deadline)
                let boundary = min(shifted[index].endSampleExclusive, shifted[index + 1].startSample)
                let bin = boundary / hop
                var bestBin = bin
                var bestChange = -Double.infinity
                for candidate in max(1, bin - 2)...min(max(1, energy.count - 1), bin + 2) {
                    guard energy.indices.contains(candidate), energy.indices.contains(candidate - 1) else { continue }
                    let change = abs(energy[candidate] - energy[candidate - 1])
                    if change > bestChange { bestChange = change; bestBin = candidate }
                }
                let adjusted = min(sampleCount, max(1, bestBin * hop))
                let left = shifted[index]
                let right = shifted[index + 1]
                if adjusted > left.startSample,
                   adjusted < right.endSampleExclusive,
                   left.pose != .rest, right.pose != .rest {
                    shifted[index] = .init(
                        phone: left.phone,
                        pose: left.pose,
                        startSample: left.startSample,
                        endSampleExclusive: adjusted,
                        unknownAllPhoneLabel: left.unknownAllPhoneLabel
                    )
                    shifted[index + 1] = .init(
                        phone: right.phone,
                        pose: right.pose,
                        startSample: adjusted,
                        endSampleExclusive: right.endSampleExclusive,
                        unknownAllPhoneLabel: right.unknownAllPhoneLabel
                    )
                }
            }
        }
        var degraded = 0
        shifted = shifted.map { phone in
            guard phone.unknownAllPhoneLabel else { return phone }
            degraded += 1
            let midpoint = (phone.startSample + phone.endSampleExclusive) / 2 / hop
            let isActive = active.indices.contains(midpoint) && active[midpoint]
            return .init(
                phone: phone.phone,
                pose: isActive ? .wide : .rest,
                startSample: phone.startSample,
                endSampleExclusive: phone.endSampleExclusive,
                unknownAllPhoneLabel: true
            )
        }
        return .init(
            phones: shifted,
            globalOffsetFrames: bestOffset,
            degradedPhoneCount: degraded
        )
    }

    private func score(
        phones: [TuringRuntimeLipSyncSourcePhoneSpan],
        active: [Bool],
        hop: Int,
        shift: Int
    ) -> Int {
        var score = 0
        for phone in phones {
            let start = max(0, phone.startSample / hop + shift)
            let end = min(active.count, max(start + 1, (phone.endSampleExclusive + hop - 1) / hop + shift))
            guard start < end else { continue }
            let wantsSpeech = phone.pose != .rest
            for frame in start..<end where active.indices.contains(frame) {
                score += active[frame] == wantsSpeech ? 1 : -1
            }
        }
        return score
    }

    private func check(
        _ cancellation: TuringGeneratedSpeechAnalysisCancellationToken,
        _ deadline: ContinuousClock.Instant
    ) throws {
        if cancellation.isCancelled { throw TuringRuntimeLipSyncFailure.cancelled }
        if ContinuousClock.now >= deadline { throw TuringRuntimeLipSyncFailure.deadlineExceeded }
    }
}
