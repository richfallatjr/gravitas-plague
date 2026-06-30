import Foundation

struct TuringQwenNativeTokenizer: Sendable {
    private let vocab: [String: Int]
    private let mergeRanks: [Pair: Int]
    private let specialTokenIDsByContent: [String: Int]
    private let specialTokenContents: [String]
    private let byteEncoder: [UInt8: String]
    private let tokenPattern: NSRegularExpression

    init(modelRoot: URL) throws {
        let decoder = JSONDecoder()
        let vocabURL = modelRoot.appendingPathComponent("vocab.json")
        let mergesURL = modelRoot.appendingPathComponent("merges.txt")
        let tokenizerConfigURL = modelRoot.appendingPathComponent("tokenizer_config.json")

        self.vocab = try decoder.decode(
            [String: Int].self,
            from: Data(contentsOf: vocabURL)
        )

        let config = try decoder.decode(
            TokenizerConfig.self,
            from: Data(contentsOf: tokenizerConfigURL)
        )

        var special: [String: Int] = [:]
        for (id, token) in config.addedTokensDecoder {
            guard let intID = Int(id) else {
                continue
            }
            special[token.content] = intID
        }
        self.specialTokenIDsByContent = special
        self.specialTokenContents = special.keys.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }

        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        var ranks: [Pair: Int] = [:]
        for line in mergesText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("#") == false else {
                continue
            }

            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }

            ranks[Pair(parts[0], parts[1])] = ranks.count
        }
        self.mergeRanks = ranks
        self.byteEncoder = Self.makeByteEncoder()
        self.tokenPattern = try NSRegularExpression(
            pattern: #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#,
            options: []
        )
    }

    func encode(
        _ text: String
    ) throws -> [Int] {
        var ids: [Int] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            if let match = nextSpecialToken(in: text, from: searchStart) {
                if searchStart < match.range.lowerBound {
                    try ids.append(
                        contentsOf: encodeOrdinary(
                            String(text[searchStart..<match.range.lowerBound])
                        )
                    )
                }

                ids.append(match.id)
                searchStart = match.range.upperBound
            } else {
                try ids.append(
                    contentsOf: encodeOrdinary(
                        String(text[searchStart..<text.endIndex])
                    )
                )
                searchStart = text.endIndex
            }
        }

        return ids
    }

    private func nextSpecialToken(
        in text: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, id: Int)? {
        var best: (range: Range<String.Index>, id: Int)?

        for token in specialTokenContents {
            guard let range = text.range(of: token, range: start..<text.endIndex),
                  let id = specialTokenIDsByContent[token] else {
                continue
            }

            if let current = best {
                if range.lowerBound < current.range.lowerBound {
                    best = (range, id)
                }
            } else {
                best = (range, id)
            }
        }

        return best
    }

    private func encodeOrdinary(
        _ text: String
    ) throws -> [Int] {
        guard text.isEmpty == false else {
            return []
        }

        let nsText = text as NSString
        let matches = tokenPattern.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )

        var ids: [Int] = []
        for match in matches {
            let piece = nsText.substring(with: match.range)
            let byteMapped = piece.utf8.map { byteEncoder[$0] ?? "" }.joined()
            for token in bpe(byteMapped) {
                guard let id = vocab[token] else {
                    throw TuringQwenNativeError.tokenizer("Missing vocab token: \(token)")
                }
                ids.append(id)
            }
        }

        return ids
    }

    private func bpe(
        _ token: String
    ) -> [String] {
        var word = token.map { String($0) }
        guard word.count > 1 else {
            return word
        }

        while true {
            var bestIndex: Int?
            var bestRank = Int.max

            for index in 0..<(word.count - 1) {
                let pair = Pair(word[index], word[index + 1])
                if let rank = mergeRanks[pair],
                   rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }

            guard let index = bestIndex else {
                break
            }

            word[index] = word[index] + word[index + 1]
            word.remove(at: index + 1)

            if word.count == 1 {
                break
            }
        }

        return word
    }

    private static func makeByteEncoder() -> [UInt8: String] {
        var bs = Array(UInt8(ascii: "!")...UInt8(ascii: "~"))
        bs += Array(UInt8(161)...UInt8(172))
        bs += Array(UInt8(174)...UInt8(255))

        var cs = bs.map(Int.init)
        var n = 0
        for b in UInt8.min...UInt8.max where bs.contains(b) == false {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }

        var encoder: [UInt8: String] = [:]
        for (byte, scalar) in zip(bs, cs) {
            guard let unicodeScalar = UnicodeScalar(scalar) else {
                continue
            }
            encoder[byte] = String(unicodeScalar)
        }

        return encoder
    }

    private struct Pair: Hashable, Sendable {
        let left: String
        let right: String

        init(_ left: String, _ right: String) {
            self.left = left
            self.right = right
        }
    }

    private struct TokenizerConfig: Decodable {
        let addedTokensDecoder: [String: AddedToken]

        enum CodingKeys: String, CodingKey {
            case addedTokensDecoder = "added_tokens_decoder"
        }
    }

    private struct AddedToken: Decodable {
        let content: String
    }
}
