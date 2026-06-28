import Foundation

enum TuringJSONSanitizer {
    nonisolated static func extractSingleTopLevelObject(from raw: String) throws -> Data {
        let unfenced = stripMarkdownFences(raw)

        guard let start = unfenced.firstIndex(of: "{") else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "No JSON object start found."
            )
        }

        var depth = 0
        var inString = false
        var isEscaped = false
        var end: String.Index?
        var index = start

        while index < unfenced.endIndex {
            let character = unfenced[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
            }

            index = unfenced.index(after: index)
        }

        guard let end else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "No balanced top-level JSON object found."
            )
        }

        let json = String(unfenced[start...end])
        guard let data = json.data(using: .utf8) else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "Extracted JSON is not UTF-8."
            )
        }

        return data
    }

    nonisolated private static func stripMarkdownFences(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else {
            return raw
        }

        var lines = trimmed.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)

        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.hasPrefix("```") == true {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }
}

protocol TuringJSONRepairService: Sendable {
    func repairJSON(
        invalidPayload: String,
        errorDescription: String
    ) async throws -> String
}

enum TuringJSONGate {
    nonisolated static func decodeStrict<T: Decodable>(
        _ type: T.Type,
        raw: String,
        repairService: TuringJSONRepairService? = nil
    ) async throws -> T {
        do {
            let data = try TuringJSONSanitizer.extractSingleTopLevelObject(
                from: raw
            )
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            guard let repairService else {
                throw error
            }

            let repaired = try await repairService.repairJSON(
                invalidPayload: raw,
                errorDescription: error.localizedDescription
            )

            do {
                let data = try TuringJSONSanitizer.extractSingleTopLevelObject(
                    from: repaired
                )
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw TuringRuntimeError.foundationRepairFailed(
                    error.localizedDescription
                )
            }
        }
    }
}
