import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import TypeFlow

@Suite("Ordered automatic replacement")
@MainActor
struct FastInputTests {
    @Test func fastPhraseKeepsShortWordsAfterCorrections() {
        // Each following key arrives immediately after the previous callback,
        // with no run-loop turn for an asynchronous replacement to catch up.
        for _ in 0..<100 {
            let input = InputFixture()
            input.replacements = ["ПРоживаю": "Проживаю", "в": "в", "деревне": "деревне",
                                  "еще": "ещё", "ПРивет": "Привет"]
            input.type("ПРоживаю в деревне еще ПРивет в деревне ")
            #expect(input.text == "Проживаю в деревне ещё Привет в деревне ")
        }
    }

    @Test func firstBoundaryConvertsWithoutWaitingForNextWord() {
        #expect(LayoutDetector.decide(
            typed: "ghbdtn", converted: "привет", currentLang: "en", otherLang: "ru", capsLock: false
        ) == .switchToConverted)
        let input = InputFixture()
        input.replacements = ["ghbdtn": "привет"]
        input.type("ghbdtn ")
        #expect(input.text == "привет ")
        #expect(input.replacementsApplied == 1)
        input.type("в деревне ")
        #expect(input.text == "привет в деревне ")
    }

    @Test func punctuationAndRepeatedSpacesStayBeforeNextInitials() {
        let input = InputFixture()
        input.replacements = ["ghbdtn,": "привет,"]
        input.type("(ghbdtn,  d derevne ")
        #expect(input.text == "(привет,  d derevne ")
    }

    @Test func eachBoundaryCapturesItsOwnWordBeforeAnotherKeyArrives() {
        let monitor = KeyboardMonitor()
        var words: [String] = []
        monitor.onWordBoundary = { boundary in
            words.append(String(boundary.keys.compactMap { KeyMapping.keycodeToEN[$0.keyCode] }))
            monitor.markConverted()
        }
        for text in ["ghbdtn", "d", "lthtdyt"] {
            for ch in text {
                let key = KeyMapping.keycodeToEN.first(where: { $0.value == ch })!.key
                monitor.handleKeyDown(keyCode: key, flags: [])
            }
            monitor.handleKeyDown(keyCode: KC.space, flags: [])
            #expect(monitor.prevWordKeys.isEmpty)
            #expect(monitor.boundaryCount == 0)
            #expect(monitor.lineKeys.isEmpty)
        }
        #expect(words == ["ghbdtn", "d", "lthtdyt"])
    }

    @Test func shortcutSpaceDoesNotCorrectTextInPreviousField() {
        let monitor = KeyboardMonitor()
        var count = 0
        monitor.onWordBoundary = { _ in count += 1 }
        monitor.handleKeyDown(keyCode: 5, flags: [])
        monitor.handleKeyDown(keyCode: KC.space, flags: .maskCommand)
        #expect(count == 0)
        #expect(monitor.currentWordKeys.isEmpty)
        #expect(monitor.prevWordKeys.isEmpty)
    }

    @Test func nativeTextEditorAppliesTheBatchBeforeFollowingShortWord() throws {
        // This is an in-process NSTextView object. No window is opened and no
        // CGEvent is posted to macOS or to another application.
        let view = NSTextView(frame: .zero)
        view.isAutomaticSpellingCorrectionEnabled = false
        view.string = "ghj;bdf."
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        let converter = TextConverter()
        var delivered = 0
        #expect(converter.replaceAtWordBoundary(
            original: "ghj;bdf.", with: "проживаю", deadline: .infinity,
            postEvent: { event in
                if event.type == .keyDown, let native = NSEvent(cgEvent: event) {
                    view.interpretKeyEvents([native])
                    delivered += 1
                }
            }
        ))
        #expect(delivered == 9)
        #expect(view.string == "проживаю")
        // Deliver the physical boundary and following text only after the batch.
        view.insertText(" в деревне", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "проживаю в деревне")
    }

    @Test func expiredDecisionEmitsNoDestructiveEvents() {
        let converter = TextConverter()
        var count = 0
        #expect(!converter.replaceAtWordBoundary(
            original: "ghbdtn", with: "привет", deadline: 0,
            postEvent: { _ in count += 1 }
        ))
        #expect(count == 0)
    }

    @Test func boundaryBatchDeletesOnlyTheWordAndCarriesNoPhysicalModifiers() throws {
        let events = try #require(BoundaryReplacement(
            original: "ghbdtn", replacement: "привет", suffix: ",", selectWord: false
        ).makeEvents())
        let deletes = events.filter { $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == Int64(KC.backspace) }
        #expect(deletes.count == 7) // six letters + comma, without the pending space
        #expect(events.allSatisfy { $0.flags.isEmpty })
        #expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == kLocalSwitcherEventMarker })
        #expect(unicode(events[events.count - 2]) == "привет,")
    }

    @Test func spotlightUsesWordSelectionBeforePendingSpace() throws {
        let events = try #require(BoundaryReplacement(
            original: "ghbdtn", replacement: "привет", suffix: "", selectWord: true
        ).makeEvents())
        #expect(events.count == 4)
        #expect(events[0].getIntegerValueField(.keyboardEventKeycode) == Int64(KC.left))
        #expect(events[0].flags == [.maskShift, .maskAlternate])
        #expect(unicode(events[2]) == "привет")
        #expect(BoundaryReplacement(original: "ghbdtn", replacement: "привет", suffix: ",", selectWord: true).makeEvents() == nil)
    }
}

@MainActor
private final class InputFixture {
    let monitor = KeyboardMonitor()
    let converter = TextConverter()
    var replacements: [String: String] = [:]
    var text = ""
    var replacementsApplied = 0
    private var pendingWord = ""

    init() {
        monitor.onWordBoundary = { [unowned self] boundary in
            let original = String(pendingWord.suffix(boundary.keys.count))
            if let replacement = replacements[original], original != replacement,
               converter.replaceAtWordBoundary(
                original: original, with: replacement, deadline: boundary.deadline,
                postEvent: { [unowned self] in receive($0) }
               ) {
                monitor.markConverted()
                replacementsApplied += 1
            }
            pendingWord = ""
        }
    }

    func type(_ string: String) {
        for ch in string {
            let key = ch == " " ? KC.space : ch == "(" ? 25 : KeyMapping.keycodeToEN.first(where: { $0.value == ch })?.key ?? 0
            if ch != " " { pendingWord.append(ch) }
            monitor.handleKeyDown(keyCode: key, flags: ch == "(" ? .maskShift : [], postEvent: { [unowned self] in receive($0) })
            // The real event leaves the callback after all proxy-posted edits.
            text.append(ch)
        }
    }

    private func receive(_ event: CGEvent) {
        guard event.type == .keyDown else { return }
        if event.getIntegerValueField(.keyboardEventKeycode) == Int64(KC.backspace) {
            if !text.isEmpty { text.removeLast() }
        } else {
            text += unicode(event)
        }
    }
}

private func unicode(_ event: CGEvent) -> String {
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 512)
    event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
    return String(utf16CodeUnits: buffer, count: length)
}
