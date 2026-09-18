import Foundation
import CryptoKit

/// The deliberately narrow JSON contract shared with qwen_build_provenance.py.
/// Foundation's `.sortedKeys` uses collation (case/numeric/punctuation), not
/// Python's literal Unicode ordering, so it cannot define this inventory hash.
enum TuringQwenPayloadInventory {
    struct Entry: Codable, Sendable {
        let bytes: Int
        let sha256: String
    }

    static func canonicalData(_ files: [String: Entry]) -> Data {
        let paths = files.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let members = paths.map { path in
            let entry = files[path]!
            return "\(quoted(path)):{\"bytes\":\(entry.bytes),\"sha256\":\(quoted(entry.sha256))}"
        }
        return Data(("{" + members.joined(separator: ",") + "}").utf8)
    }

    static func fingerprint(_ files: [String: Entry]) -> String {
        SHA256.hash(data: canonicalData(files)).map { String(format: "%02x", $0) }.joined()
    }

    /// Exact json.dumps(ensure_ascii=False, separators=(",", ":")) string
    /// escaping. In particular, slash and non-ASCII scalars remain literal.
    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0c: result += "\\f"
            case 0x0a: result += "\\n"
            case 0x0d: result += "\\r"
            case 0x09: result += "\\t"
            case 0...0x1f: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
