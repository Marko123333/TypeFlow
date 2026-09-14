import Testing
@testable import SwitcherCore
import Foundation

@Suite("Bundled Russian lexicon")
struct BundledRussianLexiconTests {
    @Test func findsPackagedResourcesInsideMacOSContentsResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflow-resource-test-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("TypeFlow_SwitcherCore.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = bundleURL.appendingPathComponent("marker.txt")
        try Data("ok".utf8).write(to: marker)

        let bundle = SwitcherCoreResources.packagedBundle(in: root)
        #expect(bundle?.url(forResource: "marker", withExtension: "txt") == marker)
    }

    @Test func loadsLargeFallbackDictionaries() {
        #expect(BundledLexicon.count(language: "ru") == 2_323_330)
        #expect(BundledLexicon.count(language: "en") == 148_957)
        #expect(BundledLexicon.contains("гиперспектральный", language: "ru"))
        #expect(BundledLexicon.contains("colourisation", language: "en"))
        #expect(!BundledLexicon.contains("ыыррррр", language: "ru"))
        #expect(!BundledLexicon.contains("qqqqqqq", language: "en"))
    }

    @Test func loadsPinnedYoDictionary() {
        let restorer = BundledRussianLexicon.makeYoRestorer()
        #expect(restorer.restore("елка") == .restored("ёлка"))
        #expect(restorer.restore("еще") == .restored("ещё"))
        #expect(restorer.restore("авиаперелетов") == .restored("авиаперелётов"))
    }

    @Test func protectsKnownSemanticAmbiguities() {
        let restorer = BundledRussianLexicon.makeYoRestorer()
        #expect(restorer.restore("все") == .ambiguous(["все", "всё"]))
        #expect(restorer.restore("небо") == .ambiguous(["небо", "нёбо"]))
        #expect(restorer.restore("осел") == .ambiguous(["осел", "осёл"]))
    }
}
