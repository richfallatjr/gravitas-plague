import Darwin
import Foundation

struct TuringQwenNativeSafetensorsFileIdentity: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let byteCount: Int64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw TuringQwenNativeError.invalidSafetensors("Safetensors source must be a regular file.")
        }
        device = info.st_dev
        inode = info.st_ino
        byteCount = info.st_size
        modificationSeconds = info.st_mtimespec.tv_sec
        modificationNanoseconds = info.st_mtimespec.tv_nsec
        changeSeconds = info.st_ctimespec.tv_sec
        changeNanoseconds = info.st_ctimespec.tv_nsec
    }

    static func capture(descriptor: Int32) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw TuringQwenNativeError.invalidSafetensors("Cannot inspect safetensors descriptor (errno \(errno)).")
        }
        return try Self(info)
    }
}

/// Cumulative candidate-reader I/O only; excludes the separate index-header
/// FileHandle. Name tracking is bounded to 64 identities, with overflow explicit.
/// Conversion count covers existing CPU row decoding, not MLX device casts.
public struct TuringQwenNativeSafetensorsIOCounters: Sendable, Equatable, Codable {
    public var opens: UInt64 = 0
    public var readCalls: UInt64 = 0
    public var bytesRead: UInt64 = 0
    public var interruptedReads: UInt64 = 0
    public var tensorRequests: UInt64 = 0
    public var rowRequests: UInt64 = 0
    public var repeatedTensorRequests: UInt64 = 0
    public var untrackedTensorRequests: UInt64 = 0
    public var float32ConvertedElements: UInt64 = 0
}

/// Candidate-only, decoder-owned descriptor. Reads copy into owned Data; no
/// mmap, tensor residency, precision, or zero-copy behavior is introduced.
final class TuringQwenNativePositionalSafetensorsFile: @unchecked Sendable {
    typealias ReadOperation = @Sendable (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int
    let descriptor: Int32
    private let url: URL
    private let identity: TuringQwenNativeSafetensorsFileIdentity
    private let readOperation: ReadOperation
    private let counterLock = NSLock()
    private var counters = TuringQwenNativeSafetensorsIOCounters()
    private var observedTensorNames = Set<String>()

    init(
        url: URL,
        expectedIdentity: TuringQwenNativeSafetensorsFileIdentity,
        readOperation: @escaping ReadOperation = { Darwin.pread($0, $1, $2, $3) }
    ) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else {
            throw TuringQwenNativeError.invalidSafetensors("Cannot open safetensors source (errno \(errno)).")
        }
        do {
            let actual = try TuringQwenNativeSafetensorsFileIdentity.capture(descriptor: fd)
            guard actual == expectedIdentity else {
                throw TuringQwenNativeError.invalidSafetensors("Safetensors file changed after index loading.")
            }
            descriptor = fd
            self.url = url
            identity = actual
            self.readOperation = readOperation
            counters.opens = 1
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    /// Validate at each tensor/row-family boundary, not for every codebook row.
    /// fstat rejects in-place mutation; stat also rejects replacing the path
    /// while the original descriptor remains readable.
    func validateIdentity() throws {
        let current = try TuringQwenNativeSafetensorsFileIdentity.capture(descriptor: descriptor)
        var pathInfo = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.fstatat(AT_FDCWD, $0, &pathInfo, 0) } ?? -1
        }
        guard status == 0, current == identity,
              try TuringQwenNativeSafetensorsFileIdentity(pathInfo) == identity else {
            throw TuringQwenNativeError.invalidSafetensors("Safetensors file identity changed during decoder residency.")
        }
    }

    func readExactly(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= UInt64(Int64.max),
              UInt64(count) <= UInt64(Int64.max) - offset,
              offset + UInt64(count) <= UInt64(identity.byteCount) else {
            throw TuringQwenNativeError.invalidSafetensors("Safetensors read exceeds file bounds or offset range.")
        }
        try Task.checkCancellation()
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var consumed = 0
            while consumed < count {
                try Task.checkCancellation()
                let received = readOperation(
                    descriptor, base.advanced(by: consumed), count - consumed,
                    off_t(offset + UInt64(consumed)))
                let readError = errno
                counterLock.withLock {
                    counters.readCalls += 1
                    if received > 0 { counters.bytesRead += UInt64(received) }
                    if received < 0 && readError == EINTR { counters.interruptedReads += 1 }
                }
                if received < 0 && readError == EINTR { continue }
                guard received > 0, received <= count - consumed else {
                    throw TuringQwenNativeError.invalidSafetensors(
                        received == 0 ? "Safetensors source truncated during positional read."
                        : "Safetensors positional read failed (errno \(readError)).")
                }
                consumed += received
            }
        }
        return result
    }

    func recordRequest(name: String, rows: Bool, convertedElements: Int = 0) {
        counterLock.withLock {
            if rows { counters.rowRequests += 1 } else { counters.tensorRequests += 1 }
            if observedTensorNames.contains(name) {
                counters.repeatedTensorRequests += 1
            } else if observedTensorNames.count < 64 {
                observedTensorNames.insert(name)
            } else {
                counters.untrackedTensorRequests += 1
            }
            counters.float32ConvertedElements += UInt64(max(0, convertedElements))
        }
    }

    func snapshot() -> TuringQwenNativeSafetensorsIOCounters {
        counterLock.withLock { counters }
    }
}
