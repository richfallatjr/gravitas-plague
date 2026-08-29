import Foundation

nonisolated struct TuringRuntimeLipSyncNormalizedText: Sendable, Equatable {
    let authoritativeTextSHA256: String
    let normalizedAlignmentText: String
    let normalizedWords: [String]
    let unresolvedWords: [String]
    let transformationCodes: [String]
}

nonisolated struct TuringRuntimeLipSyncTextNormalizer: Sendable {
    typealias WordKnown = @Sendable (String) -> Bool

    func normalize(
        exactText: String,
        wordKnown: WordKnown = { _ in true }
    ) throws -> TuringRuntimeLipSyncNormalizedText {
        guard !exactText.isEmpty else {
            throw TuringRuntimeLipSyncFailure.normalizationFailed(
                "Exact generated source text is empty."
            )
        }
        var transformations: [String] = []
        var value = exactText.precomposedStringWithCompatibilityMapping
        if value != exactText { transformations.append("nfkc") }
        let punctuationReplacements: [(String, String, String)] = [
            ("’", "'", "smartApostrophe"),
            ("‘", "'", "smartApostrophe"),
            ("—", " ", "dashBoundary"),
            ("–", " ", "dashBoundary"),
            ("…", " ", "ellipsisBoundary")
        ]
        for (source, replacement, code) in punctuationReplacements
        where value.contains(source) {
            value = value.replacingOccurrences(of: source, with: replacement)
            transformations.append(code)
        }
        let rawTokens = value
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var words: [String] = []
        for raw in rawTokens {
            let cleaned = Self.cleanToken(raw).lowercased(
                with: Locale(identifier: "en_US_POSIX")
            )
            guard !cleaned.isEmpty else { continue }
            let expanded = expandToken(
                cleaned,
                originalToken: raw,
                wordKnown: wordKnown,
                transformations: &transformations
            )
            words.append(contentsOf: expanded)
        }
        guard !words.isEmpty else {
            throw TuringRuntimeLipSyncFailure.normalizationFailed(
                "Generated text contains no alignable words."
            )
        }
        let unresolved = words.filter { !wordKnown($0) }
        return .init(
            authoritativeTextSHA256: TuringRuntimeLipSyncSHA256.text(exactText),
            normalizedAlignmentText: words.joined(separator: " "),
            normalizedWords: words,
            unresolvedWords: unresolved,
            transformationCodes: Array(Set(transformations)).sorted()
        )
    }

    private func expandToken(
        _ token: String,
        originalToken: String,
        wordKnown: WordKnown,
        transformations: inout [String]
    ) -> [String] {
        if token.hasSuffix("%"),
           let number = Self.parseNumber(String(token.dropLast())) {
            transformations.append("percentage")
            return Self.spell(number) + ["percent"]
        }
        if let colon = token.firstIndex(of: ":"),
           token[token.index(after: colon)...].allSatisfy(\.isNumber),
           let hour = Int(token[..<colon]),
           let minute = Int(token[token.index(after: colon)...]),
           (0...23).contains(hour), (0...59).contains(minute) {
            transformations.append("time")
            if minute == 0 { return Self.spell(hour) + ["o'clock"] }
            if minute < 10 { return Self.spell(hour) + ["oh"] + Self.spell(minute) }
            return Self.spell(hour) + Self.spell(minute)
        }
        if let ordinal = Self.parseOrdinal(token) {
            transformations.append("ordinal")
            return Self.spellOrdinal(ordinal)
        }
        if let number = Self.parseNumber(token) {
            transformations.append(token.contains(".") ? "decimal" : "integer")
            return Self.spell(number)
        }
        if token.contains("-") {
            if wordKnown(token) { return [token] }
            transformations.append("hyphenSplit")
            return token.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        }
        let uppercaseLetters = originalToken.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }
        if (2...8).contains(uppercaseLetters.count),
           uppercaseLetters.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }),
           !wordKnown(token) {
            transformations.append("acronym")
            return uppercaseLetters.compactMap { Self.letterNames[Character(String($0))] }
        }
        return [token]
    }

    private static func cleanToken(_ token: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "'-.:%+"))
        var scalars = token.unicodeScalars.filter { allowed.contains($0) }
        while let first = scalars.first,
              !CharacterSet.alphanumerics.contains(first), first != "+", first != "-" {
            scalars.removeFirst()
        }
        while let last = scalars.last,
              !CharacterSet.alphanumerics.contains(last), last != "%" {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private struct ParsedNumber {
        let negative: Bool
        let whole: Int
        let fractionalDigits: [Int]
    }

    private static func parseNumber(_ token: String) -> ParsedNumber? {
        var value = token
        var negative = false
        if value.first == "+" { value.removeFirst() }
        else if value.first == "-" { negative = true; value.removeFirst() }
        guard !value.isEmpty else { return nil }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2,
              !pieces[0].isEmpty,
              pieces[0].allSatisfy(\.isNumber),
              let whole = Int(pieces[0]),
              whole <= 999_999_999 else { return nil }
        var fractional: [Int] = []
        if pieces.count == 2 {
            guard !pieces[1].isEmpty, pieces[1].allSatisfy(\.isNumber) else { return nil }
            fractional = pieces[1].compactMap { Int(String($0)) }
        }
        return .init(negative: negative, whole: whole, fractionalDigits: fractional)
    }

    private static func parseOrdinal(_ token: String) -> Int? {
        for suffix in ["st", "nd", "rd", "th"] where token.hasSuffix(suffix) {
            return Int(token.dropLast(2))
        }
        return nil
    }

    private static func spell(_ number: ParsedNumber) -> [String] {
        var result = number.negative ? ["minus"] : []
        result += spell(number.whole)
        if !number.fractionalDigits.isEmpty {
            result.append("point")
            result += number.fractionalDigits.flatMap(spell)
        }
        return result
    }

    private static func spell(_ value: Int) -> [String] {
        let small = [
            "zero", "one", "two", "three", "four", "five", "six", "seven",
            "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
            "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"
        ]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        if value < 20 { return [small[value]] }
        if value < 100 {
            return [tens[value / 10]] + (value % 10 == 0 ? [] : [small[value % 10]])
        }
        if value < 1_000 {
            return [small[value / 100], "hundred"] + (value % 100 == 0 ? [] : spell(value % 100))
        }
        for (scale, name) in [(1_000_000, "million"), (1_000, "thousand")]
        where value >= scale {
            return spell(value / scale) + [name] + (value % scale == 0 ? [] : spell(value % scale))
        }
        return ["zero"]
    }

    private static func spellOrdinal(_ value: Int) -> [String] {
        let irregular = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
            11: "eleventh", 12: "twelfth", 20: "twentieth", 30: "thirtieth",
            40: "fortieth", 50: "fiftieth", 60: "sixtieth", 70: "seventieth",
            80: "eightieth", 90: "ninetieth"
        ]
        if let word = irregular[value] { return [word] }
        guard value > 0 else { return ["zeroth"] }
        var words = spell(value)
        if let last = words.popLast() {
            words.append(irregular[value % 100] ?? irregular[value % 10] ?? "\(last)th")
        }
        return words
    }

    private static let letterNames: [Character: String] = [
        "A": "ay", "B": "bee", "C": "see", "D": "dee", "E": "ee",
        "F": "ef", "G": "gee", "H": "aitch", "I": "eye", "J": "jay",
        "K": "kay", "L": "el", "M": "em", "N": "en", "O": "oh",
        "P": "pee", "Q": "cue", "R": "are", "S": "ess", "T": "tee",
        "U": "you", "V": "vee", "W": "doubleyou", "X": "ex",
        "Y": "why", "Z": "zee"
    ]
}
