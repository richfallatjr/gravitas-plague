import CryptoKit
import Foundation

nonisolated enum TuringRuntimeLipSyncSHA256 {
    static func text(_ value: String) -> String {
        hex(SHA256.hash(data: Data(value.utf8)))
    }

    static func file(_ url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    static func tree(_ root: URL) throws -> String {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw TuringRuntimeLipSyncFailure.resourceInvalid("Cannot enumerate resource tree.")
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(url)
            }
        }
        files.sort { relativePath($0, root: root) < relativePath($1, root: root) }
        var hasher = SHA256()
        for url in files {
            hasher.update(data: Data(relativePath(url, root: root).utf8))
            hasher.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }
        return hex(hasher.finalize())
    }

    static func sanitizedPCM(
        _ samples: ContiguousArray<Float>,
        sampleRate: Int,
        channelCount: Int
    ) -> String {
        var hasher = SHA256()
        var rate = Int64(sampleRate).littleEndian
        var channels = Int64(channelCount).littleEndian
        withUnsafeBytes(of: &rate) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: &channels) { hasher.update(bufferPointer: $0) }
        samples.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hex(hasher.finalize())
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
