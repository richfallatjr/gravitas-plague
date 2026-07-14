import Foundation

enum Battle01EventLog {
    static func emit(
        _ event: String,
        instanceID: UUID,
        state: Battle01State,
        fields: [(String, String)] = []
    ) {
        let details = fields.map { "  \($0.0): \($0.1)" }.joined(separator: "\n")
        print("""
        [Battle01] \(event)
          battleInstanceID: \(instanceID.uuidString)
          battleID: prologue.battle01.mrsDempsey
          state: \(state.rawValue)\(details.isEmpty ? "" : "\n\(details)")
        """)
    }
}
