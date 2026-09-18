import Cmlx
import Foundation
import MachO

/// Compiled allocator provenance, independent of app-target configuration.
/// Full optimization flags must still come from captured compile commands.
public struct TuringMLXBuildFingerprint: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let translationUnit: String
    public let compiler: String
    public let architecture: String
    public let libcxxVersion: Int?
    public let hardeningMode: String
    public let internalAssertionsEnabled: Bool?
    public let optimized: Bool
    public let optimizeSize: Bool
    public let ndebug: Bool
    public let mlxTesting: Bool
    public let experimentID: String

    public static var current: Self {
        get throws {
            guard let pointer = mlx_turing_allocator_build_fingerprint_json() else {
                throw CocoaError(.coderReadCorrupt)
            }
            return try JSONDecoder().decode(Self.self, from: Data(String(cString: pointer).utf8))
        }
    }
}

/// UUIDs read from the running main image and Xcode's optional Debug dylib.
/// These identify installed code, not a source checkout or build directory.
public enum TuringMLXBinaryIdentity {
    public static var current: [String] {
        guard let executable = Bundle.main.executableURL?.standardizedFileURL else { return [] }
        let directory = executable.deletingLastPathComponent()
        var result: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index),
                  let header = _dyld_get_image_header(index) else { continue }
            let url = URL(fileURLWithPath: String(cString: name)).standardizedFileURL
            guard url == executable || (url.deletingLastPathComponent() == directory &&
                url.lastPathComponent.hasSuffix(".debug.dylib")) else { continue }
            guard header.pointee.magic == MH_MAGIC_64 else { continue }
            let raw = UnsafeRawPointer(header)
            let full = raw.assumingMemoryBound(to: mach_header_64.self).pointee
            var offset = MemoryLayout<mach_header_64>.size
            let end = offset + Int(full.sizeofcmds)
            for _ in 0..<full.ncmds {
                guard offset + MemoryLayout<load_command>.size <= end else { break }
                let command = raw.advanced(by: offset).assumingMemoryBound(to: load_command.self).pointee
                guard command.cmdsize >= MemoryLayout<load_command>.size,
                      offset + Int(command.cmdsize) <= end else { break }
                if command.cmd == LC_UUID && command.cmdsize >= MemoryLayout<uuid_command>.size {
                    let value = raw.advanced(by: offset).assumingMemoryBound(to: uuid_command.self).pointee
                    result.append(UUID(uuid: value.uuid).uuidString)
                }
                offset += Int(command.cmdsize)
            }
        }
        return Array(Set(result)).sorted()
    }
}
