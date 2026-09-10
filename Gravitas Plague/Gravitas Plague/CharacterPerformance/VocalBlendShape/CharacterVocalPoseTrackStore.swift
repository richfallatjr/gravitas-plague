import Foundation

nonisolated struct CharacterVocalAudioAsset: Sendable, Equatable, Hashable {
    let characterID: String
    let role: CharacterVocalRole
    let fileName: String
    let expectedSHA256: String
    let url: URL
}

nonisolated struct CharacterVocalAudioAssetIdentity: Sendable, Equatable, Hashable {
    let characterID: String
    let role: CharacterVocalRole
    let fileName: String
    let sha256: String
}

nonisolated struct CharacterVocalPreparedPoseTrack: Sendable {
    let identity: CharacterVocalAudioAssetIdentity
    let track: CharacterVocalVisemeTrack
}

nonisolated enum CharacterVocalAudioInventory {
    struct Entry: Sendable, Equatable {
        let role: CharacterVocalRole
        let fileName: String
        let sha256: String
    }

    static let animatedRoles: [CharacterVocalRole] = [
        .presenceLoop,
        .damageHit,
        .death
    ]

    private static let dad: [Entry] = [
        .init(role: .presenceLoop, fileName: "dad_breathing.wav", sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"),
        .init(role: .damageHit, fileName: "dad-damaged-01.wav", sha256: "fd079a1794c72cd18b565a7398bbb3d601c18fce8be68c85578d0d10f67bf7a5"),
        .init(role: .damageHit, fileName: "dad-damaged-02.wav", sha256: "024cc7fc72276ac2501c729faa97aa5ef855f2739af4d1eba408a6304eca3e71"),
        .init(role: .damageHit, fileName: "dad-damaged-03.wav", sha256: "e28f6eba93636333ead99be7b9059bd9742136375b4aaf87fa1ab1e4e6581da1"),
        .init(role: .damageHit, fileName: "dad-damaged-04.wav", sha256: "4f5fd5842e046ab7a0fc3fb51d4fe38eb5ad4d2f923b3bacf53cb9fa262a2cbf"),
        .init(role: .death, fileName: "dad-death-01.wav", sha256: "670ff38fd3eb5e8f95d1b5848ec346b9a9e7b2f1b610b61a4c6f93e97d40b2f4"),
        .init(role: .death, fileName: "dad-death-02.wav", sha256: "bedad39a231b62e7acb4fc7462680d62d84367e5b3e341ccfe4761774853fcff"),
        .init(role: .death, fileName: "dad-death-03.wav", sha256: "a06c5cf435c3597d7bbd6e98023dc170250e9a95c8bd807fda2ecb67746ff0dc"),
        .init(role: .death, fileName: "dad-death-04.wav", sha256: "48d97a9a5558870a4ba4ee238f805ca4dd86465ffe3bace1898036f66b9dd205")
    ]

    private static let grandma: [Entry] = [
        .init(role: .presenceLoop, fileName: "dad_breathing.wav", sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"),
        .init(role: .damageHit, fileName: "grandma-damaged-01.wav", sha256: "987f3502330da589d675293815b48bc1e692d03a2cd37b4d57cbdbae27170453"),
        .init(role: .damageHit, fileName: "grandma-damaged-02.wav", sha256: "6ab48c44af6a4e8b6c1d9c034ac804494a675013566c027d5bf99091e0c8bfc8"),
        .init(role: .damageHit, fileName: "grandma-damaged-03.wav", sha256: "fab41d36ab369770e9edffa1d06ebc6f04c565da8a893211a7f4e07c9e89fd4d"),
        .init(role: .damageHit, fileName: "grandma-damaged-04.wav", sha256: "652b9c471876f5a0a7050ad84b44d167990249076d4492c04e646d574950681c"),
        .init(role: .death, fileName: "grandma-death-01.wav", sha256: "51f0cd4f03d9271c175262a4f62d66378c3ee8636a59aabf613c91e04e13b1dc"),
        .init(role: .death, fileName: "grandma-death-02.wav", sha256: "38293ffbf3b84bd7a0718d967093f57ab753281a2b9898622549cae7782f5697"),
        .init(role: .death, fileName: "grandma-death-03.wav", sha256: "a779ff2a8c5fba11915dc875981ff3db04161943c7945093dcac06dada543c79"),
        .init(role: .death, fileName: "grandma-death-04.wav", sha256: "afdb68decbef7e36c8978b48fe4bc6f3d05f718414966573a0790c5ef5050f8f")
    ]

    private static let spouse: [Entry] = [
        .init(role: .presenceLoop, fileName: "dad_breathing.wav", sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"),
        .init(role: .damageHit, fileName: "spouse-damaged-01.wav", sha256: "3b10cc19599c05ccad5d48e8b2286a6e46fc95e1593b6ec198d2a3bc3a868ff6"),
        .init(role: .damageHit, fileName: "spouse-damaged-02.wav", sha256: "17eb441692bbebef553706a99de16ccd6d01825c1b8c5d50097ec1b8453b13d0"),
        .init(role: .damageHit, fileName: "spouse-damaged-03.wav", sha256: "b1baf3e615a1fbc48beaa70ba605420e896e78e522aff285dc0a47e6c10f9805"),
        .init(role: .damageHit, fileName: "spouse-damaged-04.wav", sha256: "83d9ccc70b8084bc08231c6b43a73a2a3ed5edab889d172583f50d19eb7f66eb"),
        .init(role: .death, fileName: "spouse-death-01.wav", sha256: "f785c6c9bcdd71549418a144ae3da9378364cae404a6fe0a25858a244b1a057c"),
        .init(role: .death, fileName: "spouse-death-02.wav", sha256: "d2a171bf68151b663c2fd7930dfdfd4f1396a1b1e3e7b1fe5d159326237773f4"),
        .init(role: .death, fileName: "spouse-death-03.wav", sha256: "62de55305b678d9ce38f1a1d82618fefeaccb18b24e8128dcdc2b1d627efa879"),
        .init(role: .death, fileName: "spouse-death-04.wav", sha256: "1f2f75b7f7f7f2c05c65f558dead60e03525473926d39c29e14c0a9176741a00")
    ]

    private static let biker: [Entry] = [
        .init(role: .presenceLoop, fileName: "dad_breathing.wav", sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"),
        .init(role: .damageHit, fileName: "biker-damaged-01.wav", sha256: "817c1ee8343ea12320961fe13e525e5c47c3e224dc2b167927c0f407b22130df"),
        .init(role: .damageHit, fileName: "biker-damaged-02.wav", sha256: "2b5a8ada1d149465a803d0e96af40dd678c7de706b85c6dda371e0cf445f93a0"),
        .init(role: .damageHit, fileName: "biker-damaged-03.wav", sha256: "a68a02a758942e9cfcfb1f3854891008a39caf766614b391b0807c2d13fe7ce2"),
        .init(role: .damageHit, fileName: "biker-damaged-04.wav", sha256: "c25cc41f8a50bdfd8cd07260bfc9efcf0e225295ebc5be660fb9c4a45346b9d7"),
        .init(role: .death, fileName: "biker-death-01.wav", sha256: "2f3345b8073e3f5b86256f33f6f3e81466a5252b22c17d998bb82507b6359c33"),
        .init(role: .death, fileName: "biker-death-02.wav", sha256: "1a04eb28f3b7900ac3ace88640a75fda79bf727b4c82f4976bcdfcf6f6d833b0"),
        .init(role: .death, fileName: "biker-death-03.wav", sha256: "57e1193655477f76daa6d854e4fca6d15b699901e1e96d79c236acaa19262c1c"),
        .init(role: .death, fileName: "biker-death-04.wav", sha256: "a736672b0fd2f4ee1aa55c71002c329c32049b0d957b3897f528e7baa398f880")
    ]

    private static let neighbor: [Entry] = [
        .init(role: .presenceLoop, fileName: "dad_breathing.wav", sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"),
        .init(role: .damageHit, fileName: "neighbor-damaged-01.wav", sha256: "5c67c59fb6dd1ae05b96709d2cd0daa19643b2a06694a169cd89b326f3146123"),
        .init(role: .damageHit, fileName: "neighbor-damaged-02.wav", sha256: "ac099f4cfe1e0c983a5ce74c93f581bd0082b4eef490d087839824158951aeba"),
        .init(role: .damageHit, fileName: "neighbor-damaged-03.wav", sha256: "fbfc40ae796dffc22b1d54075bf2598a290cc46ed4e35951a08c55fbac821c24"),
        .init(role: .damageHit, fileName: "neighbor-damaged-04.wav", sha256: "4e59bd71ed5a2fa157e7b39637d6db0393e5c5484ab05790243e5426aadd40ba"),
        .init(role: .death, fileName: "neighbor-death-01.wav", sha256: "b3eade454d325b15ebadd815934b1a596a53498ab283ed0b57862f6e331d55fc"),
        .init(role: .death, fileName: "neighbor-death-02.wav", sha256: "53d79558e5a850eb993e77323d6ff7eb0d21afc656ba9a8b1837cd01779d4b82"),
        .init(role: .death, fileName: "neighbor-death-03.wav", sha256: "655853705fe89f83a5e6bae6a16ef2b94293f7f2b26b5f13fc4cb3659ef686b2"),
        .init(role: .death, fileName: "neighbor-death-04.wav", sha256: "e463fb5772a85adb14c29a4c9941efff0be6f017ac105cc7bccf99db3357eea2")
    ]

    static func ordered(characterID: String) -> [Entry] {
        switch characterID {
        case "dad": dad
        case "grandma": grandma
        case "spouse": spouse
        case "biker": biker
        case "neighbor": neighbor
        default: []
        }
    }

    static func drivesAnimation(
        role: CharacterVocalRole,
        isLooping: Bool
    ) -> Bool {
        switch role {
        case .presenceLoop:
            isLooping
        case .damageHit, .death:
            !isLooping
        }
    }

    static func entry(
        characterID: String,
        role: CharacterVocalRole,
        fileName: String
    ) -> Entry? {
        ordered(characterID: characterID).first {
            $0.role == role && $0.fileName == fileName
        }
    }

    static func assets(
        characterID: String,
        bundle: Bundle = .main
    ) -> [CharacterVocalAudioAsset] {
        ordered(characterID: characterID).compactMap { entry in
            let url = bundle.url(forResource: entry.fileName, withExtension: nil) ?? {
                let path = URL(fileURLWithPath: entry.fileName)
                return bundle.url(
                    forResource: path.deletingPathExtension().lastPathComponent,
                    withExtension: path.pathExtension
                )
            }()
            guard let url else { return nil }
            return .init(
                characterID: characterID,
                role: entry.role,
                fileName: entry.fileName,
                expectedSHA256: entry.sha256,
                url: url
            )
        }
    }

    static func asset(
        for start: CharacterVocalPlaybackStart,
        bundle: Bundle = .main
    ) -> CharacterVocalAudioAsset? {
        guard let profile = CharacterVocalBlendShapeProfile.resolve(
                  characterID: start.identity.characterID
              ),
              start.identity.archetype == profile.archetype,
              drivesAnimation(
                  role: start.identity.role,
                  isLooping: start.identity.isLooping
              ),
              let entry = entry(
                  characterID: profile.characterID,
                  role: start.identity.role,
                  fileName: start.identity.fileName
              ) else { return nil }
        let path = URL(fileURLWithPath: entry.fileName)
        guard let url = bundle.url(forResource: entry.fileName, withExtension: nil) ??
                bundle.url(
                    forResource: path.deletingPathExtension().lastPathComponent,
                    withExtension: path.pathExtension
                ) else { return nil }
        return .init(
            characterID: profile.characterID,
            role: entry.role,
            fileName: entry.fileName,
            expectedSHA256: entry.sha256,
            url: url
        )
    }
}

/// Compatibility facade retained for the focused Dad contract tests and any
/// existing call sites while the production store is shared by all supported
/// characters.
nonisolated enum DadVocalAudioInventory {
    typealias Entry = CharacterVocalAudioInventory.Entry

    static let animatedRoles = CharacterVocalAudioInventory.animatedRoles
    static let ordered = CharacterVocalAudioInventory.ordered(characterID: "dad")

    static func drivesAnimation(
        role: CharacterVocalRole,
        isLooping: Bool
    ) -> Bool {
        CharacterVocalAudioInventory.drivesAnimation(
            role: role,
            isLooping: isLooping
        )
    }

    static func entry(role: CharacterVocalRole, fileName: String) -> Entry? {
        CharacterVocalAudioInventory.entry(
            characterID: "dad",
            role: role,
            fileName: fileName
        )
    }

    static func assets(bundle: Bundle = .main) -> [CharacterVocalAudioAsset] {
        CharacterVocalAudioInventory.assets(characterID: "dad", bundle: bundle)
    }

    static func asset(
        for start: CharacterVocalPlaybackStart,
        bundle: Bundle = .main
    ) -> CharacterVocalAudioAsset? {
        guard start.identity.characterID == "dad" else { return nil }
        return CharacterVocalAudioInventory.asset(for: start, bundle: bundle)
    }
}

nonisolated enum GrandmaVocalAudioInventory {
    typealias Entry = CharacterVocalAudioInventory.Entry

    static let animatedRoles = CharacterVocalAudioInventory.animatedRoles
    static let ordered = CharacterVocalAudioInventory.ordered(characterID: "grandma")

    static func assets(bundle: Bundle = .main) -> [CharacterVocalAudioAsset] {
        CharacterVocalAudioInventory.assets(
            characterID: "grandma",
            bundle: bundle
        )
    }

    static func asset(
        for start: CharacterVocalPlaybackStart,
        bundle: Bundle = .main
    ) -> CharacterVocalAudioAsset? {
        guard start.identity.characterID == "grandma" else { return nil }
        return CharacterVocalAudioInventory.asset(for: start, bundle: bundle)
    }
}

nonisolated enum SpouseVocalAudioInventory {
    typealias Entry = CharacterVocalAudioInventory.Entry

    static let animatedRoles = CharacterVocalAudioInventory.animatedRoles
    static let ordered = CharacterVocalAudioInventory.ordered(characterID: "spouse")

    static func assets(bundle: Bundle = .main) -> [CharacterVocalAudioAsset] {
        CharacterVocalAudioInventory.assets(
            characterID: "spouse",
            bundle: bundle
        )
    }

    static func asset(
        for start: CharacterVocalPlaybackStart,
        bundle: Bundle = .main
    ) -> CharacterVocalAudioAsset? {
        guard start.identity.characterID == "spouse" else { return nil }
        return CharacterVocalAudioInventory.asset(for: start, bundle: bundle)
    }
}

nonisolated enum BikerVocalAudioInventory {
    typealias Entry = CharacterVocalAudioInventory.Entry

    static let animatedRoles = CharacterVocalAudioInventory.animatedRoles
    static let ordered = CharacterVocalAudioInventory.ordered(characterID: "biker")

    static func assets(bundle: Bundle = .main) -> [CharacterVocalAudioAsset] {
        CharacterVocalAudioInventory.assets(
            characterID: "biker",
            bundle: bundle
        )
    }

    static func asset(
        for start: CharacterVocalPlaybackStart,
        bundle: Bundle = .main
    ) -> CharacterVocalAudioAsset? {
        guard start.identity.characterID == "biker" else { return nil }
        return CharacterVocalAudioInventory.asset(for: start, bundle: bundle)
    }
}

nonisolated enum NeighborVocalAudioInventory {
    typealias Entry = CharacterVocalAudioInventory.Entry

    static let animatedRoles = CharacterVocalAudioInventory.animatedRoles
    static let ordered = CharacterVocalAudioInventory.ordered(characterID: "neighbor")

    static func assets(bundle: Bundle = .main) -> [CharacterVocalAudioAsset] {
        CharacterVocalAudioInventory.assets(
            characterID: "neighbor",
            bundle: bundle
        )
    }

    static func asset(
        for start: CharacterVocalPlaybackStart,
        bundle: Bundle = .main
    ) -> CharacterVocalAudioAsset? {
        guard start.identity.characterID == "neighbor" else { return nil }
        return CharacterVocalAudioInventory.asset(for: start, bundle: bundle)
    }
}

actor CharacterVocalPoseTrackStore {
    private let authoredStore = CharacterVocalVisemeTrackStore()

    func prepare(
        _ asset: CharacterVocalAudioAsset
    ) async -> CharacterVocalPreparedPoseTrack? {
        guard CharacterVocalBlendShapeProfile.resolve(
                  characterID: asset.characterID
              ) != nil,
              let track = await authoredStore.track(for: asset) else {
            return nil
        }
        return CharacterVocalPreparedPoseTrack(
            identity: .init(
                characterID: asset.characterID,
                role: asset.role,
                fileName: asset.fileName,
                sha256: asset.expectedSHA256
            ),
            track: track
        )
    }

    func removeAll() async {
        await authoredStore.removeAll()
    }
}
