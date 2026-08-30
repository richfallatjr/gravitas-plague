import Foundation

public struct TuringQwenNativeGPUAdmissionSnapshot: Sendable, Equatable {
    public let mode: TuringQwenNativeGPUAdmissionMode
    public let activeGenerationLeaseCount: Int
    public let activeDecodeLeaseCount: Int
    public let queuedGenerationCount: Int
    public let queuedDecodeCount: Int
    public let peakActiveGenerationLeaseCount: Int
    public let peakQueuedGenerationCount: Int
    public let peakQueuedDecodeCount: Int
    public let generationAcquisitionCount: Int
    public let decodeAcquisitionCount: Int
    public let blockedGenerationAcquisitionCount: Int
    public let blockedDecodeAcquisitionCount: Int
    public let totalGenerationWaitNanoseconds: UInt64
    public let maximumGenerationWaitNanoseconds: UInt64
    public let totalDecodeWaitNanoseconds: UInt64
    public let maximumDecodeWaitNanoseconds: UInt64
    public let invariantViolationCount: Int
}
