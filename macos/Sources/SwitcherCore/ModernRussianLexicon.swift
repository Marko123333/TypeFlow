/// Curated modern Russian vocabulary that is poorly covered by conservative
/// spelling dictionaries: IT/product jargon, social-media vocabulary and AI
/// terminology. Russian inflection is generated locally from reviewed stems so
/// users do not need a separate exception for every case, number or verb form.
public enum ModernRussianLexicon {
    /// Exposed for deterministic collision audits in the application tests.
    public static let allWords: Set<String> = {
        var result: Set<String> = [
            // AI abbreviations, indeclinable terms and common spelling variants.
            "ии", "аи", "ллм", "раг", "ревью", "селфи", "сторис", "ишью",
            "воркфлоу", "флоу",
            "нейросеть", "нейросети", "нейросетью", "нейросетей",
            "нейросетям", "нейросетями", "нейросетях",
            "нейромодель", "нейромодели", "нейромоделью", "нейромоделей",
            "нейромоделям", "нейромоделями", "нейромоделях",
            "файн-тюнинг", "промпт-инжиниринг", "вайб-кодинг",
            "код-ревью", "пул-реквест", "пулл-реквест",
            "софт-скилл", "хард-скилл", "опенсорс", "ноукод", "лоукод",
            "косплей", "косплея", "косплею", "косплеем", "косплее",
            "косплеи", "косплеев", "косплеям", "косплеями", "косплеях",

            // Common derived and irregular forms not covered by the generators.
            "логиниться", "логинюсь", "логинишься", "логинится", "логинимся",
            "логинитесь", "логинятся", "залогиниться", "залогинился", "залогинились",
            "коннектиться", "коннекчусь", "коннектишься", "коннектится",
            "коннектимся", "коннектитесь", "коннектятся", "законнектиться",
            "разбанить", "разбанил", "разбанили", "разбанишь", "разбаните",
        ]

        // Product, engineering, business, media and AI nouns ending in a
        // consonant. Generate the common singular cases and plural paradigm.
        let masculineNouns = [
            "ресерч", "ресёрч", "рисерч", "рисёрч", "апдейт", "апгрейд",
            "бэкап", "бекап", "беккап", "бэклог", "беклог", "бэкенд", "бекенд",
            "фронтенд", "девопс", "фидбек", "митап", "воркшоп", "роадмап",
            "дедлайн", "юзкейс", "стейкхолдер", "оффер", "офер", "грейд",
            "скилл", "тимлид", "джун", "мидл", "сеньор", "саппорт", "дашборд",
            "лендинг", "продакшен", "стейджинг", "коммит", "мерж",
            "пуш", "пулл", "реквест", "дебаг", "рефакторинг",
            "кодревью", "фолбэк", "фолбек", "хотфикс", "сетап", "конфиг",
            "спринт", "скрам", "таск", "тикет", "бриф", "кейс", "стартап",
            "фаундер", "хакатон", "нетворкинг", "коворкинг",
            "тимбилдинг", "брейншторм", "фриланс", "фрилансер", "продакт",
            "продактменеджер", "проджект", "проджектменеджер",

            "промпт", "промптинг", "промптер", "токен", "датасет", "эмбеддинг",
            "инференс", "файнтюнинг", "бенчмарк", "трансформер", "чатбот",
            "копилот", "дипфейк", "эвал", "пайплайн", "энкодер", "декодер",
            "лосс", "вайбкодинг", "вайбкодер", "агент",

            "контент", "креатор", "инфлюенсер", "стример", "подкаст", "рилс",
            "шортс", "лайк", "дизлайк", "репост", "донат", "хайп", "хейт",
            "хейтер", "тренд", "вайб", "кринж", "токсик", "буллинг",
            "кликбейт", "челлендж", "флешмоб", "мем", "чат", "стрим", "гейминг",
            "геймер", "фанфик", "мерч", "дроп", "скин",
            "бан", "флуд", "спам", "скам", "фейк", "пруф", "инсайд", "спойлер",
            "тизер", "трейлер", "саундтрек", "плейлист", "трек", "ремикс", "кавер",

            "маркетплейс", "кэшбэк", "кешбэк", "кешбек", "шопинг", "шоппинг",
            "фудкорт", "стритфуд", "коуч", "ментор", "эдтех", "финтех", "фудтех",
            "перформанс", "таргет", "таргетинг", "брендинг", "ребрендинг",
        ]

        let spellingRuleI: Set<Character> = ["г", "к", "х", "ж", "ч", "ш", "щ"]
        let genitivePluralEY: Set<Character> = ["ж", "ч", "ш", "щ", "ц"]
        func addMasculineNoun(_ lemma: String) {
            guard let last = lemma.last else { return }
            let plural = lemma + (spellingRuleI.contains(last) ? "и" : "ы")
            let genitivePlural = lemma + (genitivePluralEY.contains(last) ? "ей" : "ов")
            result.formUnion([
                lemma, lemma + "а", lemma + "у", lemma + "ом", lemma + "е",
                plural, genitivePlural, lemma + "ам", lemma + "ами", lemma + "ах",
            ])
        }
        for noun in masculineNouns { addMasculineNoun(noun) }

        // Productive colloquial feminine nouns (`фича`, `нейронка`).
        let feminineANouns = [
            "фича", "нейронка", "генеративка", "мультимодалка", "диффузионка",
            "админка", "удаленка", "удалёнка",
        ]
        func addFeminineANoun(_ lemma: String) {
            guard lemma.hasSuffix("а") else { return }
            let stem = String(lemma.dropLast())
            guard let last = stem.last else { return }
            let plural = stem + (spellingRuleI.contains(last) ? "и" : "ы")
            result.formUnion([
                lemma, plural, stem + "е", stem + "у", stem + "ой", stem + "ою",
                stem + "ам", stem + "ами", stem + "ах",
            ])
        }
        for noun in feminineANouns { addFeminineANoun(noun) }

        let productivePrefixes = ["", "по", "за", "про", "до", "пере", "на", "от"]

        // Borrowed verbs adapted with Russian -ить. Stable forms are generated;
        // irregular first-person forms are added only where explicitly reviewed.
        let iVerbStems = [
            "ресерч", "ресёрч", "рисерч", "рисёрч", "гугл", "фикс", "дебаж",
            "мерж", "пуш", "пулл", "коммит", "апдейт", "апгрейд", "бэкап",
            "бекап", "беккап", "бан", "донат", "репост", "хейт", "стрим",
            "сейв", "релиз", "монитор", "тест", "рефактор", "хост", "билд",
            "шер", "саппорт", "скрин", "флуд", "спам", "тролл", "краш",
            "фейл", "апрув", "буст", "скролл", "промпт",
        ]
        func addIVerb(_ stem: String, allowBarePrefixedCommand: Bool = false) {
            result.insert(stem)
            let stableForms = [
                stem + "ить", stem + "и", stem + "ишь", stem + "ит", stem + "им",
                stem + "ите", stem + "ил", stem + "ила", stem + "ило", stem + "или",
                stem + "ив", stem + "ивший",
            ]
            result.formUnion(stableForms)
            for prefix in productivePrefixes.dropFirst() {
                if allowBarePrefixedCommand { result.insert(prefix + stem) }
                for form in stableForms { result.insert(prefix + form) }
            }
        }
        for stem in iVerbStems {
            addIVerb(stem, allowBarePrefixedCommand: stem.hasSuffix("серч"))
        }
        for stem in ["ресерч", "ресёрч", "рисерч", "рисёрч"] {
            for prefix in productivePrefixes {
                result.formUnion([
                    prefix + stem + "у", prefix + stem + "ат",
                    prefix + stem + "ущий", prefix + stem + "енный",
                ])
            }
        }

        // Productive -ать adaptation (`чекать`, `лайкать`, `свайпать`).
        let aVerbStems = ["чек", "лайк", "дизлайк", "юз", "клик", "свайп", "тап", "скип", "тег"]
        func addAVerb(_ stem: String) {
            let forms = [
                stem, stem + "ать", stem + "аю", stem + "аешь", stem + "ает",
                stem + "аем", stem + "аете", stem + "ают", stem + "ал", stem + "ала",
                stem + "ало", stem + "али", stem + "ай", stem + "айте",
            ]
            result.formUnion(forms)
            for prefix in productivePrefixes.dropFirst() {
                for form in forms.dropFirst() { result.insert(prefix + form) }
            }
        }
        for stem in aVerbStems { addAVerb(stem) }

        // Vowel-ending stems have spelling-changing imperatives.
        let deployForms = [
            "деплой", "деплоить", "деплою", "деплоишь", "деплоит", "деплоим",
            "деплоите", "деплоят", "деплоил", "деплоила", "деплоили",
        ]
        for prefix in productivePrefixes {
            for form in deployForms { result.insert(prefix + form) }
        }
        let reviewForms = [
            "ревью", "ревьюить", "ревьюю", "ревьюишь", "ревьюит", "ревьюим",
            "ревьюите", "ревьюят", "ревьюил", "ревьюила", "ревьюили",
            "ревьюй", "ревьюйте",
        ]
        for prefix in productivePrefixes {
            for form in reviewForms { result.insert(prefix + form) }
        }

        // Reviewed lock/unlock jargon: finite forms plus reflexive counterparts.
        // Do not apply these endings to unrelated stems or broad corpus entries.
        for stem in ["лоч", "залоч", "разлоч", "перелоч", "анлоч"] {
            let forms = ["ить", "у", "ишь", "ит", "им", "ите", "ат",
                         "ил", "ила", "ило", "или", "и"]
            for ending in forms {
                let form = stem + ending
                result.insert(form)
                result.insert(form + ((ending == "у" || ending == "ите" || ending == "ила" ||
                                       ending == "ило" || ending == "или" || ending == "и") ? "сь" : "ся"))
            }
            result.formUnion([stem + "ив", stem + "ившись"])
            for ending in ["енный", "енная", "енное", "енные", "енного", "енной", "енных",
                           "енному", "енным", "енную", "енными", "енном", "ен", "ена", "ено", "ены"] {
                result.insert(stem + ending)
            }
        }

        return result
    }()

    public static func contains(_ word: String) -> Bool {
        allWords.contains(word.lowercased())
    }
}
