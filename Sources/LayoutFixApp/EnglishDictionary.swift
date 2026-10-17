import AppKit

/// English word lookup for `auto` mode, backed by the system spell checker. It runs locally,
/// is only given the single word being checked, and learns nothing.
@MainActor
enum EnglishDictionary {
    static func isWord(_ word: String) -> Bool {
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return misspelled.location == NSNotFound
    }
}
