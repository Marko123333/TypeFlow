import Foundation

/// High-frequency Russian initialisms and conventional short names that are
/// often absent from spellcheckers. The entries are stored in lowercase and
/// matched case-insensitively, so `фсб`, `Фсб` and `ФСБ` share one rule.
///
/// Keep this list conservative: an entry is an automatic layout-switch signal,
/// not merely a spelling-dictionary addition. Two-letter initialisms are mostly
/// excluded because their QWERTY key images frequently collide with real short
/// English words (`рф` -> `ha`, for example).
public enum RussianAbbreviations {
    /// Manually reviewed, high-frequency entries. These supplement the open
    /// corpus with current organisations, products and informal shorthand.
    private static let reviewed: Set<String> = [
        // Government, security, law enforcement and public administration.
        "фсб", "фбр", "мвд", "мчс", "мид", "фсо", "свр", "скр",
        "фсин", "фссп", "фнс", "фмс", "фстэк", "фскн", "гибдд",
        "гаи", "дпс", "пдн", "овд", "увд", "омвд", "рувд", "гувд",
        "омон", "собр", "цсн", "кгб", "нквд", "цру", "анб",
        "фоив", "мфц", "загс", "нпа", "коап", "упк", "гпк",
        "гост", "санпин", "снип", "мрот", "росстат", "росреестр",
        "роскомнадзор", "росгвардия", "росавиация", "роструд",
        "роспотребнадзор", "росприроднадзор", "минфин", "минюст",
        "минздрав", "минтруд", "минцифры", "минобрнауки",
        "фгис", "еирц", "гжи", "рсо", "гуп", "муп", "фгуп",

        // Countries, unions and international organisations.
        "ссср", "рсфср", "снг", "еаэс", "одкб", "оон", "нато",
        "обсе", "брикс", "шос", "вто", "воз", "мок", "мвф",
        "юнеско", "юнисеф", "магатэ", "асеан", "апек", "оэср",
        "опек", "сша", "оаэ", "фрг", "кнр", "кндр", "юар",

        // Housing, utilities, property and municipal services.
        "жкх", "тсж", "жск", "жэк", "дэз", "бти", "гис", "мкд",
        "тко", "одн", "гвс", "хвс", "крт", "дду", "дск",

        // Education, science and culture.
        "мгу", "спбгу", "мгимо", "рудн", "вшэ", "вуз", "ссуз",
        "егэ", "огэ", "гиа", "впр", "вкр", "нии", "ран", "вак",
        "рнф", "рффи", "рфбр", "ниу", "фгос", "спо", "дпо",
        "ргб", "рнб", "гтрк", "вгтрк", "тасс", "риа", "рбк",
        "нтв", "тнт", "квн", "сми",

        // Business, finance, taxes and personal documents.
        "ооо", "оао", "зао", "пао", "ано", "нко", "пко", "ндс",
        "нпд", "усн", "осн", "есхн", "енп", "инн", "кпп", "огрн",
        "огрнип", "оквэд", "окпо", "октмо", "кбк", "бик", "снилс",
        "фио", "пфр", "сфр", "фомс", "фсс", "цбд", "ввп", "кпд",
        "ауд", "руб", "коп", "тыс", "млн", "млрд", "егрн", "егрюл",
        "егрип", "сбп", "офд", "ккт", "бсо", "мсп", "кфх", "лпх",
        "ижс", "чоп", "чоо",

        // Transport, roads and insurance.
        "птс", "стс", "осаго", "каско", "пдд", "дтп", "ржд",
        "глонасс", "гтд", "свх", "таксфри",

        // Medicine, biology and health.
        "вич", "спид", "орви", "орз", "днк", "рнк", "мрт", "узи",
        "экг", "эко", "омс", "дмс", "вмп", "жкт", "цнс", "сдвг",
        "рлс", "бад", "впч", "зож", "ковид",

        // Technology, communications and engineering.
        "икт", "асу", "сапр", "апи", "впн", "впс", "ссд", "озу",
        "пзу", "эцп", "кэп", "уэп", "смс", "ммс", "жки", "жкд",
        "бп", "ибп", "цод", "лвс", "влс", "ддос", "субд", "поис",
        "ии", "аи", "ллм", "раг",

        // Industry, energy, emergency response and the armed forces.
        "аэс", "гэс", "тэс", "тэц", "лэп", "гсм", "апк", "ниокр",
        "окр", "чс", "рсчс", "еддс", "вмф", "вкс", "вдв", "рвсн",
        "пво", "гру", "сво", "ато", "бпла", "бла", "бтр", "бмп",
        "птрк", "пзрк", "рсзо",

        // Common conversational and publishing abbreviations.
        "имхо", "лол", "кек", "пж", "пжл", "спс", "прив", "тд",
        "тп", "стр", "шт", "мин", "сек", "мес", "тел",
    ]

    private static let corpus: Set<String> = {
        guard let url = SwitcherCoreResources.bundle.url(
            forResource: "ru_abbreviations",
            withExtension: "txt"
        ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return Set(contents.split(whereSeparator: \.isNewline).compactMap { line in
            let token = line.trimmingCharacters(in: .whitespaces)
            return token.isEmpty || token.hasPrefix("#") ? nil : token
        })
    }()

    /// Exposed for deterministic coverage and key-image collision audits.
    public static let all: Set<String> = reviewed.union(corpus)

    public static var reviewedCount: Int { reviewed.count }
    public static var corpusCount: Int { corpus.count }

    public static func isReviewed(_ token: String) -> Bool {
        reviewed.contains(token.lowercased())
    }

    public static func contains(_ token: String) -> Bool {
        all.contains(token.lowercased())
    }
}
