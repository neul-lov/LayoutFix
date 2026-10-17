/// Standard Korean Dubeolsik (2-set) keyboard layout tables.
///
/// Jamo are represented as Hangul Compatibility Jamo scalars (U+3131–U+318E), which is
/// what a keyboard produces for a lone consonant or vowel.
enum Dubeolsik {
    /// Unshifted keys. Letters not listed in `shifted` produce the same jamo with Shift
    /// (or Caps Lock), matching the macOS 2-Set Korean input source.
    static let unshifted: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ",
        "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ",
        "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
    ]

    static let shifted: [Character: Character] = [
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ",
    ]

    /// Jamo produced by the key `ch`, or nil if `ch` is not a letter key.
    static func jamo(forKey ch: Character) -> Character? {
        if let j = shifted[ch] { return j }
        if let j = unshifted[ch] { return j }
        guard ch.isASCII, ch.isUppercase else { return nil }
        return unshifted[Character(ch.lowercased())]
    }

    /// Keystrokes for a single (possibly compound) compatibility jamo.
    static let keys: [Character: String] = {
        var map: [Character: String] = [:]
        for (key, jamo) in unshifted { map[jamo] = String(key) }
        for (key, jamo) in shifted { map[jamo] = String(key) }
        for (pair, compound) in compoundVowels { map[compound] = map[pair.first]! + map[pair.second]! }
        for (pair, compound) in compoundFinals { map[compound] = map[pair.first]! + map[pair.second]! }
        return map
    }()

    // MARK: Syllable tables (Unicode order)

    static let initials: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let medials: [Character] = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    /// Index 0 is "no final consonant".
    static let finals: [Character?] = [nil] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ").map { Optional($0) }

    static let initialIndex: [Character: Int] = Dictionary(uniqueKeysWithValues: initials.enumerated().map { ($1, $0) })
    static let medialIndex: [Character: Int] = Dictionary(uniqueKeysWithValues: medials.enumerated().map { ($1, $0) })
    static let finalIndex: [Character: Int] = Dictionary(uniqueKeysWithValues: finals.enumerated().compactMap { i, c in c.map { ($0, i) } })

    static let compoundVowels: [Pair: Character] = [
        Pair("ㅗ", "ㅏ"): "ㅘ", Pair("ㅗ", "ㅐ"): "ㅙ", Pair("ㅗ", "ㅣ"): "ㅚ",
        Pair("ㅜ", "ㅓ"): "ㅝ", Pair("ㅜ", "ㅔ"): "ㅞ", Pair("ㅜ", "ㅣ"): "ㅟ",
        Pair("ㅡ", "ㅣ"): "ㅢ",
    ]

    static let compoundFinals: [Pair: Character] = [
        Pair("ㄱ", "ㅅ"): "ㄳ", Pair("ㄴ", "ㅈ"): "ㄵ", Pair("ㄴ", "ㅎ"): "ㄶ",
        Pair("ㄹ", "ㄱ"): "ㄺ", Pair("ㄹ", "ㅁ"): "ㄻ", Pair("ㄹ", "ㅂ"): "ㄼ",
        Pair("ㄹ", "ㅅ"): "ㄽ", Pair("ㄹ", "ㅌ"): "ㄾ", Pair("ㄹ", "ㅍ"): "ㄿ",
        Pair("ㄹ", "ㅎ"): "ㅀ", Pair("ㅂ", "ㅅ"): "ㅄ",
    ]

    /// Reverse of `compoundFinals`, used to split a final when a vowel follows.
    static let splitFinals: [Character: Pair] = Dictionary(uniqueKeysWithValues: compoundFinals.map { ($1, $0) })

    static func isConsonant(_ c: Character) -> Bool { initialIndex[c] != nil }
    static func isVowel(_ c: Character) -> Bool { medialIndex[c] != nil }

    struct Pair: Hashable {
        let first: Character
        let second: Character
        init(_ a: Character, _ b: Character) { first = a; second = b }
    }

    // MARK: Unicode ranges

    static let syllableBase: UInt32 = 0xAC00
    static let syllableLast: UInt32 = 0xD7A3
    static let medialCount = 21
    static let finalCount = 28
}
