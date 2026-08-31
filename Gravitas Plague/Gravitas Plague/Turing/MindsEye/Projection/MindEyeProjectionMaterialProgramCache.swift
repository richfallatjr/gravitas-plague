import Foundation
import RealityKit

/// Caches only compiled graph programs. Every target still receives its own
/// material instance and all entity-specific textures/matrices are overwritten
/// on that instance before it can be committed.
actor MindEyeProjectionMaterialProgramCache {
    struct Key: Hashable, Sendable {
        let graphVersion: String
        let importedPBRContractSHA256: String
        let diagnosticMode: MindEyeProjectionMaterialDiagnosticMode
    }

    private var programs: [Key: Result<ShaderGraphMaterial.Program, any Error>] = [:]
    private var inFlight: [Key: Task<ShaderGraphMaterial.Program, any Error>] = [:]

    func program(
        key: Key,
        build: @escaping @Sendable () async throws -> ShaderGraphMaterial.Program
    ) async throws -> ShaderGraphMaterial.Program {
        if let cached = programs[key] {
            return try cached.get()
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await build() }
        inFlight[key] = task
        do {
            let program = try await task.value
            programs[key] = .success(program)
            inFlight[key] = nil
            return program
        } catch {
            programs[key] = .failure(error)
            inFlight[key] = nil
            throw error
        }
    }
}
