import Foundation
import Combine

@MainActor
final class CharacterAttributeStore: ObservableObject {
    static let shared = CharacterAttributeStore()

    @Published private(set) var attributesByID: [String: CharacterAttributes] = [:]
    @Published private(set) var validationErrors: [String] = []

    private init() {}

    var isLoaded: Bool {
        !attributesByID.isEmpty
    }

    func loadStrict() throws {
        let manifest = try JockAnimationLibraryLoader.loadManifest()
        try loadStrict(
            animationManifest: manifest
        )
    }

    func loadStrict(
        animationManifest: JockAnimationManifest
    ) throws {
        validationErrors.removeAll()

        let characterIDs = try loadManifestCharacterIDs()
        var loaded: [String: CharacterAttributes] = [:]

        for characterID in characterIDs {
            let attributes = try loadSidecar(
                characterID: characterID
            )

            guard attributes.characterID == characterID else {
                throw CharacterAttributeError.archetypeMismatch(
                    characterID: characterID,
                    archetype: attributes.characterID
                )
            }

            guard attributes.archetype.rawValue == characterID else {
                throw CharacterAttributeError.archetypeMismatch(
                    characterID: characterID,
                    archetype: attributes.archetype.rawValue
                )
            }

            if loaded[attributes.characterID] != nil {
                throw CharacterAttributeError.duplicateCharacterID(
                    attributes.characterID
                )
            }

            try validate(
                attributes,
                animationManifest: animationManifest
            )

            loaded[attributes.characterID] = attributes
        }

        attributesByID = loaded

        print(
            """
            [CharacterAttributes] loaded strict
              characters: \(loaded.keys.sorted().joined(separator: ", "))
              noFallback: true
            """
        )
    }

    func attributes(
        for archetype: PlagueCharacterArchetype
    ) throws -> CharacterAttributes {
        if attributesByID.isEmpty {
            try loadStrict()
        }

        guard let attributes = attributesByID[archetype.rawValue] else {
            throw CharacterAttributeError.missingSidecar(
                characterID: archetype.rawValue
            )
        }

        return attributes
    }

    func attributes(
        forCharacterID characterID: String
    ) throws -> CharacterAttributes {
        if attributesByID.isEmpty {
            try loadStrict()
        }

        guard let attributes = attributesByID[characterID] else {
            throw CharacterAttributeError.missingSidecar(
                characterID: characterID
            )
        }

        return attributes
    }
}

private extension CharacterAttributeStore {
    struct CharacterManifest: Codable {
        let schema: String
        let characters: [String]
    }

    func loadManifestCharacterIDs() throws -> [String] {
        guard let url = characterLibraryResourceURL(
            forResource: "character_manifest",
            withExtension: "json",
            preferredSubdirectory: "CharacterLibrary/Manifests"
        ) else {
            throw CharacterAttributeError.missingManifest
        }

        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(
            CharacterManifest.self,
            from: data
        )

        print(
            """
            [CharacterAttributes] manifest loaded
              schema: \(manifest.schema)
              characters: \(manifest.characters.joined(separator: ", "))
            """
        )

        return manifest.characters
    }

    func loadSidecar(
        characterID: String
    ) throws -> CharacterAttributes {
        guard let url = characterLibraryResourceURL(
            forResource: "\(characterID).character",
            withExtension: "json",
            preferredSubdirectory: "CharacterLibrary/Characters"
        ) else {
            throw CharacterAttributeError.missingSidecar(
                characterID: characterID
            )
        }

        let data = try Data(contentsOf: url)
        let attributes = try JSONDecoder().decode(
            CharacterAttributes.self,
            from: data
        )

        guard attributes.schema == "com.gravitas.character_attributes.v1" else {
            throw CharacterAttributeError.badSchema(
                characterID: characterID,
                schema: attributes.schema
            )
        }

        print(
            """
            [CharacterAttributes] sidecar loaded
              characterID: \(attributes.characterID)
              archetype: \(attributes.archetype.rawValue)
              asset: \(attributes.asset.usdz)
            """
        )

        return attributes
    }

    func characterLibraryResourceURL(
        forResource resource: String,
        withExtension ext: String,
        preferredSubdirectory: String
    ) -> URL? {
        Bundle.main.url(
            forResource: resource,
            withExtension: ext,
            subdirectory: preferredSubdirectory
        ) ?? Bundle.main.url(
            forResource: resource,
            withExtension: ext
        )
    }

    func validate(
        _ attributes: CharacterAttributes,
        animationManifest: JockAnimationManifest
    ) throws {
        try validateUSDZ(attributes)
        try validateHits(attributes)
        try validateAnimations(
            attributes,
            animationManifest: animationManifest
        )
        try validateAudio(attributes)

        print(
            """
            [CharacterAttributes] validation passed
              characterID: \(attributes.characterID)
              noFallback: true
            """
        )
    }

    func validateUSDZ(
        _ attributes: CharacterAttributes
    ) throws {
        guard CharacterAssetRegistry.url(
            attributes: attributes
        ) != nil else {
            throw CharacterAttributeError.missingUSDZ(
                characterID: attributes.characterID,
                file: attributes.asset.usdz
            )
        }
    }

    func validateHits(
        _ attributes: CharacterAttributes
    ) throws {
        let min = attributes.horde.hitsToKill.min
        let max = attributes.horde.hitsToKill.max

        guard attributes.horde.enabled else {
            throw CharacterAttributeError.disabledCharacter(
                characterID: attributes.characterID
            )
        }

        guard min > 0, max >= min else {
            throw CharacterAttributeError.invalidHitsToKill(
                characterID: attributes.characterID,
                min: min,
                max: max
            )
        }
    }

    func validateAnimations(
        _ attributes: CharacterAttributes,
        animationManifest: JockAnimationManifest
    ) throws {
        let availableClipIDs = Set(
            animationManifest.clips
                .filter(\.approvedForRuntime)
                .map(\.clipID)
        )

        try validateClipRefs(
            attributes.animations.idle,
            characterID: attributes.characterID,
            role: "idle",
            availableClipIDs: availableClipIDs
        )
        try validateClipRefs(
            attributes.animations.walk,
            characterID: attributes.characterID,
            role: "walk",
            availableClipIDs: availableClipIDs
        )
        try validateClipRefs(
            attributes.animations.turn.left90,
            characterID: attributes.characterID,
            role: "turn.left_90",
            availableClipIDs: availableClipIDs
        )
        try validateClipRefs(
            attributes.animations.turn.right90,
            characterID: attributes.characterID,
            role: "turn.right_90",
            availableClipIDs: availableClipIDs
        )
        try validateClipRefs(
            attributes.animations.attack,
            characterID: attributes.characterID,
            role: "attack",
            availableClipIDs: availableClipIDs
        )
        try validateClipRefs(
            attributes.animations.damage,
            characterID: attributes.characterID,
            role: "damage",
            availableClipIDs: availableClipIDs
        )
        try validateClipRefs(
            attributes.animations.death,
            characterID: attributes.characterID,
            role: "death",
            availableClipIDs: availableClipIDs
        )
    }

    func validateClipRefs(
        _ refs: [AnimationClipRef],
        characterID: String,
        role: String,
        availableClipIDs: Set<String>
    ) throws {
        guard !refs.isEmpty else {
            throw CharacterAttributeError.missingAnimationRole(
                characterID: characterID,
                role: role
            )
        }

        for ref in refs {
            guard availableClipIDs.contains(ref.clipID) else {
                throw CharacterAttributeError.missingAnimationClip(
                    characterID: characterID,
                    role: role,
                    clipID: ref.clipID
                )
            }
        }
    }

    func validateAudio(
        _ attributes: CharacterAttributes
    ) throws {
        if let loop = attributes.audio.presenceLoop {
            try validateSound(
                loop,
                characterID: attributes.characterID,
                role: "presence_loop"
            )
        } else {
            throw CharacterAttributeError.missingAudioRole(
                characterID: attributes.characterID,
                role: "presence_loop"
            )
        }

        try validateOptionalSoundRefs(
            attributes.audio.damageHits,
            characterID: attributes.characterID,
            role: "damage_hits"
        )
        try validateSoundRefs(
            attributes.audio.faceHits,
            characterID: attributes.characterID,
            role: "face_hits"
        )
        try validateOptionalSoundRefs(
            attributes.audio.death,
            characterID: attributes.characterID,
            role: "death"
        )
        try validateOptionalSoundRefs(
            attributes.audio.attack,
            characterID: attributes.characterID,
            role: "attack"
        )
    }

    func validateSoundRefs(
        _ refs: [SoundRef],
        characterID: String,
        role: String
    ) throws {
        guard !refs.isEmpty else {
            throw CharacterAttributeError.missingAudioRole(
                characterID: characterID,
                role: role
            )
        }

        try validateOptionalSoundRefs(
            refs,
            characterID: characterID,
            role: role
        )
    }

    func validateOptionalSoundRefs(
        _ refs: [SoundRef],
        characterID: String,
        role: String
    ) throws {
        for ref in refs {
            try validateSound(
                ref,
                characterID: characterID,
                role: role
            )
        }
    }

    func validateSound(
        _ ref: SoundRef,
        characterID: String,
        role: String
    ) throws {
        guard Bundle.main.url(
            forResource: ref.basename,
            withExtension: ref.ext
        ) ?? Bundle.main.url(
            forResource: ref.basename,
            withExtension: ref.ext,
            subdirectory: "Audio"
        ) != nil else {
            throw CharacterAttributeError.missingAudioFile(
                characterID: characterID,
                role: role,
                file: ref.file
            )
        }
    }
}
