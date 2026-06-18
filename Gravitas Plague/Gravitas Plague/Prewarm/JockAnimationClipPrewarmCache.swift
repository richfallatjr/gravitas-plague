import Foundation

actor JockAnimationClipPrewarmCache {
    static let shared = JockAnimationClipPrewarmCache()

    private var runtimeLibrary: HordePrewarmedAnimationLibrary?
    private var loadingTask: Task<HordePrewarmedAnimationLibrary, Error>?

    func isReady(
        clipID: String
    ) -> Bool {
        runtimeLibrary?.clipsByID[clipID] != nil
    }

    func requireRuntimeLibraryReady() throws -> HordePrewarmedAnimationLibrary {
        guard let runtimeLibrary else {
            throw HordePrewarmError.animationPrewarmFailed(
                clipID: "runtime_library",
                reason: "Runtime animation library has not been prewarmed."
            )
        }

        return runtimeLibrary
    }

    func preloadRuntimeLibrary(
        requiredClipIDs: Set<String>
    ) async throws -> HordePrewarmedAnimationLibrary {
        if let runtimeLibrary {
            try validateRequiredClips(
                requiredClipIDs,
                in: runtimeLibrary
            )

            return runtimeLibrary
        }

        if let loadingTask {
            let loaded = try await loadingTask.value
            try validateRequiredClips(
                requiredClipIDs,
                in: loaded
            )

            runtimeLibrary = loaded

            return loaded
        }

        let task = Task.detached(priority: .utility) {
            try JockAnimationLibraryLoader.loadPrewarmedRuntimeLibrary()
        }

        loadingTask = task

        do {
            let loaded = try await task.value

            try validateRequiredClips(
                requiredClipIDs,
                in: loaded
            )

            runtimeLibrary = loaded
            loadingTask = nil

            print(
                """
                [AnimationPrewarm] runtime library ready
                  clipCount: \(loaded.clipsByID.count)
                  requiredClipCount: \(requiredClipIDs.count)
                  noDiskReadAtSpawn: true
                """
            )

            return loaded
        } catch {
            loadingTask = nil
            throw error
        }
    }

    func releaseAll() {
        loadingTask?.cancel()
        runtimeLibrary = nil
        loadingTask = nil

        print("[AnimationPrewarm] released runtime animation cache")
    }

    private func validateRequiredClips(
        _ clipIDs: Set<String>,
        in library: HordePrewarmedAnimationLibrary
    ) throws {
        for clipID in clipIDs.sorted() where library.clipsByID[clipID] == nil {
            print(
                """
                [AnimationPrewarm] ERROR required clip missing from prewarmed cache
                  clipID: \(clipID)
                  fallback: false
                """
            )

            throw HordePrewarmError.missingAnimationClip(
                clipID: clipID
            )
        }
    }
}

extension JockAnimationLibraryLoader {
    static func loadPrewarmedRuntimeLibrary() throws -> HordePrewarmedAnimationLibrary {
        let rig = try loadRigDefinition()
        let map = try loadSkeletonMap()
        let manifest = try loadManifest()
        let overrides = loadRuntimeClipOverridesIfAvailable()

        if let animationLibraryRoot = try? animationLibraryRootURL() {
            _ = AnimationManifestConsistencyValidator.validate(
                manifest: manifest,
                animationLibraryRoot: animationLibraryRoot
            )
        }

        let runtimeApprovedSummaries = manifest.clips.filter {
            $0.approvedForRuntime
        }

        var loadedClips: [String: JockAnimClip] = [:]

        for summary in runtimeApprovedSummaries {
            let clip = try loadClip(summary: summary)
            loadedClips[summary.clipID] = clip
            loadedClips[clip.clipID] = clip

            if summary.clipID != clip.clipID {
                print(
                    """
                    [AnimationPrewarm] WARNING manifest clip ID differs from sidecar payload
                      manifestClipID: \(summary.clipID)
                      payloadClipID: \(clip.clipID)
                      relativePath: \(summary.relativePath)
                    """
                )
            }
        }

        if loadedClips["dead_fall_forward"] == nil,
           let fallbackDeathClip = loadedClips["dead_fall_forward_01"] {
            loadedClips["dead_fall_forward"] = fallbackDeathClip
            print("[AnimationPrewarm] Runtime alias registered: dead_fall_forward -> dead_fall_forward_01")
        }

        let sourceRigEntriesByID = try loadPrewarmedSourceRigEntries(
            clips: Array(loadedClips.values),
            animationLibraryRoot: try animationLibraryRootURL()
        )

        print(
            """
            [AnimationPrewarm] parsed runtime clips
              approvedSummaries: \(runtimeApprovedSummaries.count)
              loadedClipKeys: \(loadedClips.count)
              sourceRigEntries: \(sourceRigEntriesByID.count)
              noJSONReadAtSpawn: true
            """
        )

        return HordePrewarmedAnimationLibrary(
            rigDefinition: rig,
            skeletonMap: map,
            manifest: manifest,
            runtimeOverrides: overrides,
            clipsByID: loadedClips,
            sourceRigEntriesByID: sourceRigEntriesByID
        )
    }

    private static func loadPrewarmedSourceRigEntries(
        clips: [JockAnimClip],
        animationLibraryRoot: URL
    ) throws -> [String: JockSourceRigEntry] {
        var entriesByID: [String: JockSourceRigEntry] = [:]

        for clip in clips {
            guard let reference = clip.sourceRig?.registryReference else {
                continue
            }

            if entriesByID[reference.sourceRigID] != nil {
                continue
            }

            let url = try sourceRigURL(
                reference: reference,
                animationLibraryRoot: animationLibraryRoot
            )

            let data = try Data(contentsOf: url)
            let entry = try JSONDecoder().decode(
                JockSourceRigEntry.self,
                from: data
            )

            guard entry.skeletonHash == reference.skeletonHash else {
                throw HordePrewarmError.animationPrewarmFailed(
                    clipID: clip.clipID,
                    reason: "Source rig hash mismatch for \(reference.sourceRigID)."
                )
            }

            entriesByID[reference.sourceRigID] = entry
        }

        if !entriesByID.isEmpty {
            print(
                """
                [AnimationPrewarm] source rig entries parsed
                  count: \(entriesByID.count)
                  sourceRigIDs: \(entriesByID.keys.sorted().joined(separator: ", "))
                  noSourceRigJSONReadAtSpawn: true
                """
            )
        }

        return entriesByID
    }

    private static func sourceRigURL(
        reference: JockSourceRigReference,
        animationLibraryRoot: URL
    ) throws -> URL {
        let directURL = animationLibraryRoot
            .appendingPathComponent(reference.relativePath)

        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }

        let normalized = reference.relativePath
            .replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)

        guard let fileNameWithExtension = parts.last else {
            throw JockLoaderError.invalidRelativePath(
                reference.relativePath
            )
        }

        let subdirectory = (["AnimationLibrary"] + Array(parts.dropLast()))
            .joined(separator: "/")
        let nsName = fileNameWithExtension as NSString
        let baseName = nsName.deletingPathExtension
        let extensionName = nsName.pathExtension

        if let bundleURL = Bundle.main.url(
            forResource: baseName,
            withExtension: extensionName,
            subdirectory: subdirectory
        ) {
            return bundleURL
        }

        throw JockLoaderError.missingResource(
            "\(subdirectory)/\(fileNameWithExtension)"
        )
    }
}
