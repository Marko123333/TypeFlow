import Foundation

public enum BundledRussianLexicon {
    /// Builds a restorer from the generated, pinned eyo-kernel resources.
    /// Unsafe forms are paired with their plain-е spelling, making them
    /// explicitly ambiguous so YoRestorer cannot apply them automatically.
    /// Loading is local-only and deterministic; no network request is made.
    public static func makeYoRestorer() -> YoRestorer {
        let safe = load("yo_safe_forms")
        let unsafe = load("yo_unsafe_forms")
        let ambiguityBlockers = unsafe.map(YoRestorer.withoutYo)
        return YoRestorer(words: safe + unsafe + ambiguityBlockers)
    }

    private static func load(_ resource: String) -> [String] {
        guard let url = SwitcherCoreResources.bundle.url(forResource: resource, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(whereSeparator: \.isNewline).compactMap { row -> String? in
            guard !row.hasPrefix("#") else { return nil }
            let word = row.trimmingCharacters(in: .whitespaces)
            return word.isEmpty ? nil : word
        }
    }
}
