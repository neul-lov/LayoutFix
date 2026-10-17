/// Which way to convert. `auto` is conservative and refuses ambiguous input.
public enum ConversionDirection: String, CaseIterable, Codable, Sendable {
    case auto
    case englishToKorean
    case koreanToEnglish
}

/// A concrete direction after `auto` has been resolved.
public enum ResolvedDirection: String, Sendable, Equatable {
    case englishToKorean
    case koreanToEnglish
}

public enum ConversionRefusal: Error, Equatable, Sendable {
    /// Nothing in the text maps to the other layout, or the result equals the input.
    case unchanged
    /// `auto` saw both Hangul and Latin letters and will not guess.
    case mixedScripts
    /// `auto` saw only Latin letters but the result does not look like Korean (e.g. "hello").
    case looksLikeEnglish
}

public struct ConversionResult: Equatable, Sendable {
    public let text: String
    public let direction: ResolvedDirection
}

public enum LayoutConverter {
    /// Treats every ASCII letter as a Dubeolsik keystroke and composes Hangul.
    /// Lone jamo already in the text join the composition (ㅎ + "ksrmf" → 한글); all other
    /// characters (spaces, digits, punctuation, complete syllables) pass through.
    public static func englishToKorean(_ text: String) -> String {
        var composer = HangulComposer()
        for ch in undoingCapsLock(text) {
            if let jamo = Dubeolsik.jamo(forKey: ch) {
                composer.feed(jamo: jamo)
            } else if Dubeolsik.isConsonant(ch) || Dubeolsik.isVowel(ch) {
                composer.feed(existingJamo: ch)
            } else {
                composer.feed(other: ch)
            }
        }
        return composer.finish()
    }

    /// Caps Lock turns every letter uppercase, which in Dubeolsik would wrongly mean Shift
    /// (ㄲ ㄸ ㅃ ㅆ ㅉ ㅒ ㅖ). A run of 2+ letters that is entirely uppercase and contains a
    /// letter whose Shift means nothing in Dubeolsik (anything but Q W E R T O P) can only come
    /// from Caps Lock, so it is read unshifted ("DKSSUD" → 안녕). Runs made only of
    /// Q W E R T O P stay shifted ("RO" → 꺠), and mixed case keeps Shift ("dlTek" → 있다).
    static func undoingCapsLock(_ text: String) -> String {
        var out = ""
        var run = ""
        func flushRun() {
            let isCapsLock = run.count >= 2 && run.allSatisfy(\.isUppercase)
                && run.contains { Dubeolsik.shifted[$0] == nil }
            out += isCapsLock ? run.lowercased() : run
            run = ""
        }
        for ch in text {
            if ch.isASCII, ch.isLetter {
                run.append(ch)
            } else {
                flushRun()
                out.append(ch)
            }
        }
        flushRun()
        return out
    }

    /// Decomposes Hangul (precomposed syllables, compatibility jamo, or NFD conjoining jamo)
    /// into the Dubeolsik keystrokes that would type it. Other characters pass through.
    /// A character (grapheme cluster) containing jamo that no Dubeolsik key produces, such as
    /// old Hangul (ᄒᆞᆫ) or fillers, is left untouched rather than half converted.
    public static func koreanToEnglish(_ text: String) -> String {
        var out = ""
        for ch in text {
            var keys = ""
            var unmappable = false
            for scalar in ch.unicodeScalars {
                if let k = keystrokes(for: scalar) {
                    keys += k
                } else if isHangul(scalar) {
                    unmappable = true
                    break
                } else {
                    keys.unicodeScalars.append(scalar)
                }
            }
            out += unmappable ? String(ch) : keys
        }
        return out
    }

    /// - Parameter isEnglishWord: optional dictionary lookup (e.g. the system spell checker)
    ///   consulted by `auto` for Latin words of 4+ letters. Shorter words are checked only
    ///   against the built-in list, because dictionaries accept many 2–3 letter abbreviations
    ///   that are also Korean typed in the wrong layout ("dl" = 이, "rm" = 그, "dk" = 아).
    public static func convert(_ text: String, direction: ConversionDirection,
                               isEnglishWord: ((String) -> Bool)? = nil) -> Result<ConversionResult, ConversionRefusal> {
        let resolved: ResolvedDirection
        switch direction {
        case .englishToKorean: resolved = .englishToKorean
        case .koreanToEnglish: resolved = .koreanToEnglish
        case .auto:
            let hangul = containsHangul(text)
            let latin = containsLatinLetter(text)
            switch (hangul, latin) {
            case (true, true): return .failure(.mixedScripts)
            case (true, false): resolved = .koreanToEnglish
            case (false, true): resolved = .englishToKorean
            case (false, false): return .failure(.unchanged)
            }
        }

        let output = resolved == .englishToKorean ? englishToKorean(text) : koreanToEnglish(text)
        if output == text { return .failure(.unchanged) }
        if direction == .auto, resolved == .englishToKorean,
           containsEnglishWord(text, isEnglishWord: isEnglishWord) || !looksLikeKorean(output) {
            return .failure(.looksLikeEnglish)
        }
        return .success(ConversionResult(text: output, direction: resolved))
    }

    // MARK: Classification

    public static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHangul)
    }

    public static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
    }

    /// True if any Latin word of 2+ letters in `text` is a known English word.
    static func containsEnglishWord(_ text: String, isEnglishWord: ((String) -> Bool)?) -> Bool {
        var word = ""
        func check() -> Bool {
            defer { word = "" }
            guard word.count >= 2 else { return false }
            let lower = word.lowercased()
            if CommonEnglishWords.words.contains(lower) { return true }
            return word.count >= 4 && isEnglishWord?(lower) == true
        }
        for scalar in text.unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic {
                word.unicodeScalars.append(scalar)
            } else if check() {
                return true
            }
        }
        return check()
    }

    /// Lone jamo that casual Korean puts after a word: ㅋㅋ, ㅎㅎ, ㄷㄷ, ㅇㅇ, ㅠㅠ, ㅜㅜ, ㅡㅡ.
    static let casualTailJamo: Set<UInt32> = [0x314B, 0x314E, 0x3137, 0x3147, 0x3160, 0x315C, 0x3161]
    /// Laughter that may also open a word: "ㅋㅋㅋ진짜", "ㅎㅎ그래".
    static let casualLeadJamo: Set<UInt32> = [0x314B, 0x314E]

    /// Shape check for `auto`, applied per whitespace-separated word of the converted text.
    /// Dubeolsik always attaches a consonant to the next vowel, so real Korean typing never
    /// leaves a lone vowel or a lone consonant in front of a syllable. After the last syllable,
    /// only a run of 2+ casual jamo is accepted ("안녕ㅋㅋ", "고마워ㅠㅠ"), and a word may open with
    /// 2+ ㅋ/ㅎ ("ㅋㅋㅋ진짜"). English words converted by
    /// mistake fail one of these: "hello" → "ㅗ디ㅣㅐ" (lone vowels), "test" → "ㅅㄷㄴㅅ"
    /// (no syllable), "Swift" → "ㄴ쟔" (leading consonant), "that" → "솜ㅅ" (stray final
    /// consonant), "there" → "솓ㄱㄷ" (mixed tail). Words that still compose cleanly are
    /// caught by `containsEnglishWord`; anything else ("risk" → "갸나") needs the explicit
    /// direction.
    static func looksLikeKorean(_ converted: String) -> Bool {
        enum Item { case syllable, consonant(UInt32), vowel(UInt32) }
        var hasSyllable = false
        var items: [Item] = []

        func wordIsPlausible() -> Bool {
            defer { items.removeAll() }
            guard let last = items.lastIndex(where: { if case .syllable = $0 { return true }; return false }) else {
                // No syllable: allowed only as casual jamo on their own ("ㅋㅋ") or no jamo at all.
                return items.isEmpty || (items.count >= 2 && items.allSatisfy(isCasual))
            }
            var start = 0
            while start < last, case .consonant(let v) = items[start], casualLeadJamo.contains(v) { start += 1 }
            if start == 1 { start = 0 } // a single leading consonant is a stray key, not laughter
            for item in items[start..<last] {
                if case .syllable = item { continue }
                return false
            }
            let tail = items[(last + 1)...]
            return tail.isEmpty || (tail.count >= 2 && tail.allSatisfy(isCasual))
        }
        func isCasual(_ item: Item) -> Bool {
            switch item {
            case .syllable: return false
            case .consonant(let v), .vowel(let v): return casualTailJamo.contains(v)
            }
        }

        for scalar in converted.unicodeScalars {
            switch scalar.value {
            case Dubeolsik.syllableBase...Dubeolsik.syllableLast:
                items.append(.syllable)
                hasSyllable = true
            case 0x3131...0x314E:
                items.append(.consonant(scalar.value))
            case 0x314F...0x3163:
                items.append(.vowel(scalar.value))
            default:
                if scalar.properties.isWhitespace, !wordIsPlausible() { return false }
            }
        }
        return wordIsPlausible() && hasSyllable
    }

    static func isHangul(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0xAC00...0xD7A3, 0x3131...0x318E, 0x1100...0x11FF, 0xA960...0xA97F, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC: return true
        default: return false
        }
    }

    // MARK: Decomposition

    private static func keystrokes(for scalar: Unicode.Scalar) -> String? {
        let v = scalar.value
        switch v {
        case Dubeolsik.syllableBase...Dubeolsik.syllableLast:
            let index = Int(v - Dubeolsik.syllableBase)
            let li = index / (Dubeolsik.medialCount * Dubeolsik.finalCount)
            let vi = (index % (Dubeolsik.medialCount * Dubeolsik.finalCount)) / Dubeolsik.finalCount
            let ti = index % Dubeolsik.finalCount
            var keys = Dubeolsik.keys[Dubeolsik.initials[li]]! + Dubeolsik.keys[Dubeolsik.medials[vi]]!
            if let f = Dubeolsik.finals[ti] { keys += Dubeolsik.keys[f]! }
            return keys
        case 0x3131...0x318E:
            return Dubeolsik.keys[Character(scalar)]
        case 0x1100...0x1112: // conjoining initials (NFD)
            return Dubeolsik.keys[Dubeolsik.initials[Int(v - 0x1100)]]
        case 0x1161...0x1175: // conjoining medials
            return Dubeolsik.keys[Dubeolsik.medials[Int(v - 0x1161)]]
        case 0x11A8...0x11C2: // conjoining finals
            return Dubeolsik.finals[Int(v - 0x11A7)].flatMap { Dubeolsik.keys[$0] }
        default:
            return nil
        }
    }
}
