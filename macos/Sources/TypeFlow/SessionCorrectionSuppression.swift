import Foundation

/// Remembers auto-corrections the user immediately rejected with Backspace or
/// Undo. Each spelling is skipped once: this lets the user insist on an unusual
/// form without accidentally disabling a normal correction for the whole app
/// session.
struct SessionCorrectionSuppression {
    private(set) var words: Set<String> = []

    mutating func remember(original: String, alternatives: some Sequence<String>) {
        insert(original)
        for alternative in alternatives { insert(alternative) }
    }

    mutating func consume(_ word: String) -> Bool {
        words.remove(normalize(word)) != nil
    }

    private mutating func insert(_ word: String) {
        let normalized = normalize(word)
        if !normalized.isEmpty { words.insert(normalized) }
    }

    private func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
