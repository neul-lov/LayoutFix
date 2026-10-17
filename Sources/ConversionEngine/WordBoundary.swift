public enum WordBoundary {
    public struct Match: Equatable, Sendable {
        /// Offset of the word from the start of the searched text, in UTF-16 units.
        public let utf16Start: Int
        public let utf16Length: Int
        public let word: String
        /// Spaces/tabs between the end of the word and the caret, in UTF-16 units.
        public let trailingWhitespaceUTF16: Int
    }

    /// Finds the last word in `text`, which is the text immediately before the caret.
    ///
    /// A word is a run of non-whitespace characters, so punctuation typed with the word
    /// stays attached ("dkssud," → "안녕,"); conversion leaves punctuation unchanged anyway.
    /// Spaces and tabs between the word and the caret are skipped, line breaks are not:
    /// a caret at the start of a line has no previous word.
    public static func lastWord(in text: String) -> Match? {
        var index = text.endIndex
        var trailing = 0
        while index > text.startIndex {
            let previous = text.index(before: index)
            let ch = text[previous]
            guard ch == " " || ch == "\t" || ch == "\u{00A0}" else { break }
            trailing += ch.utf16.count
            index = previous
        }
        let wordEnd = index
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous].isWhitespace { break }
            index = previous
        }
        guard index < wordEnd else { return nil }
        let start = text.utf16.distance(from: text.utf16.startIndex, to: index)
        let word = String(text[index..<wordEnd])
        return Match(utf16Start: start, utf16Length: word.utf16.count, word: word, trailingWhitespaceUTF16: trailing)
    }

    /// Validates text grabbed with ⌥⇧← in the keyboard path: one word plus optional trailing
    /// spaces, no line breaks. Returns nil if it is anything else.
    static func singleWordWithTrailingSpace(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains(where: \.isNewline) else { return nil }
        guard let match = lastWord(in: text), match.utf16Start == 0 else { return nil }
        return text
    }
}
