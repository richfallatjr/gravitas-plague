import Foundation

struct TuringWalkieCommsAssetStore: Sendable {
    enum AssetError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name):
                return "Missing Turing walkie comm asset: \(name)"
            }
        }
    }

    let subdirectory = "Turing/Audio/walkie"

    func openCommURL() throws -> URL {
        try url(name: "open-comm", ext: "wav")
    }

    func sendCommURL() throws -> URL {
        try url(name: "send-comm", ext: "wav")
    }

    func ambientStaticLoopURL() throws -> URL {
        try url(name: "walkie-talkie-static-loop", ext: "mp3")
    }

    func sendingStaticLoopURL() throws -> URL {
        try url(name: "sending-static-loop", ext: "mp3")
    }

    func randomBurstURLs() -> [URL] {
        (1...6).compactMap { index in
            let name = String(format: "walkie-talkie-%02d", index)
            do {
                return try url(name: name, ext: "wav")
            } catch {
                print("""
                [TuringWalkieComms] random burst asset missing
                  file: \(name).wav
                """)
                return nil
            }
        }
    }

    private func url(name: String, ext: String) throws -> URL {
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: ext,
            subdirectory: subdirectory
        ) {
            return url
        }

        if let url = Bundle.main.url(
            forResource: name,
            withExtension: ext
        ) {
            return url
        }

        throw AssetError.missing("\(name).\(ext)")
    }
}
