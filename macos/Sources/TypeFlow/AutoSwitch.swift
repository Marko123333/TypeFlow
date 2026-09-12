import AppKit
import Carbon
import IOKit
import SwitcherCore

/// Проверка слов по системному словарю (NSSpellChecker) — локально, без зависимостей,
/// без сети и без бандла данных. ~0.1мс на проверку, 40+ языков.
enum Dict {
    /// Evidence strength used by automatic layout detection. A broad corpus
    /// must never outweigh AppleSpell or explicit technical terminology.
    enum Confidence: Int, Comparable {
        case absent = 0
        case bundled = 1
        case system = 2
        case curated = 3

        static func < (lhs: Confidence, rhs: Confidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    @MainActor private static let checker = NSSpellChecker.shared
    /// Кэш списка словарей: availableLanguages ходит в AppleSpell — не дёргаем на каждое слово.
    @MainActor private static var cachedLanguages: [String]?

    @MainActor static func isAvailable(_ lang: String) -> Bool {
        let two = String(lang.prefix(2))
        return languages().contains { String($0.prefix(2)) == two }
    }

    @MainActor private static func languages() -> [String] {
        if let cached = cachedLanguages { return cached }
        let langs = checker.availableLanguages
        cachedLanguages = langs
        return langs
    }

    /// Прогрев: первое обращение к NSSpellChecker поднимает XPC-процесс AppleSpell
    /// (сотни мс на main) — без прогрева этот фриз пришёлся бы на первый пробел
    /// пользователя после запуска. Вызывается отложенно из applicationDidFinishLaunching.
    @MainActor static func warmUp() {
        _ = languages()
        _ = isValidWord("тест", lang: "ru")
        _ = isValidWord("test", lang: "en")
    }

    /// true — слово есть в словаре языка (орфография корректна).
    @MainActor static func isValidWord(_ word: String, lang: String) -> Bool {
        if HighConfidenceLexicon.contains(word, language: lang) { return true }
        guard isAvailable(lang) else { return false }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    @MainActor static func confidence(_ word: String, lang: String) -> Confidence {
        if HighConfidenceLexicon.contains(word, language: lang) { return .curated }
        if isValidWord(word, lang: lang) { return .system }
        if BundledLexicon.contains(word, language: lang) { return .bundled }
        return .absent
    }

    /// Returns only a one-edit, same-script correction accepted by the local
    /// safety filter. No text or diagnostics leave the Mac.
    @MainActor static func bestCorrection(_ word: String, lang: String) -> String? {
        // Explicitly reviewed typos remain eligible even when the broad corpus
        // happens to contain their misspelling (`питух` is one such noisy entry).
        if let explicit = SpellingCandidateSelector.best(original: word, guesses: []) {
            return explicit
        }

        let normalized = word.lowercased()
        guard !isValidWord(normalized, lang: lang),
              !BundledLexicon.contains(normalized, language: lang) else { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = checker.guesses(
            forWordRange: range,
            in: word,
            language: lang,
            inSpellDocumentWithTag: 0
        ) ?? []
        return SpellingCandidateSelector.best(original: word, guesses: guesses)
    }
}

enum LayoutVerdict { case switchToConverted, keep, undecided }

/// Решает, набрано ли слово в неправильной раскладке. Точность важнее полноты:
/// при любой неуверенности → .undecided (ничего не делаем). Ручной триггер остаётся.
enum LayoutDetector {
    /// Some physical keys are punctuation in the active layout but letters in
    /// the opposite one (`he,` -> `руб`, `gbne[` -> `питух`). Keep the full
    /// key sequence when the opposite side has an explicit curated match or a
    /// safe one-edit spelling correction. Ordinary ambiguous punctuation such
    /// as `levf.` remains on the conservative split-and-check path.
    @MainActor
    static func prefersWholeToken(
        typed: String,
        converted: String,
        currentLang: String,
        otherLang: String,
        convertedHasSafeCorrection: Bool
    ) -> Bool {
        // In a hyphenated token, ordinary sentence punctuation is much more likely
        // to be literal (`xnj-nj,` -> `что-то,`) than an extra target-layout letter.
        // Bracket/backtick keys remain eligible below because they represent the
        // common Russian letters х/ъ/ё and rarely terminate an unpaired token.
        let trailing = splitTrailingPunctuation(typed).suffix
        let commonSentencePunctuation: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]
        if typed.contains("-"),
           let firstTrailing = trailing.first,
           commonSentencePunctuation.contains(firstTrailing) {
            return false
        }

        if hyphenatedVerdict(
            typed: typed,
            converted: converted,
            currentLang: currentLang,
            otherLang: otherLang,
            allowBundledComponents: false
        ) == .switchToConverted {
            return true
        }

        guard !typed.allSatisfy({ $0.isLetter }),
              converted.count >= 2,
              converted.allSatisfy({ $0.isLetter }) else { return false }

        let convertedCurated = HighConfidenceLexicon.contains(converted, language: otherLang)
        let typedCurated = HighConfidenceLexicon.contains(typed, language: currentLang)
        if convertedCurated != typedCurated { return convertedCurated }
        return converted.count >= 4 && convertedHasSafeCorrection
    }

    @MainActor
    static func decide(typed: String, converted: String, currentLang: String, otherLang: String, capsLock: Bool) -> LayoutVerdict {
        // always-convert — ЯВНЫЙ override: матчим по СКОНВЕРТИРОВАННОЙ (целевой) форме.
        // В список кладётся целевое слово (напр. «жоппа»); так правильно набранное слово
        // не даёт пинг-понг. Жёсткие гейты (secure/denied-app/never) проверены ДО decide.
        if AutoSwitchPolicy.isAlwaysConvert(converted) { return .switchToConverted }

        let cur = String(currentLang.prefix(2))
        let oth = String(otherLang.prefix(2))

        // `ли` and `ль` share their physical keys with the common technical
        // abbreviations KB and KM. Sentence-capitalized `Kb`/`Km` are still
        // eligible for Russian particles, but preserve the conventional all-caps
        // spellings used for storage sizes and distances.
        if cur == "en",
           isAllCaps(typed),
           ["kb", "km"].contains(typed.lowercased()) {
            return .keep
        }

        // Russian abbreviations are exact signals, but some of their all-letter
        // QWERTY images are also genuine English tokens (`мгу` <-> `vue`, for
        // example). Preserve that current-language token when it has any local
        // dictionary evidence; punctuation-bearing and unknown images remain safe
        // to convert (`ac,` -> `фсб`, `;r[` -> `жкх`). Correctly typed Russian
        // abbreviations always stay unchanged.
        let typedRussianAbbreviation = cur == "ru" && RussianAbbreviations.contains(typed)
        let convertedRussianAbbreviation = oth == "ru" && RussianAbbreviations.contains(converted)
        if typedRussianAbbreviation != convertedRussianAbbreviation {
            if typedRussianAbbreviation { return .keep }
            if typed.allSatisfy({ $0.isLetter }) {
                let normalizedTyped = typed.lowercased()
                let explicitlyKnownCurrent = HighConfidenceLexicon.contains(
                    normalizedTyped,
                    language: cur
                ) || ShortWords.common(cur)?.contains(normalizedTyped) == true
                if explicitlyKnownCurrent { return .keep }

                // The extended Wiktionary corpus is deliberately weaker than a
                // real current-language word. The manually reviewed frequent set
                // remains an exact signal even when a broad dictionary happens to
                // contain an obscure collision (`vdl` -> `мвд`).
                if !RussianAbbreviations.isReviewed(converted),
                   Dict.confidence(normalizedTyped, lang: cur) != .absent {
                    return .keep
                }
            }
            return .switchToConverted
        }

        // Exact curated words are stronger than the generic acronym/camelCase vetoes.
        // This lets a known technical acronym keep its spelling in the correct layout
        // and convert in the wrong one (`ЬСЗ` -> `MCP`, `ЫЫР` -> `SSH`). It also lets
        // punctuation-backed exact Russian words such as `to\`` -> `ещё` through.
        let typedCurated = HighConfidenceLexicon.contains(typed, language: cur)
        let convertedCurated = HighConfidenceLexicon.contains(converted, language: oth)
        if typedCurated != convertedCurated {
            return convertedCurated ? .switchToConverted : .keep
        }

        // A hyphen is part of many ordinary words, not automatically a code marker.
        // Accept a layout flip only when every component on exactly one side is a
        // known word. This converts `xnj-nj` -> `что-то` and `ult-nj` -> `где-то`,
        // while preserving real English compounds such as `well-known`.
        if let hyphenated = hyphenatedVerdict(
            typed: typed,
            converted: converted,
            currentLang: cur,
            otherLang: oth,
            allowBundledComponents: true
        ) {
            return hyphenated
        }

        // Product/runtime names with an internal dot are not accepted by normal
        // spellcheckers. A small exact lexicon handles `тщвуюоы` -> `node.js`
        // (and the reverse keep decision) without opening a broad URL/domain rule.
        let typedTechnical = HighConfidenceLexicon.containsTechnicalToken(typed, language: cur)
        let convertedTechnical = HighConfidenceLexicon.containsTechnicalToken(converted, language: oth)
        if typedTechnical != convertedTechnical {
            return convertedTechnical ? .switchToConverted : .keep
        }
        // AppleSpell may accept a domain as a valid token. Unknown dotted forms
        // are therefore an explicit keep; only the exact technical allowlist
        // above may opt into automatic conversion.
        if typed.contains(".") || converted.contains(".") { return .keep }

        // --- мягкие вето (дёшево, до словаря) ---
        // Одиночные буквы исправляем только по закрытым спискам реальных слов: например,
        // `b` -> `и`, `d` -> `в`, `ф` -> `a`. Это важный переход после английского
        // технического термина (`ssh b nginx`), где словарного контекста самого токена нет.
        // Проверяем без учёта регистра, поэтому `B` -> `И` работает в начале предложения.
        if typed.count == 1 {
            guard typed.allSatisfy({ $0.isLetter }), converted.allSatisfy({ $0.isLetter }) else {
                return .undecided
            }
            let normalizedTyped = typed.lowercased()
            let normalizedConverted = converted.lowercased()
            if let current = oneLetterWords(cur), current.contains(normalizedTyped) { return .keep }
            return oneLetterWords(oth)?.contains(normalizedConverted) == true
                ? .switchToConverted : .undecided
        }
        // Обычный путь — набранное целиком буквенное. Плюс (issue #22, п.3) случай «буквы
        // на клавишах-пунктуации»: ё/х/ъ/ж/э/б/ю в ЙЦУКЕН живут на ` [ ] ; ' , . — тогда
        // typed содержит эти знаки, но КОНВЕРСИЯ целиком буквенная, и решает словарь ниже.
        // Хвостовые . , ; : уже отщеплены вызывающим (#15) + walk неоднозначности, поэтому
        // сюда доходит только начальная/срединная пунктуация («`krf»→ёлка, «rf;tncz»→
        // кажется) — там трактовки-как-знак-препинания нет, а «дел.»/«думаю» отсеяны выше.
        guard typed.allSatisfy({ $0.isLetter }) || converted.allSatisfy({ $0.isLetter }) else {
            return .undecided // цифры/URL/код/почта/эмодзи
        }
        // Dictionary lookups below are case-insensitive, so an all-caps target
        // (`GHBDTN` -> `ПРИВЕТ`) must reach them even when the user held Shift
        // rather than Caps Lock. Real acronyms remain safe when their current-side
        // spelling is known or the opposite-side image is unknown. Mixed-case code
        // identifiers keep the conservative veto.
        if !capsLock, !isAllCaps(typed), looksLikeCodeIdentifier(typed) {
            return .undecided
        }

        // --- Кросс-скрипт пары с ивритом (3.0) ---
        // Системный ивритский словарь macOS для детекта БЕСПОЛЕЗЕН: он принимает любой
        // набор букв как «валидное слово» (проверено эмпирически), двусторонняя проверка
        // на стороне иврита невозможна. Поэтому конвертим ТОЛЬКО при положительном
        // сигнале второй (не-ивритской) стороны — её собственным словарём:
        //   • набрано в иврит-раскладке, а конверсия — валидное слово второй раскладки
        //     → задумана она, конвертим;
        //   • набрано во второй раскладке и это её валидное слово → keep (не трогаем);
        //   • всё остальное (имена, бренды, опечатки, «задуман иврит») → .undecided:
        //     направление «в иврит» без словаря честно не решаемо — точность важнее
        //     полноты. Ручной триггер конвертирует любые пары всегда.
        // Второй словарь берём по ЯЗЫКУ ПАРЫ (ru/de/fr/…), не хардкодим en — иначе
        // пара русский+иврит конвертила бы каждое валидное русское слово в иврит
        // (ревью-находка июльского аудита).
        if isHebrew(cur) || isHebrew(oth) {
            guard typed.count >= 3 else { return .undecided }              // короткий частотный сигнал для иврита не строим
            let hebrewIsCurrent = isHebrew(cur)
            let sideLang = hebrewIsCurrent ? oth : cur
            guard !isHebrew(sideLang), Dict.isAvailable(sideLang) else { return .undecided }
            if hebrewIsCurrent {
                // NSSpellChecker токенизирует («привет!» для него валиден), а часть ивритских
                // букв живёт на пунктуационных клавишах — EN-образ КОРРЕКТНОГО иврита может
                // получиться «слово + пунктуация» и ложно пройти словарь (ревью-находка,
                // тот же класс, что «думаю vs дума.» в 2.7.0). Словарю отдаём только
                // целиком буквенный образ; иначе .undecided — ручной триггер работает.
                guard converted.allSatisfy({ $0.isLetter }) else { return .undecided }
                return Dict.isValidWord(converted.lowercased(), lang: sideLang)
                    ? .switchToConverted : .undecided
            }
            return Dict.isValidWord(typed.lowercased(), lang: sideLang) ? .keep : .undecided
        }

        // --- Короткие (2-буквенные) слова: позитивный частотный сигнал (3.1, issue #22) ---
        // NSSpellChecker на длине 2 принимает почти любой набор букв за «слово», поэтому
        // обычная двусторонняя проверка тут ненадёжна (ради этого и стоял гейт count>=3).
        // Вместо словаря — компактный список ЧАСТЫХ коротких слов (ShortWords), строго как
        // позитивный сигнал: конвертим 2 буквы ТОЛЬКО если конверсия — частое слово целевого
        // языка, а набранное — не частое слово текущего (симметрия как у иврит-ветки).
        // Коллизий «частое↔частое» нет (аудит образов раскладки). Пары с языком без списка
        // сюда не попадают → 2-буквенные, как и раньше, не трогаются.
        if typed.count == 2 {
            guard let othShort = ShortWords.common(oth) else { return .undecided }
            if let curShort = ShortWords.common(cur), curShort.contains(typed.lowercased()) {
                return .keep   // уже частое слово в текущей раскладке — не трогаем
            }
            return othShort.contains(converted.lowercased()) ? .switchToConverted : .undecided
        }

        // Never ask a spelling dictionary to choose a punctuation-bearing target.
        // NSSpellChecker tokenizes strings such as `ac,` and `;r[` and may accept
        // their alphabetic fragment. That used to rewrite correctly typed Russian
        // abbreviations (`фсб` -> `ac,`, `жкх` -> `;r[`) and could duplicate a
        // literal trailing comma (`фсб,` -> `ac,,`). Exact curated words, ordinary
        // punctuation-key-to-letter conversions and approved dotted/hyphenated
        // tokens have already been handled above, so the generic dictionary path
        // is safe only when the entire destination is alphabetic.
        guard converted.allSatisfy({ $0.isLetter }) else { return .undecided }

        // Словарь — без учёта регистра (Caps Lock не должен мешать определению слова).
        let convertedConfidence = Dict.confidence(converted.lowercased(), lang: oth)
        guard convertedConfidence != .absent else { return .keep }
        let typedConfidence = Dict.confidence(typed.lowercased(), lang: cur)
        // Очень широкий fallback-корпус содержит имена и исторические формы. На 3-4
        // символах его положительного сигнала недостаточно: именно так `inst` ошибочно
        // превращался в русский образ. Короткие слова должны подтвердить AppleSpell,
        // curated-словарь или специальные списки выше.
        if convertedConfidence == .bundled, typed.count < 5 { return .keep }
        return convertedConfidence > typedConfidence ? .switchToConverted : .keep
    }

    private static func oneLetterWords(_ language: String) -> Set<String>? {
        switch language.lowercased().prefix(2) {
        case "ru": ["а", "в", "и", "к", "о", "с", "у", "я"]
        case "en": ["a", "i"]
        default: nil
        }
    }

    @MainActor
    private static func hyphenatedVerdict(
        typed: String,
        converted: String,
        currentLang: String,
        otherLang: String,
        allowBundledComponents: Bool
    ) -> LayoutVerdict? {
        guard typed.contains("-") || converted.contains("-") else { return nil }

        let typedParts = typed.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let convertedParts = converted.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard typedParts.count == convertedParts.count,
              typedParts.count >= 2,
              typedParts.allSatisfy({ !$0.isEmpty }),
              convertedParts.allSatisfy({ !$0.isEmpty }) else {
            return .undecided
        }

        let typedAlphabetic = typedParts.allSatisfy { $0.allSatisfy(\.isLetter) }
        let convertedAlphabetic = convertedParts.allSatisfy { $0.allSatisfy(\.isLetter) }
        guard typedAlphabetic || convertedAlphabetic else { return .undecided }

        let typedKnown = typedAlphabetic && typedParts.allSatisfy {
            isKnownCompoundComponent(
                $0,
                language: currentLang,
                allowBundled: allowBundledComponents
            )
        }
        let convertedKnown = convertedAlphabetic && convertedParts.allSatisfy {
            isKnownCompoundComponent(
                $0,
                language: otherLang,
                allowBundled: allowBundledComponents
            )
        }
        if typedKnown != convertedKnown {
            return convertedKnown ? .switchToConverted : .keep
        }
        return typedKnown ? .keep : .undecided
    }

    @MainActor
    private static func isKnownCompoundComponent(
        _ component: String,
        language: String,
        allowBundled: Bool
    ) -> Bool {
        let normalized = component.lowercased()
        if HighConfidenceLexicon.contains(normalized, language: language) { return true }
        if normalized.count == 1 {
            return oneLetterWords(language)?.contains(normalized) == true
        }
        if normalized.count == 2 {
            return ShortWords.common(language)?.contains(normalized) == true
        }

        let confidence = Dict.confidence(normalized, lang: language)
        return confidence != .absent && (allowBundled || confidence != .bundled)
    }

    /// issue #15: отщепляет прилипшую к концу слова пунктуацию ("ghbdtn," → ядро 6 + ",").
    /// Ядро детектится и конвертится как обычно, хвост возвращается в поле ЛИТЕРАЛОМ —
    /// конвертировать его по кейкодам нельзя: клавиша ',' в EN — это 'б' в RU, а
    /// запятая RU (Shift+6) в EN — '^'. Набор консервативный: цифры, дефис, @/#
    /// НЕ отщепляем — для URL/кода/почты вето детектора отрабатывает по делу.
    /// Кавычки ' и " исключены сознательно: смарт-пунктуация приложений подменяет их
    /// типографскими, а на dead-key раскладках (U.S. International) апостроф — dead key;
    /// оба случая ломают счёт/литеральность. «…»/«»/– недостижимы из буфера (Option-слой).
    /// ВАЖНО: '.', ',', ';', ':' в EN — клавиши букв ю/б/ж/Ж в ЙЦУКЕН, поэтому вызывающий
    /// ОБЯЗАН проверить полную конверсию по словарю (неоднозначность «думаю» vs «дума.»).
    /// Также ` [ ] — клавиши ё/х/ъ: отщепляем их с хвоста, чтобы тот же walk неоднозначности
    /// сработал симметрично (issue #22-скептик: иначе «ружьё»/«цех» шли бы мимо проверки).
    static func splitTrailingPunctuation(_ s: String) -> (coreLength: Int, suffix: String) {
        let punct: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "`", "[", "]"]
        var core = s[...]
        while let last = core.last, punct.contains(last) { core = core.dropLast() }
        return (core.count, String(s.dropFirst(core.count)))
    }

    /// Язык — иврит (BCP-47 `he` или устаревший `iw`). 3.0: гейт кросс-скрипт-детекта.
    static func isHebrew(_ lang: String) -> Bool {
        let two = lang.lowercased().prefix(2)
        return two == "he" || two == "iw"
    }

    static func isAllCaps(_ s: String) -> Bool {
        s == s.uppercased() && s != s.lowercased()
    }

    /// Похоже на программный идентификатор: внутренняя заглавная (camelCase/PascalCase)
    /// или смешение латиницы и кириллицы в одном токене → почти всегда код, не слово.
    static func looksLikeCodeIdentifier(_ s: String) -> Bool {
        for (i, c) in s.enumerated() where i > 0 && c.isUppercase { return true }
        var hasLatin = false, hasCyrillic = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A: hasLatin = true
            case 0x0400...0x04FF: hasCyrillic = true
            default: break
            }
        }
        return hasLatin && hasCyrillic
    }
}

/// Политика безопасности авто-конвертации.
enum AutoSwitchPolicy {
    /// Активен ли защищённый ввод (поле пароля, Secure Keyboard Entry в терминале) —
    /// тогда авто-конвертацию НЕ делаем (приватность; пароль не трогаем).
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Имя приложения, удерживающего защищённый ввод (Word, Terminal, менеджер
    /// паролей, loginwindow при системном запросе пароля и т.п.), или nil если
    /// определить не удалось. Читаем PID из IORegistry (то же, что `ioreg`:
    /// IOConsoleUsers → kCGSSessionSecureInputPID) и резолвим в человекочитаемое имя.
    static func secureInputHolderName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            entry, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for s in sessions {
            guard let raw = s["kCGSSessionSecureInputPID"] as? Int, raw != 0 else { continue }
            let pid = pid_t(raw)
            if let app = NSRunningApplication(processIdentifier: pid)?.localizedName, !app.isEmpty {
                return app
            }
            var buf = [CChar](repeating: 0, count: 4096)      // системные процессы (loginwindow) — не GUI-приложения
            let len = proc_pidpath(pid, &buf, 4096)
            if len > 0 {
                let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
                let name = (String(decoding: bytes, as: UTF8.self) as NSString).lastPathComponent
                if !name.isEmpty { return name }
            }
            return nil
        }
        return nil
    }

    /// Дефолтный список приложений, где авто выключено: терминалы, IDE, менеджеры
    /// паролей. Возвращается, пока пользователь не отредактировал список
    /// (см. SettingsManager.deniedApps). Запись с суффиксом "*" — префикс (весь вендор).
    static let defaultDeniedApps: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.sublimetext.4", "com.todesktop.230313mzl4w4u92", "com.google.android.studio",
        "com.jetbrains.*",
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    /// Менеджеры паролей — несъёмные из списка в UI (безопасность).
    static let protectedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    /// Терминалы: в них нет OS-выделения текста, поэтому «конвертация строки» (#24) через
    /// Shift+Cmd+← не выделяет строку, а в Terminal.app клавиши протекают мусором. Для них
    /// режим «вся строка» деградирует на буферный путь (последнее слово — он в терминалах
    /// работает, backspace+перепечатка). Список — терминалы из defaultDeniedApps.
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper",
    ]
    static func isTerminalApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return terminalApps.contains(id)
    }

    static func isDeniedApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        // Менеджеры паролей — жёсткий, не зависящий от пользовательского списка гейт:
        // их нельзя разблокировать ни через UI, ни через рассинхрон дефолтов.
        if protectedApps.contains(id) { return true }
        for entry in SettingsManager.shared.deniedApps {
            if entry.hasSuffix("*") {
                if id.hasPrefix(String(entry.dropLast())) { return true }
            } else if entry == id {
                return true
            }
        }
        return false
    }

    /// Слово в списке never-convert (обе стороны пары, без регистра).
    static func isDeniedWord(_ typed: String, _ converted: String) -> Bool {
        let set = SettingsManager.shared.deniedWordsSet
        guard !set.isEmpty else { return false }
        return set.contains(typed.lowercased()) || set.contains(converted.lowercased())
    }

    /// Слово в списке always-convert — матчим по СКОНВЕРТИРОВАННОЙ (целевой) форме.
    /// В список кладётся «целевое» слово (что должно получиться), а не мусор раскладки —
    /// иначе правильно набранное слово конвертилось бы обратно (пинг-понг).
    static func isAlwaysConvert(_ converted: String) -> Bool {
        let set = SettingsManager.shared.alwaysConvertWordsSet
        guard !set.isEmpty else { return false }
        return set.contains(converted.lowercased())
    }

    /// Клиенты удалённого рабочего стола: когда такое окно в фокусе, текст живёт
    /// на ДРУГОЙ машине — наш инстанс должен молчать и уступить удалённому TypeFlow.
    static let remoteClients: Set<String> = [
        "com.apple.ScreenSharing",   // Apple «Общий экран» / Screen Sharing.app
        "com.apple.RemoteDesktop",   // Apple Remote Desktop
    ]

    static func isRemoteDesktopClient(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return remoteClients.contains(id)
    }

    /// Правило «уступи удалёнке»: режим удалённого стола включён И в фокусе клиент
    /// удалёнки → этот инстанс ничего не делает (ни триггер, ни авто), чтобы не
    /// дублировать работу инстанса на контролируемой машине.
    static var shouldDeferToRemoteClient: Bool {
        guard SettingsManager.shared.remoteDesktopMode else { return false }
        return isRemoteDesktopClient(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
