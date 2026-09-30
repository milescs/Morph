import Foundation

/// Splits a command-line string into arguments (quotes and backslash escapes), without a shell.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaping = false

        for ch in text {
            if escaping {
                current.append(ch)
                escaping = false
                inWord = true
                continue
            }
            if ch == "\\" && quote != "'" {
                escaping = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                inWord = true
                continue
            }
            if ch.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
                continue
            }
            current.append(ch)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }

    /// Quotes an argument for display (e.g. "Show command").
    public static func quote(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=,+@%^"))
        if !word.isEmpty && word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
