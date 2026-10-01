import Foundation
import Testing
import SwitcherCore
@testable import TypeFlow

@Suite("Reported layout regressions")
struct LayoutRegressionTests {
    @Test func projectMenuDestinationsAreConcreteHTTPSLinks() {
        for link in [SettingsManager.starURL, SettingsManager.supportURL, SettingsManager.contactURL] {
            let url = URL(string: link)
            #expect(url?.scheme == "https")
            #expect(url?.host == "github.com")
            #expect(link.contains("Marko123333/TypeFlow"))
        }
    }

    @Test func mapsCyrillicImageOfSSHBackToEnglish() {
        #expect(KeyMapping.convert("ыыр") == "ssh")
    }

    @Test func mapsShiftedPunctuationKeyAsRussianCapital() {
        #expect(KeyMapping.convert("<kby") == "Блин")
    }

    @Test @MainActor func detectorAcceptsSSHAsTargetWord() {
        let decision = LayoutDetector.decide(
            typed: "ыыр",
            converted: "ssh",
            currentLang: "ru",
            otherLang: "en",
            capsLock: false
        )
        #expect(decision == .switchToConverted)
    }

    @Test @MainActor func convertsRussianCheeseFromEnglishLayout() {
        #expect(KeyMapping.convert("csh") == "сыр")
        #expect(LayoutDetector.decide(
            typed: "csh",
            converted: "сыр",
            currentLang: "en",
            otherLang: "ru",
            capsLock: false
        ) == .switchToConverted)
        #expect(LayoutDetector.decide(
            typed: "сыр",
            converted: "csh",
            currentLang: "ru",
            otherLang: "en",
            capsLock: false
        ) == .keep)
    }

    @Test @MainActor func detectorUsesBroadCorpusOnlyAsFallback() {
        let target = "colourisation"
        let typed = KeyMapping.convert(target)
        let decision = LayoutDetector.decide(
            typed: typed,
            converted: target,
            currentLang: "ru",
            otherLang: "en",
            capsLock: false
        )
        #expect(decision == .switchToConverted)
    }

    @Test @MainActor func detectorConvertsWholeCapitalizedRussianWord() {
        let decision = LayoutDetector.decide(
            typed: "<kby",
            converted: "Блин",
            currentLang: "en",
            otherLang: "ru",
            capsLock: false
        )
        #expect(decision == .switchToConverted)
    }

    @Test @MainActor func keepsEnglishInstInsteadOfTrustingNoisyFallback() {
        let target = KeyMapping.convert("inst")
        #expect(LayoutDetector.decide(
            typed: "inst",
            converted: target,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false
        ) == .keep)
    }

    @Test @MainActor func convertsISPAndISPManagerFromRussianLayout() {
        #expect(KeyMapping.convert("isp") == "шыз")
        #expect(KeyMapping.convert("ispmanager") == "шызьфтфпук")
        for target in ["isp", "ispmanager", "api", "cdn", "db", "dev", "inst", "sftp", "ui", "ux"] {
            let typed = KeyMapping.convert(target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "ru",
                otherLang: "en",
                capsLock: false
            ) == .switchToConverted)
        }
    }

    @Test @MainActor func convertsMCPInLowercaseAndUppercaseFromRussianLayout() {
        for target in ["mcp", "MCP"] {
            let typed = KeyMapping.convert(target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "ru",
                otherLang: "en",
                capsLock: target == "MCP"
            ) == .switchToConverted)
        }
        #expect(KeyMapping.convert("mcp") == "ьсз")
        #expect(KeyMapping.convert("MCP") == "ЬСЗ")
    }

    @Test @MainActor func convertsReportedRussianPhraseFromEnglishLayout() {
        for target in ["не", "работает", "ещё"] {
            let typed = KeyMapping.convert(target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted)
        }

        #expect(KeyMapping.convert("не") == "yt")
        #expect(KeyMapping.convert("работает") == "hf,jnftn")
        #expect(KeyMapping.convert("ещё") == "to`")
        #expect(LayoutDetector.prefersWholeToken(
            typed: "to`",
            converted: "ещё",
            currentLang: "en",
            otherLang: "ru",
            convertedHasSafeCorrection: false
        ))
    }

    @Test @MainActor func convertsPlainEImageOfYoWordFromEnglishLayout() {
        #expect(KeyMapping.convert("еще") == "tot")
        #expect(LayoutDetector.decide(
            typed: "tot",
            converted: "еще",
            currentLang: "en",
            otherLang: "ru",
            capsLock: false
        ) == .switchToConverted)
        #expect(BundledRussianLexicon.makeYoRestorer().restore("еще") == .restored("ещё"))
    }

    @Test @MainActor func openingParenthesisAndLeadingHyphenLeaveOnlyWordAtSpace() {
        let keycodes = Dictionary(uniqueKeysWithValues: KeyMapping.keycodeToEN.map { ($0.value, $0.key) })
        for prefix in ["(", "((", "-", "(-", " -", "(-("] {
            let monitor = KeyboardMonitor()
            for character in prefix {
                if character == "(" { monitor.handleKeyDown(keyCode: 25, flags: .maskShift) }
                else if character == "-" { monitor.handleKeyDown(keyCode: 27, flags: []) }
                else { monitor.handleKeyDown(keyCode: KC.space, flags: []) }
            }
            for character in "ghbdtn" {
                monitor.handleKeyDown(keyCode: keycodes[character]!, flags: [])
            }
            monitor.handleKeyDown(keyCode: KC.space, flags: [])
            #expect(monitor.prevWordKeys.count == 6, "Prefix leaked into word: \(prefix)")
            #expect(monitor.boundaryCount == 1)
            let typed = String(monitor.prevWordKeys.compactMap { KeyMapping.keycodeToEN[$0.keyCode] })
            #expect(typed == "ghbdtn")
            #expect(LayoutDetector.decide(
                typed: typed, converted: KeyMapping.convert(typed),
                currentLang: "en", otherLang: "ru", capsLock: false
            ) == .switchToConverted)
        }
    }

    @Test @MainActor func openingParenthesisAfterAnotherWordStartsFreshWord() {
        let monitor = KeyboardMonitor()
        for character in "foo" {
            let keycode = KeyMapping.keycodeToEN.first { $0.value == character }!.key
            monitor.handleKeyDown(keyCode: keycode, flags: [])
        }
        monitor.handleKeyDown(keyCode: 25, flags: .maskShift)
        #expect(monitor.currentWordKeys.isEmpty)
        for character in "ghbdtn" {
            let keycode = KeyMapping.keycodeToEN.first { $0.value == character }!.key
            monitor.handleKeyDown(keyCode: keycode, flags: [])
        }
        monitor.handleKeyDown(keyCode: KC.space, flags: [])
        #expect(monitor.prevWordKeys.count == 6)
    }

    @Test @MainActor func internalHyphenStillBelongsToCompound() {
        let monitor = KeyboardMonitor()
        for character in "xnj" {
            let keycode = KeyMapping.keycodeToEN.first { $0.value == character }!.key
            monitor.handleKeyDown(keyCode: keycode, flags: [])
        }
        monitor.handleKeyDown(keyCode: 27, flags: [])
        for character in "nj" {
            let keycode = KeyMapping.keycodeToEN.first { $0.value == character }!.key
            monitor.handleKeyDown(keyCode: keycode, flags: [])
        }
        monitor.handleKeyDown(keyCode: KC.space, flags: [])
        let typed = String(monitor.prevWordKeys.compactMap { KeyMapping.keycodeToEN[$0.keyCode] })
        #expect(typed == "xnj-nj")
        #expect(LayoutDetector.decide(typed: typed, converted: "что-то", currentLang: "en",
                                      otherLang: "ru", capsLock: false) == .switchToConverted)
    }

    @Test @MainActor func punctuationKeyThatMapsToRussianLetterRemainsPartOfWord() {
        let monitor = KeyboardMonitor()
        monitor.handleKeyDown(keyCode: 27, flags: []) // leading hyphen stays outside
        monitor.handleKeyDown(keyCode: 41, flags: []) // ; is Russian ж
        for character in "jgf" {
            let keycode = KeyMapping.keycodeToEN.first { $0.value == character }!.key
            monitor.handleKeyDown(keyCode: keycode, flags: [])
        }
        monitor.handleKeyDown(keyCode: KC.space, flags: [])
        #expect(monitor.prevWordKeys.count == 4)
        let typed = String(monitor.prevWordKeys.compactMap { KeyMapping.keycodeToEN[$0.keyCode] })
        #expect(typed == ";jgf")
        #expect(KeyMapping.convert(typed) == "жопа")
    }

    @Test @MainActor func convertsRussianHyphenatedWordsFromEnglishLayout() {
        for target in [
            "что-то", "Что-то", "ЧТО-ТО", "где-то", "из-за", "кто-нибудь",
            "когда-нибудь", "какой-либо", "по-моему", "во-первых",
            "онлайн-магазин", "давным-давно",
        ] {
            let typed = KeyMapping.convert(target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted, "Failed hyphenated target: \(target)")
        }

        #expect(KeyMapping.convert("что-то") == "xnj-nj")
        #expect(KeyMapping.convert("где-то") == "ult-nj")
        #expect(LayoutDetector.decide(
            typed: "что-то",
            converted: "xnj-nj",
            currentLang: "ru",
            otherLang: "en",
            capsLock: false
        ) == .keep)
        let punctuated = LayoutDetector.splitTrailingPunctuation("xnj-nj,")
        #expect(punctuated.coreLength == 6)
        #expect(punctuated.suffix == ",")

        let endingOnPunctuationKey = KeyMapping.convert("во-первых")
        #expect(endingOnPunctuationKey == "dj-gthds[")
        #expect(LayoutDetector.prefersWholeToken(
            typed: endingOnPunctuationKey,
            converted: "во-первых",
            currentLang: "en",
            otherLang: "ru",
            convertedHasSafeCorrection: false
        ))

        #expect(!LayoutDetector.prefersWholeToken(
            typed: "xnj-nj,",
            converted: KeyMapping.convert("xnj-nj,"),
            currentLang: "en",
            otherLang: "ru",
            convertedHasSafeCorrection: false
        ))
    }

    @Test @MainActor func keepsRealEnglishHyphenatedWords() {
        for word in ["well-known", "state-of-the-art"] {
            #expect(LayoutDetector.decide(
                typed: word,
                converted: KeyMapping.convert(word),
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .keep)

            let typedInRussianLayout = KeyMapping.convert(word)
            #expect(LayoutDetector.decide(
                typed: typedInRussianLayout,
                converted: word,
                currentLang: "ru",
                otherLang: "en",
                capsLock: false
            ) == .switchToConverted)
        }
    }

    @Test @MainActor func convertsRussianEtCeteraAbbreviationFromEnglishLayout() {
        #expect(KeyMapping.convert("тд") == "nl")
        #expect(LayoutDetector.decide(
            typed: "nl",
            converted: "тд",
            currentLang: "en",
            otherLang: "ru",
            capsLock: false
        ) == .switchToConverted)
    }

    @Test @MainActor func convertsRussianConjunctionFromEnglishLayout() {
        for (typed, converted) in [("b", "и"), ("d", "в"), ("c", "с"), ("r", "к"),
                                   ("j", "о"), ("e", "у"), ("f", "а"), ("z", "я")] {
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: converted,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted)
        }
        #expect(LayoutDetector.decide(
            typed: "i",
            converted: "ш",
            currentLang: "en",
            otherLang: "ru",
            capsLock: false
        ) == .keep)
        for target in ["А", "В", "И", "К", "О", "С", "У", "Я"] {
            #expect(LayoutDetector.decide(
                typed: KeyMapping.convert(target),
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted, "Failed uppercase one-letter word: \(target)")
        }
        #expect(KeyMapping.convert("И") == "B")
    }

    @Test @MainActor func convertsRussianParticlesFromEnglishLayoutInEveryCase() {
        let targets = [
            "уж", "же", "бы", "ли", "ль", "ведь", "разве", "неужели",
            "вот", "вон", "именно", "только", "лишь", "пусть", "пускай",
            "дескать", "якобы", "мол", "вряд", "едва", "уже", "всё-таки",
            "опять-таки", "как-никак", "всего-навсего",
        ]

        for target in targets {
            let capitalized = target.prefix(1).uppercased() + target.dropFirst()
            let variants = ["ли", "ль"].contains(target)
                ? [target, capitalized]
                : [target, capitalized, target.uppercased()]
            for variant in variants {
                let typed = KeyMapping.convert(variant)
                #expect(LayoutDetector.decide(
                    typed: typed,
                    converted: variant,
                    currentLang: "en",
                    otherLang: "ru",
                    capsLock: variant == variant.uppercased()
                ) == .switchToConverted, "Failed particle: \(variant) from \(typed)")
            }
        }

        #expect(KeyMapping.convert("уж") == "e;")
        #expect(KeyMapping.convert("Уж") == "E;")
        #expect(KeyMapping.convert("УЖ") == "E:")
        for pair in [("e;", "уж"), ("E;", "Уж"), ("E:", "УЖ")] {
            #expect(LayoutDetector.prefersWholeToken(
                typed: pair.0,
                converted: pair.1,
                currentLang: "en",
                otherLang: "ru",
                convertedHasSafeCorrection: false
            ), "Trailing punctuation key was not retained for \(pair.1)")
        }

        for (typed, converted) in [("KB", "ЛИ"), ("KM", "ЛЬ")] {
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: converted,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .keep, "Technical abbreviation was treated as a particle: \(typed)")
        }
        for (typed, converted) in [("Kb", "Ли"), ("Km", "Ль")] {
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: converted,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted, "Capitalized particle was not converted: \(converted)")
        }
    }

    @Test @MainActor func convertsDottedTechnicalNameFromRussianLayout() {
        for target in ["node.js", "Node.js", "node.js,", "socket.io"] {
            let typed = KeyMapping.convert(target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "ru",
                otherLang: "en",
                capsLock: false
            ) == .switchToConverted)
        }

        let domain = "example.com"
        #expect(LayoutDetector.decide(
            typed: KeyMapping.convert(domain),
            converted: domain,
            currentLang: "ru",
            otherLang: "en",
            capsLock: false
        ) == .keep)
    }

    @Test @MainActor func convertsPreferredRussianShortRepliesFromEnglishLayout() {
        for (typed, target) in [
            ("ye", "ну"), ("jr", "ок"), ("uj", "го"),
            ("lf", "да"), ("yt", "не"),
        ] {
            #expect(KeyMapping.convert(typed) == target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted)
        }
    }

    @Test @MainActor func convertsRussianAbbreviationsAndProfanityFromEnglishLayout() {
        for target in ["руб", "рус", "хуй", "блядь", "пиздец"] {
            let typed = KeyMapping.convert(target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted)
        }
        #expect(KeyMapping.convert("руб") == "he,")
        #expect(KeyMapping.convert("хуй") == "[eq")
    }

    @Test @MainActor func convertsAaPanelFromRussianLayout() {
        let typed = KeyMapping.convert("aapanel")
        #expect(typed == "ффзфтуд")
        #expect(LayoutDetector.decide(
            typed: typed,
            converted: "aapanel",
            currentLang: "ru",
            otherLang: "en",
            capsLock: false
        ) == .switchToConverted)
    }

    @Test @MainActor func treatsPunctuationKeyAsTargetLetterOnlyWithStrongEvidence() {
        #expect(LayoutDetector.prefersWholeToken(
            typed: "he,",
            converted: "руб",
            currentLang: "en",
            otherLang: "ru",
            convertedHasSafeCorrection: false
        ))
        #expect(LayoutDetector.prefersWholeToken(
            typed: "gbne[",
            converted: "питух",
            currentLang: "en",
            otherLang: "ru",
            convertedHasSafeCorrection: true
        ))
        #expect(!LayoutDetector.prefersWholeToken(
            typed: "levf.",
            converted: "думаю",
            currentLang: "en",
            otherLang: "ru",
            convertedHasSafeCorrection: false
        ))
        #expect(Dict.bestCorrection("питух", lang: "ru") == "петух")
    }

    @Test @MainActor func doesNotRewriteKnownRussianWordAsAnotherWord() {
        #expect(BundledLexicon.contains("скачивание", language: "ru"))
        #expect(Dict.bestCorrection("скачивание", lang: "ru") == nil)
    }

    @Test func rejectedCorrectionIsSuppressedOnlyOncePerSpelling() {
        var suppression = SessionCorrectionSuppression()
        suppression.remember(original: "gbne[", alternatives: ["питух"])
        let consumesOriginalOnce = suppression.consume("GBNE[")
        let consumesOriginalTwice = suppression.consume("gbne[")
        let consumesAlternativeOnce = suppression.consume("ПИТУХ")
        let consumesAlternativeTwice = suppression.consume("питух")
        let consumesUnrelated = suppression.consume("петух")
        #expect(consumesOriginalOnce)
        #expect(!consumesOriginalTwice)
        #expect(consumesAlternativeOnce)
        #expect(!consumesAlternativeTwice)
        #expect(!consumesUnrelated)
    }

    @Test @MainActor func deletingIntoCorrectionRejectsOnlyTheLastConversion() async {
        let monitor = KeyboardMonitor()
        var rejectionCount = 0
        monitor.onRejectLastConversion = { rejectionCount += 1 }
        monitor.markConverted()

        monitor.handleKeyDown(keyCode: KC.backspace, flags: [])
        await Task.yield()
        #expect(rejectionCount == 0) // first Backspace removes the triggering space

        monitor.handleKeyDown(keyCode: KC.backspace, flags: [])
        await Task.yield()
        #expect(rejectionCount == 1)

        monitor.handleKeyDown(keyCode: KC.backspace, flags: [])
        await Task.yield()
        #expect(rejectionCount == 1)
    }

    @Test @MainActor func convertsEnglishArticlesFromRussianLayout() {
        for (typed, converted) in [("ф", "a"), ("ш", "i")] {
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: converted,
                currentLang: "ru",
                otherLang: "en",
                capsLock: false
            ) == .switchToConverted)
        }
    }

    @Test @MainActor func convertsModernRussianBorrowingsAndProductiveVerbForms() {
        for target in [
            "ресерч", "Ресерч", "РЕСЕРЧ", "поресерч", "поресерчи",
            "поресерчить", "заресерчил", "проресерчите", "погуглил",
            "пофиксить", "запушили", "промпты", "датасетом", "нейронка",
            "файн-тюнинг", "вайб-кодинг",
        ] {
            let typed = KeyMapping.convert(target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted, "Failed modern term: \(target) from \(typed)")
        }

        #expect(KeyMapping.convert("ресерч") == "htcthx")
        #expect(KeyMapping.convert("поресерч") == "gjhtcthx")
        #expect(KeyMapping.convert("поресерчи") == "gjhtcthxb")
    }

    @Test @MainActor func recognizesRussianAndEnglishAITerms() {
        for target in ["ии", "ИИ", "аи", "АИ", "ллм", "ЛЛМ", "раг", "РАГ"] {
            #expect(LayoutDetector.decide(
                typed: KeyMapping.convert(target),
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted, "Failed Russian AI term: \(target)")
        }

        for target in ["ai", "AI", "llm", "LLM", "rag", "RAG", "gpt", "GPT"] {
            #expect(LayoutDetector.decide(
                typed: KeyMapping.convert(target),
                converted: target,
                currentLang: "ru",
                otherLang: "en",
                capsLock: false
            ) == .switchToConverted, "Failed English AI term: \(target)")
        }

        #expect(KeyMapping.convert("ИИ") == "BB")
        #expect(KeyMapping.convert("АИ") == "FB")
        #expect(KeyMapping.convert("AI") == "ФШ")
    }

    @Test @MainActor func checksAllCapsWordsAgainstDictionaries() {
        for target in ["ПРИВЕТ", "РАБОТАЕТ", "ИССЛЕДОВАНИЕ"] {
            #expect(LayoutDetector.decide(
                typed: KeyMapping.convert(target),
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted, "Failed uppercase dictionary word: \(target)")
        }

        for currentWord in ["TEST", "SERVER", "RESEARCH", "NASA", "HTTP", "SSH", "MCP", "KB", "KM"] {
            #expect(LayoutDetector.decide(
                typed: currentWord,
                converted: KeyMapping.convert(currentWord),
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) != .switchToConverted, "Rewrote English acronym/word: \(currentWord)")
        }
    }

    @Test @MainActor func convertsRussianAbbreviationsFromEnglishLayout() {
        for target in [
            "фсб", "ФСБ", "фбр", "ФБР", "пдн", "ПДН", "жкх", "ЖКХ",
            "мвд", "мчс", "гибдд", "тсж", "ооо", "инн", "снилс",
            "днк", "мрт", "егэ", "оон", "сша", "вднх", "ВДНХ",
            "гоэлро", "ГОЭЛРО", "пэвм", "ПЭВМ", "цска", "ЦСКА",
        ] {
            let typed = KeyMapping.convert(target)
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted, "Failed abbreviation: \(typed) -> \(target)")
        }
    }

    @Test @MainActor func keepsCorrectRussianAbbreviationsAndTheirPunctuationImages() {
        #expect(KeyMapping.convert("фсб") == "ac,")
        #expect(KeyMapping.convert("жкх") == ";r[")

        for target in ["фсб", "ФСБ", "фбр", "пдн", "жкх", "ЖКХ"] {
            #expect(LayoutDetector.decide(
                typed: target,
                converted: KeyMapping.convert(target),
                currentLang: "ru",
                otherLang: "en",
                capsLock: false
            ) == .keep, "Rewrote correct Russian abbreviation: \(target)")
        }

        let punctuated = LayoutDetector.splitTrailingPunctuation("фсб,")
        #expect(punctuated.coreLength == 3)
        #expect(punctuated.suffix == ",")
        #expect(LayoutDetector.decide(
            typed: "фсб",
            converted: "ac,",
            currentLang: "ru",
            otherLang: "en",
            capsLock: false
        ) == .keep)
    }

    @Test @MainActor func keepsWholeWrongLayoutAbbreviationOnPunctuationKeys() {
        for (typed, target) in [("ac,", "фсб"), (";r[", "жкх")] {
            #expect(LayoutDetector.prefersWholeToken(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                convertedHasSafeCorrection: false
            ), "Split punctuation that belongs to abbreviation: \(typed) -> \(target)")
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            ) == .switchToConverted)
        }
    }

    @Test @MainActor func neverSelectsGenericPunctuationBearingTarget() {
        for typed in ["фыб", "жкъ", "хол"] {
            let converted = KeyMapping.convert(typed)
            #expect(!converted.allSatisfy({ $0.isLetter }))
            #expect(LayoutDetector.decide(
                typed: typed,
                converted: converted,
                currentLang: "ru",
                otherLang: "en",
                capsLock: false
            ) != .switchToConverted, "Selected punctuation target: \(typed) -> \(converted)")
        }
    }

    @Test @MainActor func russianAbbreviationKeyImageCollisionsStayEnglish() {
        var collisions: [String] = []
        for target in RussianAbbreviations.all {
            let typed = KeyMapping.convert(target).lowercased()
            let currentEvidence = typed.allSatisfy(\.isLetter)
                ? Dict.confidence(typed, lang: "en")
                : .absent
            let explicitlyKnownEnglish = HighConfidenceLexicon.contains(typed, language: "en")
                || ShortWords.common("en")?.contains(typed) == true
            let decision = LayoutDetector.decide(
                typed: typed,
                converted: target,
                currentLang: "en",
                otherLang: "ru",
                capsLock: false
            )
            if explicitlyKnownEnglish
                || (currentEvidence != .absent && !RussianAbbreviations.isReviewed(target)) {
                collisions.append("\(typed) -> \(target)")
                #expect(decision == .keep, "Rewrote known English token: \(typed) -> \(target)")
            } else {
                #expect(decision == .switchToConverted, "Missed safe abbreviation: \(typed) -> \(target)")
            }
        }
        #expect(!collisions.isEmpty, "Collision guard was not exercised")
    }

    @Test func modernRussianLexiconHasNoUnreviewedEnglishKeyImageCollisions() {
        let intentional: Set<String> = ["bb", "fb"] // user-requested ИИ and АИ
        let collisions = ModernRussianLexicon.allWords.compactMap { target -> String? in
            let typed = KeyMapping.convert(target).lowercased()
            guard typed.allSatisfy(\.isLetter),
                  !intentional.contains(typed),
                  HighConfidenceLexicon.contains(typed, language: "en")
                    || BundledLexicon.contains(typed, language: "en") else { return nil }
            return "\(typed) -> \(target)"
        }.sorted()
        #expect(collisions.isEmpty, "Unreviewed English collisions: \(collisions.prefix(20))")
    }
}
