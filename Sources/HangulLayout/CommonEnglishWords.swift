/// High-frequency English words that `auto` must never turn into Hangul.
///
/// Many of them compose into plausible syllables ("the" → 솓, "and" → 뭉, "go" → 해), so the
/// shape heuristic alone cannot reject them. A few collide with common Korean words typed in
/// the wrong layout ("so" → 내, "go" → 해, "do" → 애, "to" → 새); `auto` treats those as
/// ambiguous and refuses, and the explicit English → Korean shortcut still converts them.
enum CommonEnglishWords {
    static let words: Set<String> = [
        "the", "be", "to", "of", "and", "in", "that", "have", "it", "for", "not", "on", "with", "he",
        "as", "you", "do", "at", "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
        "or", "an", "will", "my", "one", "all", "would", "there", "their", "what", "so", "up", "out",
        "if", "about", "who", "get", "which", "go", "me", "when", "make", "can", "like", "time", "no",
        "just", "him", "know", "take", "people", "into", "year", "your", "good", "some", "could",
        "them", "see", "other", "than", "then", "now", "look", "only", "come", "its", "over", "think",
        "also", "back", "after", "use", "two", "how", "our", "work", "first", "well", "way", "even",
        "new", "want", "because", "any", "these", "give", "day", "most", "us", "is", "are", "was",
        "were", "been", "has", "had", "did", "does", "am", "yes", "ok", "okay", "hi", "hey", "thanks",
        "please", "sorry", "here", "where", "why", "very", "much", "more", "many", "too", "own",
        "same", "right", "left", "still", "never", "always", "again", "off", "down", "let", "put",
        "set", "run", "end", "big", "old", "long", "great", "little", "few", "last", "next", "high",
        "small", "large", "best", "better", "sure", "real", "free", "full", "open", "close", "done",
        "need", "feel", "try", "ask", "call", "keep", "help", "show", "tell", "turn", "start", "stop",
        "move", "live", "play", "read", "write", "find", "made", "said", "went", "got", "came", "seen",
        "today", "world", "life", "hand", "part", "place", "case", "week", "point", "home", "word",
        "fact", "name", "line", "test", "code", "data", "file", "user", "mode", "type", "text", "size",
        "list", "page", "item", "note", "app", "web", "mac", "key", "cat", "dog", "man", "car", "job",
        "fix", "bug", "add", "fine", "nice", "cool", "true", "false", "null", "nil", "void", "func",
        "var", "def", "class", "return", "import", "public", "static", "change", "suggest",
        "thing", "things", "something", "nothing", "everything", "should", "might", "must", "shall",
        "may", "being", "while", "before", "since", "until", "each", "every", "both", "either",
        "neither", "such", "far", "near", "soon", "late", "early", "fast", "slow", "hot",
        "cold", "yet", "ago", "via", "per", "etc", "lol", "omg", "btw", "idk",
    ]
}
