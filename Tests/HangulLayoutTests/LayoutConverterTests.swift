import Testing
@testable import HangulLayout

@Suite("English keystrokes → Korean")
struct EnglishToKoreanTests {
    @Test("Required examples", arguments: [
        ("dkssudgktpdy", "안녕하세요"),
        ("gksrmf", "한글"),
    ])
    func requiredExamples(input: String, expected: String) {
        #expect(LayoutConverter.englishToKorean(input) == expected)
    }

    @Test("Initial consonant + vowel, including shifted double consonants", arguments: [
        ("rk", "가"), ("Rk", "까"), ("Ek", "따"), ("Qk", "빠"), ("Tk", "싸"), ("Wk", "짜"),
        ("gh", "호"), ("dl", "이"), ("zz", "ㅋㅋ"),
    ])
    func initialsAndVowels(input: String, expected: String) {
        #expect(LayoutConverter.englishToKorean(input) == expected)
    }

    @Test("Final consonants, double finals, and finals moving to the next syllable", arguments: [
        ("rkr", "각"), ("rkR", "갂"), ("dlTek", "있다"), ("rkrk", "가가"),
        ("dkssud", "안녕"), ("sjan", "너무"), ("sjans", "너문"), ("Ekfkr", "따락"),
        // ㄸ ㅃ ㅉ can never be finals:
        ("rkE", "가ㄸ"), ("rkQk", "가빠"),
    ])
    func finals(input: String, expected: String) {
        #expect(LayoutConverter.englishToKorean(input) == expected)
    }

    @Test("Compound final consonants and splitting them before a vowel", arguments: [
        ("ekfr", "닭"), ("ekfrdl", "닭이"), ("ekfrk", "달가"),
        ("dksw", "앉"), ("dkswdk", "앉아"), ("dkswk", "안자"), ("whgdms", "좋은"), ("dlfrdj", "읽어"),
        ("rkqt", "값"), ("rkqtdl", "값이"), ("tkfa", "삶"), ("dlfgek", "잃다"),
        ("rhkdtk", "광사"), ("ahrt", "몫"),
    ])
    func compoundFinals(input: String, expected: String) {
        #expect(LayoutConverter.englishToKorean(input) == expected)
    }

    @Test("Compound vowels", arguments: [
        ("ghk", "화"), ("dho", "왜"), ("ghl", "회"), ("dnj", "워"), ("dnp", "웨"),
        ("dnl", "위"), ("dml", "의"), ("ghkdl", "화이"), ("rhks", "관"), ("dnjs", "원"),
        ("dhkd", "왕"), ("hk", "ㅘ"), // vowel with no initial stays a lone (compound) jamo
    ])
    func compoundVowels(input: String, expected: String) {
        #expect(LayoutConverter.englishToKorean(input) == expected)
    }

    @Test("Spaces, digits, punctuation and line breaks are preserved")
    func preservesNonLetters() {
        #expect(LayoutConverter.englishToKorean("dkssud, gksrmf! 123 (rk)") == "안녕, 한글! 123 (가)")
        #expect(LayoutConverter.englishToKorean("gks\trmf\n2024.") == "한\t글\n2024.")
        #expect(LayoutConverter.englishToKorean("") == "")
        #expect(LayoutConverter.englishToKorean("123 !?") == "123 !?")
    }

    @Test("Caps Lock / Shift on non-double keys gives the same jamo")
    func uppercaseLetters() {
        // Whole words in capitals are Caps Lock, not Shift.
        #expect(LayoutConverter.englishToKorean("DKSSUD") == "안녕")
        #expect(LayoutConverter.englishToKorean("GKSRMF") == "한글")
        #expect(LayoutConverter.englishToKorean("DKSSUDGKTPDY") == "안녕하세요")
        #expect(LayoutConverter.englishToKorean("TKFKDGO") == "사랑해")
        // Mixed case keeps Dubeolsik Shift: Q W E R T O P give ㅃ ㅉ ㄸ ㄲ ㅆ ㅒ ㅖ.
        #expect(LayoutConverter.englishToKorean("dlTek") == "있다")
        #expect(LayoutConverter.englishToKorean("Rk") == "까")
        #expect(LayoutConverter.englishToKorean("T") == "ㅆ")
        #expect(LayoutConverter.englishToKorean("RO") == "꺠")
        #expect(LayoutConverter.englishToKorean("TT") == "ㅆㅆ")
    }

    @Test("Two lone consonants form a compound jamo like the system input method; a vowel takes one back")
    func loneCompoundConsonants() {
        #expect(LayoutConverter.englishToKorean("rt") == "ㄳ")
        #expect(LayoutConverter.englishToKorean("qt") == "ㅄ")
        #expect(LayoutConverter.englishToKorean("rtk") == "ㄱ사")
        #expect(LayoutConverter.englishToKorean(LayoutConverter.koreanToEnglish("ㅄ")) == "ㅄ")
        // Jamo already in the text are not merged with each other.
        #expect(LayoutConverter.convert("ㅂㅅ", direction: .englishToKorean) == .failure(.unchanged))
    }

    @Test("Lone jamo already in the text join the composition")
    func existingJamo() {
        #expect(LayoutConverter.englishToKorean("ㅎksrmf") == "한글")
        #expect(LayoutConverter.englishToKorean("안녕 gktpdy") == "안녕 하세요")
    }
}

@Suite("Korean → English keystrokes")
struct KoreanToEnglishTests {
    @Test("Required example")
    func requiredExample() {
        #expect(LayoutConverter.koreanToEnglish("안녕") == "dkssud")
    }

    @Test("Syllables, finals, compounds and double consonants", arguments: [
        ("안녕하세요", "dkssudgktpdy"), ("한글", "gksrmf"), ("닭", "ekfr"), ("값", "rkqt"),
        ("화", "ghk"), ("의", "dml"), ("있다", "dlTek"), ("까", "Rk"), ("얘", "dO"), ("예", "dP"),
    ])
    func syllables(input: String, expected: String) {
        #expect(LayoutConverter.koreanToEnglish(input) == expected)
    }

    @Test("Lone compatibility jamo, including compound ones")
    func compatibilityJamo() {
        #expect(LayoutConverter.koreanToEnglish("ㅋㅋㅋ") == "zzz")
        #expect(LayoutConverter.koreanToEnglish("ㅘ") == "hk")
        #expect(LayoutConverter.koreanToEnglish("ㄳ") == "rt")
    }

    @Test("NFD (conjoining jamo) input, as found in macOS file names")
    func decomposedInput() {
        let nfd = "\u{1100}\u{1161}\u{11A8}" // 각 decomposed
        #expect(LayoutConverter.koreanToEnglish(nfd) == "rkr")
    }

    @Test("Characters with jamo no key produces (old Hangul, fillers) are left whole")
    func unmappableClusters() {
        let oldHangul = "\u{1112}\u{119E}\u{11AB}" // ᄒᆞᆫ
        #expect(LayoutConverter.koreanToEnglish(oldHangul) == oldHangul)
        #expect(LayoutConverter.koreanToEnglish("가\u{11F0}") == "가\u{11F0}")
        #expect(LayoutConverter.koreanToEnglish("\u{A960}\u{1161}") == "\u{A960}\u{1161}")
        #expect(LayoutConverter.koreanToEnglish("한 \u{1112}\u{119E}\u{11AB}") == "gks \u{1112}\u{119E}\u{11AB}")
    }

    @Test("Spaces, digits and punctuation are preserved")
    func preservesNonHangul() {
        #expect(LayoutConverter.koreanToEnglish("안녕, 한글! 123") == "dkssud, gksrmf! 123")
        #expect(LayoutConverter.koreanToEnglish("abc 안녕") == "abc dkssud")
    }
}

@Suite("Round trips")
struct RoundTripTests {
    @Test("Every precomposed syllable round-trips through its keystrokes")
    func everySyllable() {
        var failures: [String] = []
        for value in UInt32(0xAC00)...UInt32(0xD7A3) {
            let s = String(Character(Unicode.Scalar(value)!))
            let back = LayoutConverter.englishToKorean(LayoutConverter.koreanToEnglish(s))
            if back != s { failures.append(s) }
        }
        #expect(failures.isEmpty, "Failed: \(failures.prefix(20))")
    }

    @Test("Random syllable sequences round-trip")
    func randomSequences() {
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<2000 {
            let length = Int(rng.next() % 8) + 1
            let s = String((0..<length).map { _ in
                Character(Unicode.Scalar(UInt32(0xAC00) + UInt32(rng.next() % 11172))!)
            })
            let keys = LayoutConverter.koreanToEnglish(s)
            #expect(LayoutConverter.englishToKorean(keys) == s, "\(keys)")
        }
    }
}

@Suite("Direction selection")
struct DirectionTests {
    @Test("Explicit directions always apply")
    func explicit() throws {
        let toKorean = try LayoutConverter.convert("hello", direction: .englishToKorean).get()
        #expect(toKorean.text == "ㅗ디ㅣㅐ")
        let toEnglish = try LayoutConverter.convert("안녕", direction: .koreanToEnglish).get()
        #expect(toEnglish.text == "dkssud")
    }

    @Test("Auto converts mistyped Korean and Korean text")
    func autoConverts() throws {
        #expect(try LayoutConverter.convert("dkssudgktpdy", direction: .auto).get().text == "안녕하세요")
        #expect(try LayoutConverter.convert("gksrmf", direction: .auto).get().direction == .englishToKorean)
        #expect(try LayoutConverter.convert("안녕", direction: .auto).get().text == "dkssud")
    }

    @Test("Auto refuses valid-looking English words", arguments: ["hello", "test", "street", "Swift", "macOS", "apple", "keyboard"])
    func autoRefusesEnglish(word: String) {
        let result = LayoutConverter.convert(word, direction: .auto)
        #expect(result == .failure(.looksLikeEnglish))
    }

    @Test("Auto refuses common English words that compose into plausible syllables", arguments: [
        "the", "that", "and", "for", "with", "there", "code", "today", "world", "what", "when", "then",
        "first", "change", "size", "sure", "right", "work", "they", "suggest", "class", "to", "do", "go",
        "so", "The", "THAT", "the end", "dkssud the",
    ])
    func autoRefusesCommonEnglish(word: String) {
        #expect(LayoutConverter.convert(word, direction: .auto) == .failure(.looksLikeEnglish))
    }

    @Test("Explicit English → Korean still converts those words")
    func explicitConvertsCommonEnglish() throws {
        #expect(try LayoutConverter.convert("go", direction: .englishToKorean).get().text == "해")
        #expect(try LayoutConverter.convert("the", direction: .englishToKorean).get().text == "솓")
    }

    @Test("Auto keeps casual Korean such as trailing ㅋㅋ and ㅠㅠ", arguments: [
        ("dkssudzz", "안녕ㅋㅋ"), ("dkssudgktpdybb", "안녕하세요ㅠㅠ"), ("dkssud zzz", "안녕 ㅋㅋㅋ"),
        ("rmfjsep", "그런데"), ("dkssud, qksrkdnj!", "안녕, 반가워!"), ("dkssudgg", "안녕ㅎㅎ"),
        ("dkssud bb", "안녕 ㅠㅠ"), ("rhakdnjbb", "고마워ㅠㅠ"), ("tlfgdj mm", "싫어 ㅡㅡ"), ("zzzwlsWk", "ㅋㅋㅋ진짜"),
    ])
    func autoAllowsCasualKorean(input: String, expected: String) throws {
        #expect(try LayoutConverter.convert(input, direction: .auto).get().text == expected)
    }

    @Test("Shape rule: stray or mixed trailing consonants are not Korean typing")
    func shapeRule() {
        #expect(!LayoutConverter.looksLikeKorean("솜ㅅ"))
        #expect(!LayoutConverter.looksLikeKorean("솓ㄱㄷ"))
        #expect(!LayoutConverter.looksLikeKorean("녛ㅎㄷㄴㅅ"))
        #expect(!LayoutConverter.looksLikeKorean("당ㅎ"))
        #expect(!LayoutConverter.looksLikeKorean("ㅋㅋ"))
        #expect(LayoutConverter.looksLikeKorean("안녕 ㅋㅋ"))
        #expect(LayoutConverter.looksLikeKorean("안녕ㅋㅋㅎㅎ"))
        #expect(LayoutConverter.looksLikeKorean("ㅋㅋ진짜"))
        #expect(!LayoutConverter.looksLikeKorean("ㅋ진짜"))
        #expect(!LayoutConverter.looksLikeKorean("ㄱㄱ진짜"))
    }

    @Test("Dictionary lookup refuses longer English words but never short Korean")
    func dictionaryLookup() throws {
        // Dictionaries accept abbreviations such as "dl" or "rm"; those are 이 and 그 typed in
        // the wrong layout, so 2–3 letter words never reach the lookup.
        let acceptsEverything: (String) -> Bool = { _ in true }
        #expect(try LayoutConverter.convert("dl", direction: .auto, isEnglishWord: acceptsEverything).get().text == "이")
        #expect(try LayoutConverter.convert("dmd", direction: .auto, isEnglishWord: acceptsEverything).get().text == "응")
        #expect(LayoutConverter.convert("risk", direction: .auto, isEnglishWord: { $0 == "risk" }) == .failure(.looksLikeEnglish))
        #expect(try LayoutConverter.convert("gksrmf", direction: .auto, isEnglishWord: { $0 == "risk" }).get().text == "한글")
    }

    @Test("Without a dictionary, uncommon English words can still look like Korean")
    func autoHeuristicLimit() {
        // "risk" composes into the valid syllables "갸나" and is not in the built-in list.
        // The app passes the system spell checker, which catches it; see dictionaryLookup().
        #expect((try? LayoutConverter.convert("risk", direction: .auto).get().text) == "갸나")
    }

    @Test("Auto refuses mixed Korean and Latin text")
    func autoRefusesMixed() {
        #expect(LayoutConverter.convert("안녕 dkssud", direction: .auto) == .failure(.mixedScripts))
    }

    @Test("Nothing convertible means unchanged, never a rewrite")
    func unchanged() {
        #expect(LayoutConverter.convert("123 !?", direction: .auto) == .failure(.unchanged))
        #expect(LayoutConverter.convert("안녕", direction: .englishToKorean) == .failure(.unchanged))
        #expect(LayoutConverter.convert("dkssud", direction: .koreanToEnglish) == .failure(.unchanged))
        #expect(LayoutConverter.convert("", direction: .auto) == .failure(.unchanged))
    }
}

/// Small deterministic RNG so the property test is reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
