import AudioToolbox
import AVFAudio
import Darwin
import Foundation
import Synchronization

nonisolated struct TuringPCMStreamBufferSnapshot: Sendable, Equatable {
    let capacityFrames: Int
    let availableFrames: Int
    let renderedFrames: Int
    let underrunCount: Int
    let underrunFrames: Int
    let isSealed: Bool
    let isDrained: Bool
    let firstPCMHostTime: UInt64?
}

/// A fixed-capacity single-producer/single-consumer ring. The producer may
/// allocate and wait before calling `tryAppend`; `render` is the sole consumer
/// and performs only atomic operations and bounded memory copies/zero fills.
nonisolated final class TuringPCMStreamBuffer: @unchecked Sendable {
    static let sampleRate =
        TuringPCMStreamConfiguration.realityKitSampleRate

    let capacityFrames: Int
    let startupWatermarkFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private let readFrame = Atomic<Int>(0)
    private let writeFrame = Atomic<Int>(0)
    private let sealed = Atomic<Bool>(false)
    private let drained = Atomic<Bool>(false)
    private let firstPCMHostTime = Atomic<UInt64>(0)
    private let renderedFrames = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)
    private let underrunFrames = Atomic<Int>(0)

    init(configuration: TuringPCMStreamConfiguration) throws {
        try configuration.validate()
        capacityFrames = configuration.outputCapacityFrames
        startupWatermarkFrames =
            configuration.startupWatermarkFrames
        storage = .allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        storage.deinitialize(count: capacityFrames)
        storage.deallocate()
    }

    var availableFrames: Int {
        let read = readFrame.load(ordering: .acquiring)
        let write = writeFrame.load(ordering: .acquiring)
        return max(0, write - read)
    }

    var hasReachedStartupWatermark: Bool {
        availableFrames >= startupWatermarkFrames
    }

    var isSealed: Bool {
        sealed.load(ordering: .acquiring)
    }

    var isDrained: Bool {
        drained.load(ordering: .acquiring)
    }

    /// Returns false without consuming any input when the complete append does
    /// not fit. This keeps backpressure outside the real-time callback and
    /// makes a sequence either wholly accepted or wholly rejected.
    func tryAppend(_ samples: ContiguousArray<Float>) -> Bool {
        guard !samples.isEmpty else { return true }
        guard !sealed.load(ordering: .acquiring),
              samples.count <= capacityFrames else {
            return false
        }

        let write = writeFrame.load(ordering: .relaxed)
        let read = readFrame.load(ordering: .acquiring)
        let occupied = max(0, write - read)
        guard samples.count <= capacityFrames - occupied else {
            return false
        }

        samples.withUnsafeBufferPointer { source in
            guard let sourceAddress = source.baseAddress else { return }
            let storageIndex = write % capacityFrames
            let firstCount = min(
                samples.count,
                capacityFrames - storageIndex
            )
            storage.advanced(by: storageIndex).update(
                from: sourceAddress,
                count: firstCount
            )
            let secondCount = samples.count - firstCount
            if secondCount > 0 {
                storage.update(
                    from: sourceAddress.advanced(by: firstCount),
                    count: secondCount
                )
            }
        }
        writeFrame.store(
            write + samples.count,
            ordering: .releasing
        )
        return true
    }

    func seal() {
        sealed.store(true, ordering: .releasing)
        if availableFrames == 0 {
            drained.store(true, ordering: .releasing)
        }
    }

    func snapshot() -> TuringPCMStreamBufferSnapshot {
        let read = readFrame.load(ordering: .acquiring)
        let write = writeFrame.load(ordering: .acquiring)
        let firstHostTime = firstPCMHostTime.load(
            ordering: .acquiring
        )
        return TuringPCMStreamBufferSnapshot(
            capacityFrames: capacityFrames,
            availableFrames: max(0, write - read),
            renderedFrames: renderedFrames.load(
                ordering: .acquiring
            ),
            underrunCount: underrunCount.load(
                ordering: .acquiring
            ),
            underrunFrames: underrunFrames.load(
                ordering: .acquiring
            ),
            isSealed: sealed.load(ordering: .acquiring),
            isDrained: drained.load(ordering: .acquiring),
            firstPCMHostTime: firstHostTime == 0
                ? nil
                : firstHostTime
        )
    }

    @inline(__always)
    func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let requestedFrames = Int(frameCount)
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard requestedFrames > 0,
              !buffers.isEmpty,
              let firstData = buffers[0].mData else {
            isSilence.pointee = true
            return noErr
        }

        let firstCapacity = Int(buffers[0].mDataByteSize) /
            MemoryLayout<Float>.stride
        let writableFrames = min(requestedFrames, firstCapacity)
        guard writableFrames > 0 else {
            isSilence.pointee = true
            return noErr
        }

        for index in buffers.indices {
            guard let data = buffers[index].mData else { continue }
            memset(data, 0, Int(buffers[index].mDataByteSize))
        }

        let read = readFrame.load(ordering: .relaxed)
        let write = writeFrame.load(ordering: .acquiring)
        let available = max(0, write - read)
        let copiedFrames = min(writableFrames, available)

        if copiedFrames > 0 {
            let destination = firstData.assumingMemoryBound(
                to: Float.self
            )
            let storageIndex = read % capacityFrames
            let firstCount = min(
                copiedFrames,
                capacityFrames - storageIndex
            )
            destination.update(
                from: storage.advanced(by: storageIndex),
                count: firstCount
            )
            let secondCount = copiedFrames - firstCount
            if secondCount > 0 {
                destination.advanced(by: firstCount).update(
                    from: storage,
                    count: secondCount
                )
            }

            // Mono is the only supported layout. Mirror into any unexpected
            // additional output buffers without advancing the stream twice.
            if buffers.count > 1 {
                var index = 1
                while index < buffers.count {
                    guard let data = buffers[index].mData else {
                        index += 1
                        continue
                    }
                    let capacity = Int(
                        buffers[index].mDataByteSize
                    ) / MemoryLayout<Float>.stride
                    let mirrorCount = min(copiedFrames, capacity)
                    data.assumingMemoryBound(to: Float.self).update(
                        from: destination,
                        count: mirrorCount
                    )
                    index += 1
                }
            }

            let newRead = read + copiedFrames
            readFrame.store(newRead, ordering: .releasing)
            renderedFrames.wrappingAdd(
                copiedFrames,
                ordering: .relaxed
            )
            if firstPCMHostTime.load(ordering: .relaxed) == 0 {
                let flags = timestamp.pointee.mFlags
                let hostTime =
                    flags.contains(.hostTimeValid)
                    ? timestamp.pointee.mHostTime
                    : mach_absolute_time()
                firstPCMHostTime.store(
                    max(1, hostTime),
                    ordering: .releasing
                )
            }
            if sealed.load(ordering: .acquiring),
               newRead == write {
                drained.store(true, ordering: .releasing)
            }
        } else if sealed.load(ordering: .acquiring) {
            drained.store(true, ordering: .releasing)
        }

        if copiedFrames < writableFrames,
           !sealed.load(ordering: .acquiring) {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            underrunFrames.wrappingAdd(
                writableFrames - copiedFrames,
                ordering: .relaxed
            )
        }
        isSilence.pointee = ObjCBool(copiedFrames == 0)
        return noErr
    }
}
