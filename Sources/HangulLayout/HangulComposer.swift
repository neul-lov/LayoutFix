/// Composes a stream of jamo into Hangul syllables the way a Dubeolsik input method does.
///
/// State is one syllable block in progress: initial (choseong), medial (jungseong) and
/// final (jongseong). Rules:
/// - A consonant after a vowel becomes the final, or merges into a compound final (ㄹ+ㄱ=ㄺ).
/// - A vowel after a final steals it (or the second half of a compound final) as the
///   initial of a new syllable: 닭 + ㅏ → 달가.
/// - Vowels merge into compound vowels when possible (ㅗ+ㅏ=ㅘ).
/// - ㄸ, ㅃ, ㅉ can never be finals and start a new syllable instead.
/// - Two lone consonants that form a compound final merge into it (ㄱ+ㅅ = ㄳ, ㅂ+ㅅ = ㅄ), as
///   the system input method does; a following vowel takes the second half back (ㄳ+ㅏ = ㄱ사).
/// - A lone consonant or vowel is emitted as a compatibility jamo.
struct HangulComposer {
    private var initial: Character?
    private var medial: Character?
    private var final: Character?
    private(set) var output = ""

    mutating func feed(jamo c: Character) {
        if Dubeolsik.isVowel(c) {
            feedVowel(c)
        } else {
            feedConsonant(c)
        }
    }

    /// Jamo already present in the text start a fresh block, so existing jamo never merge with
    /// each other ("ㅂㅅ" stays as typed); keystrokes that follow can still attach (ㅎ + k → 하).
    mutating func feed(existingJamo c: Character) {
        flush()
        feed(jamo: c)
    }

    /// Any non-jamo character ends the current syllable and is copied through unchanged.
    mutating func feed(other c: Character) {
        flush()
        output.append(c)
    }

    mutating func finish() -> String {
        flush()
        return output
    }

    private mutating func feedConsonant(_ c: Character) {
        switch (initial, medial, final) {
        case (_, .some, nil) where initial != nil:
            // 가 + ㄴ → 간, unless the consonant cannot be a final (ㄸㅃㅉ).
            if Dubeolsik.finalIndex[c] != nil {
                final = c
            } else {
                flush()
                initial = c
            }
        case (.some, .some, .some(let f)):
            if let compound = Dubeolsik.compoundFinals[.init(f, c)] {
                final = compound
            } else {
                flush()
                initial = c
            }
        case (.some(let i), nil, nil):
            if let compound = Dubeolsik.compoundFinals[.init(i, c)] {
                initial = compound // lone compound consonant, e.g. ㄳ
            } else {
                flush()
                initial = c
            }
        default:
            // Empty or lone vowel: start a new block.
            flush()
            initial = c
        }
    }

    private mutating func feedVowel(_ v: Character) {
        switch (initial, medial, final) {
        case (.some(let i), nil, nil) where Dubeolsik.splitFinals[i] != nil:
            // Lone compound consonant + vowel: ㄳ + ㅏ → ㄱ + 사.
            let split = Dubeolsik.splitFinals[i]!
            initial = split.first
            flush()
            initial = split.second
            medial = v
        case (_, nil, nil):
            // Empty → lone vowel; lone initial → initial + vowel.
            medial = v
        case (_, .some(let m), nil):
            if let compound = Dubeolsik.compoundVowels[.init(m, v)] {
                medial = compound
            } else {
                flush()
                medial = v
            }
        case (.some, .some, .some(let f)):
            // The final (or its second half) moves to the next syllable.
            let carried: Character
            if let split = Dubeolsik.splitFinals[f] {
                final = split.first
                carried = split.second
            } else {
                final = nil
                carried = f
            }
            flush()
            initial = carried
            medial = v
        default:
            flush()
            medial = v
        }
    }

    private mutating func flush() {
        defer { initial = nil; medial = nil; final = nil }
        switch (initial, medial) {
        case (.some(let i), .some(let m)):
            let li = Dubeolsik.initialIndex[i]!
            let vi = Dubeolsik.medialIndex[m]!
            let ti = final.flatMap { Dubeolsik.finalIndex[$0] } ?? 0
            let value = Dubeolsik.syllableBase
                + UInt32((li * Dubeolsik.medialCount + vi) * Dubeolsik.finalCount + ti)
            output.unicodeScalars.append(Unicode.Scalar(value)!)
        case (.some(let i), nil):
            output.append(i)
        case (nil, .some(let m)):
            output.append(m)
        case (nil, nil):
            break
        }
    }
}
