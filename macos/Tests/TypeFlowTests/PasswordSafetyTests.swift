import Testing
import SwitcherCore
@testable import TypeFlow

@Suite("Password input safety")
struct PasswordSafetyTests {
    @Test func recognizesIndependentPasswordSignals() {
        #expect(PasswordFocus.isProtected(secureInput: true, subrole: nil, protectedContent: false))
        #expect(PasswordFocus.isProtected(secureInput: false, subrole: "AXSecureTextField", protectedContent: false))
        #expect(PasswordFocus.isProtected(secureInput: false, subrole: "AXTextField", protectedContent: true))
        #expect(!PasswordFocus.isProtected(secureInput: false, subrole: "AXTextField", protectedContent: false))
        #expect(!PasswordFocus.isProtected(secureInput: false, subrole: nil, protectedContent: false))
    }

    @Test func protectedInputDiscardsBufferedText() {
        let monitor = KeyboardMonitor()
        monitor.handleKeyDown(keyCode: 0, flags: [])
        monitor.suspendForProtectedInput()
        #expect(monitor.currentWordLength == 0)
        #expect(monitor.currentWordKeys.isEmpty)
        #expect(monitor.prevWordKeys.isEmpty)
        #expect(monitor.lineKeys.isEmpty)
    }

    @Test @MainActor func lockBorrowingsAreNotCorrectedToOrdinaryRussianWords() {
        for word in ["лочилась", "лочился", "лочиться", "лочусь", "лочишься", "лочится",
                     "лочимся", "лочитесь", "лочатся", "лочилось", "лочились",
                     "залочилась", "разлочился", "перелочить", "анлочить", "залоченный"] {
            #expect(ModernRussianLexicon.contains(word), "Missing: \(word)")
            #expect(Dict.bestCorrection(word, lang: "ru") == nil, "Incorrect correction: \(word)")
            #expect(LayoutDetector.decide(typed: word, converted: KeyMapping.convert(word),
                                         currentLang: "ru", otherLang: "en", capsLock: false) != .switchToConverted)
        }
    }
}
