import Foundation

/// Exact membership in the large bundled RU/EN fallback dictionaries.
///
/// The resources are sorted 64-bit FNV-1a hashes and are memory-mapped. This
/// keeps roughly 2.5 million forms available without materializing millions
/// of Swift `String` objects. They are deliberately a weaker signal than the
/// curated technical list and the operating-system spellchecker.
public enum BundledLexicon {
    private static let russian = try? HashedWordLexicon(resource: "ru_words")
    private static let english = try? HashedWordLexicon(resource: "en_words")

    public static func supports(language: String) -> Bool {
        return switch language.lowercased().prefix(2) {
        case "ru": russian != nil
        case "en": english != nil
        default: false
        }
    }

    public static func contains(_ word: String, language: String) -> Bool {
        guard !word.isEmpty, word.allSatisfy(\.isLetter) else { return false }
        return switch language.lowercased().prefix(2) {
        case "ru": russian?.contains(word.lowercased()) == true
        case "en": english?.contains(word.lowercased()) == true
        default: false
        }
    }

    public static func count(language: String) -> Int {
        return switch language.lowercased().prefix(2) {
        case "ru": russian?.count ?? 0
        case "en": english?.count ?? 0
        default: 0
        }
    }
}

private struct HashedWordLexicon: @unchecked Sendable {
    private static let magic = Array("LSLEX1\0\0".utf8)
    private static let headerSize = 16
    private static let offsetBasis: UInt64 = 0xCBF29CE484222325
    private static let prime: UInt64 = 0x100000001B3

    private let data: Data
    let count: Int

    init(resource: String) throws {
        guard let url = SwitcherCoreResources.bundle.url(forResource: resource, withExtension: "fnv64") else {
            throw LexiconError.missingResource(resource)
        }
        let mapped = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard mapped.count >= Self.headerSize,
              Array(mapped.prefix(8)) == Self.magic else {
            throw LexiconError.invalidHeader(resource)
        }
        let storedCount = mapped.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        guard storedCount <= UInt64(Int.max),
              mapped.count == Self.headerSize + Int(storedCount) * MemoryLayout<UInt64>.size else {
            throw LexiconError.invalidLength(resource)
        }
        data = mapped
        count = Int(storedCount)
    }

    func contains(_ word: String) -> Bool {
        let needle = Self.fnv1a64(word)
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            let candidate = value(at: middle)
            if candidate < needle {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < count && value(at: low) == needle
    }

    private func value(at index: Int) -> UInt64 {
        data.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(
                fromByteOffset: Self.headerSize + index * MemoryLayout<UInt64>.size,
                as: UInt64.self
            ))
        }
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var result = offsetBasis
        for byte in value.utf8 {
            result ^= UInt64(byte)
            result = result &* prime
        }
        return result
    }

    private enum LexiconError: Error {
        case missingResource(String)
        case invalidHeader(String)
        case invalidLength(String)
    }
}
