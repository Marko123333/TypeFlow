import Foundation
import ServiceManagement

/// Централизованное хранение настроек через UserDefaults
/// Настройки приложения. Свойства thread-safe через UserDefaults.
final class SettingsManager: @unchecked Sendable {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoSwitch = "com.marko.localswitcher.autoSwitch"
        static let layout1ID = "com.marko.localswitcher.layout1ID"
        static let layout2ID = "com.marko.localswitcher.layout2ID"
        static let debugLog = "com.marko.localswitcher.debugLog"
        static let skippedVersion = "com.marko.localswitcher.skippedVersion"
        static let lastUpdateCheck = "com.marko.localswitcher.lastUpdateCheck"
        static let launchAtLogin = "com.marko.localswitcher.launchAtLogin"
        static let checkUpdatesEnabled = "com.marko.localswitcher.checkUpdatesEnabled"
        static let betaChannelEnabled = "com.marko.localswitcher.betaChannelEnabled"
        static let highestStableUpdateVersion = "com.marko.localswitcher.highestStableUpdateVersion"
        static let highestBetaUpdateVersion = "com.marko.localswitcher.highestBetaUpdateVersion"
        static let interfaceLanguage = "com.marko.localswitcher.interfaceLanguage"
        static let permissionsWereGranted = "com.marko.localswitcher.permissionsWereGranted"
        static let launchAtLoginAsked = "com.marko.localswitcher.launchAtLoginAsked"
        static let perAppLayout = "com.marko.localswitcher.perAppLayout"
        static let triggerKey = "com.marko.localswitcher.triggerKey"
        static let triggerRightOnly = "com.marko.localswitcher.triggerRightOnly"
        static let triggerDoubleTap = "com.marko.localswitcher.triggerDoubleTap"
        static let switchHotkey = "com.marko.localswitcher.switchHotkey"
        static let switchDoubleTap = "com.marko.localswitcher.switchDoubleTap"
        static let switchRightOnly = "com.marko.localswitcher.switchRightOnly"
        static let caseHotkey = "com.marko.localswitcher.caseHotkey"       // issue #29
        static let caseDoubleTap = "com.marko.localswitcher.caseDoubleTap"
        static let caseRightOnly = "com.marko.localswitcher.caseRightOnly"
        static let autoConvert = "com.marko.localswitcher.autoConvert"
        static let smartConversion = "com.marko.localswitcher.smartConversion"
        static let convertByText = "com.marko.localswitcher.convertByText"
        static let convertWholeLine = "com.marko.localswitcher.convertWholeLine"
        static let remoteDesktopMode = "com.marko.localswitcher.remoteDesktopMode"
        static let showRemoteDesktopBeta = "com.marko.localswitcher.showRemoteDesktopBeta"
        static let autoConvertOffered = "com.marko.localswitcher.autoConvertOffered"
        static let lastWhatsNewVersion = "com.marko.localswitcher.lastWhatsNewVersion"
        static let lastBetaNotesShown = "com.marko.localswitcher.lastBetaNotesShown"
        static let keySound = "com.marko.localswitcher.keySound"
        static let caretFlag = "com.marko.localswitcher.caretFlag"
        static let secureInputNotice = "com.marko.localswitcher.secureInputNotice"
        static let monochromeIcon = "com.marko.localswitcher.monochromeIcon"
        static let deniedAppsAdded = "com.marko.localswitcher.deniedAppsAdded"
        static let deniedAppsRemoved = "com.marko.localswitcher.deniedAppsRemoved"
        static let deniedWords = "com.marko.localswitcher.deniedWords"
        static let alwaysConvertWords = "com.marko.localswitcher.alwaysConvertWords"
    }

    private init() {}

    // MARK: - Properties

    var autoSwitchEnabled: Bool {
        get { defaults.object(forKey: Keys.autoSwitch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoSwitch) }
    }

    /// ID первой раскладки (пустая строка = авто-определение)
    var layout1ID: String {
        get { defaults.string(forKey: Keys.layout1ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout1ID) }
    }

    /// ID второй раскладки (пустая строка = авто-определение)
    var layout2ID: String {
        get { defaults.string(forKey: Keys.layout2ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout2ID) }
    }

    var debugLogEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugLog) }
        set { defaults.set(newValue, forKey: Keys.debugLog) }
    }

    var skippedVersion: String {
        get { defaults.string(forKey: Keys.skippedVersion) ?? "" }
        set { defaults.set(newValue, forKey: Keys.skippedVersion) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Keys.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheck) }
    }

    var launchAtLogin: Bool {
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            let enabled = newValue
            DispatchQueue.main.async {
                self.doUpdateLoginItem(enabled: enabled)
            }
        }
    }

    /// Авто-проверка обновлений при запуске (дефолт: включено).
    /// На ручную проверку через меню не влияет.
    var checkUpdatesEnabled: Bool {
        get { defaults.object(forKey: Keys.checkUpdatesEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.checkUpdatesEnabled) }
    }

    /// Канал бета-версий: когда включён, авто-проверка обновлений также смотрит фид
    /// пред-релизов (version-beta.json) и предлагает более свежую бету. По умолчанию
    /// ВЫКЛ — обычные пользователи получают только стабильные релизы.
    var betaChannelEnabled: Bool {
        get { defaults.bool(forKey: Keys.betaChannelEnabled) }
        set { defaults.set(newValue, forKey: Keys.betaChannelEnabled) }
    }

    var highestStableUpdateVersion: String {
        get { defaults.string(forKey: Keys.highestStableUpdateVersion) ?? "" }
        set { defaults.set(newValue, forKey: Keys.highestStableUpdateVersion) }
    }

    var highestBetaUpdateVersion: String {
        get { defaults.string(forKey: Keys.highestBetaUpdateVersion) ?? "" }
        set { defaults.set(newValue, forKey: Keys.highestBetaUpdateVersion) }
    }

    /// Язык интерфейса (пустая строка = авто-определение по системе)
    var interfaceLanguage: String {
        get { defaults.string(forKey: Keys.interfaceLanguage) ?? "" }
        set {
            defaults.set(newValue, forKey: Keys.interfaceLanguage)
            L10n.reloadLanguage()
        }
    }

    /// Флаг: разрешения были ранее выданы (для определения сброса после обновления)
    var permissionsWereGranted: Bool {
        get { defaults.bool(forKey: Keys.permissionsWereGranted) }
        set { defaults.set(newValue, forKey: Keys.permissionsWereGranted) }
    }

    var launchAtLoginAsked: Bool {
        get { defaults.bool(forKey: Keys.launchAtLoginAsked) }
        set { defaults.set(newValue, forKey: Keys.launchAtLoginAsked) }
    }

    var perAppLayout: Bool {
        get { defaults.bool(forKey: Keys.perAppLayout) }
        set { defaults.set(newValue, forKey: Keys.perAppLayout) }
    }

    // MARK: - Триггер конвертации

    /// Клавиша-триггер: "option" | "command" | "control" | "shift" | "capsLock".
    /// Дефолт — Shift: в паре с switchHotkey=shift включает общий Caramba-style
    /// распознаватель (один Shift = раскладка, два = конвертация).
    var triggerKey: String {
        get { defaults.string(forKey: Keys.triggerKey) ?? "shift" }
        set { defaults.set(newValue, forKey: Keys.triggerKey) }
    }

    /// Реагировать только на правую клавишу модификатора (для option/command/control/shift).
    var triggerRightOnly: Bool {
        get { defaults.bool(forKey: Keys.triggerRightOnly) }
        set { defaults.set(newValue, forKey: Keys.triggerRightOnly) }
    }

    /// Двойной тап вместо одиночного.
    var triggerDoubleTap: Bool {
        get {
            defaults.object(forKey: Keys.triggerDoubleTap) == nil
                ? true : defaults.bool(forKey: Keys.triggerDoubleTap)
        }
        set { defaults.set(newValue, forKey: Keys.triggerDoubleTap) }
    }

    /// issue #14: отдельный хоткей «просто переключить раскладку» (без конверсии) —
    /// в т.ч. модификаторные комбо (Ctrl+Shift), которые системно назначить нельзя.
    /// Кодировка как у triggerKey; дефолт Shift. Совпадение Shift с триггером
    /// намеренно поддерживается общим распознавателем жестов.
    var switchHotkey: String {
        get { defaults.string(forKey: Keys.switchHotkey) ?? "shift" }
        set { defaults.set(newValue, forKey: Keys.switchHotkey) }
    }

    /// issue #14: смена раскладки по ДВОЙНОМУ тапу хоткея (зеркало triggerDoubleTap).
    var switchDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.switchDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.switchDoubleTap) }
    }

    /// issue #14: реагировать только на ПРАВУЮ клавишу хоткея (зеркало triggerRightOnly).
    /// Действует лишь для одиночных модификаторов; для комбо сторона не различается.
    var switchRightOnly: Bool {
        get { defaults.bool(forKey: Keys.switchRightOnly) }
        set { defaults.set(newValue, forKey: Keys.switchRightOnly) }
    }

    /// issue #29: хоткей смены регистра (кодировка как triggerKey; пустая строка — выключен, дефолт).
    var caseHotkey: String {
        get { defaults.string(forKey: Keys.caseHotkey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.caseHotkey) }
    }
    var caseDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.caseDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.caseDoubleTap) }
    }
    var caseRightOnly: Bool {
        get { defaults.bool(forKey: Keys.caseRightOnly) }
        set { defaults.set(newValue, forKey: Keys.caseRightOnly) }
    }

    /// Caps Lock как триггер требует consume-tap (чтобы подавить переключение регистра).
    var triggerIsCapsLock: Bool { triggerKey == "capsLock" }

    /// Автоматическая конвертация «на лету» (детект неправильной раскладки на границе
    /// слова). Отдельный флаг от autoSwitchEnabled (тот гейтит РУЧНОЙ триггер).
    /// В этой производной сборке включено по умолчанию; строгие словарные гейты,
    /// защищённый ввод и исключения приложений остаются обязательными.
    var autoConvert: Bool {
        get {
            defaults.object(forKey: Keys.autoConvert) == nil
                ? true : defaults.bool(forKey: Keys.autoConvert)
        }
        set { defaults.set(newValue, forKey: Keys.autoConvert) }
    }

    /// issue #22 (вариант B): умная по-словная конверсия выделения — флипаем только слова не в
    /// той раскладке, а верный текст оставляем («iPhone стоит»). По умолчанию ВКЛ. Выключено —
    /// старое одностороннее поведение (всё выделение в одну сторону по текущей раскладке).
    var smartConversion: Bool {
        get { defaults.object(forKey: Keys.smartConversion) == nil ? true : defaults.bool(forKey: Keys.smartConversion) }
        set { defaults.set(newValue, forKey: Keys.smartConversion) }
    }

    /// issue #22 (вариант A): ручной триггер конвертирует ПО ТЕКСТУ — тотальный флип обеих
    /// письменностей (латиница↔кириллица) вместо направления по активной раскладке. Полезно
    /// для mixed-мусора, но переворачивает и намеренный второй язык. По умолчанию ВЫКЛ.
    /// Перебивает «Умную конверсию».
    var convertByText: Bool {
        get { defaults.bool(forKey: Keys.convertByText) }
        set { defaults.set(newValue, forKey: Keys.convertByText) }
    }

    /// issue #24: триггер конвертирует ВСЮ строку (от курсора до начала строки), а не только
    /// последнее слово — сам выделяет строку (без мыши) и прогоняет через умную конверсию.
    /// Удобно в терминале и когда набрал несколько слов не в той раскладке. По умолчанию ВЫКЛ.
    var convertWholeLine: Bool {
        get { defaults.bool(forKey: Keys.convertWholeLine) }
        set { defaults.set(newValue, forKey: Keys.convertWholeLine) }
    }

    /// issue #10: показывать флаг раскладки у текстовой каретки (бета). По умолчанию ВЫКЛ.
    /// issue #27: показывать неактивирующую подсказку, когда защищённый ввод ставит на паузу.
    /// По умолчанию включено; можно отключить тем, кому она мешает.
    var secureInputNoticeEnabled: Bool {
        get { defaults.object(forKey: Keys.secureInputNotice) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.secureInputNotice) }
    }

    var caretFlag: Bool {
        get { defaults.bool(forKey: Keys.caretFlag) }
        set { defaults.set(newValue, forKey: Keys.caretFlag) }
    }

    /// Режим работы через удалённый рабочий стол (Apple Screen Sharing и т.п.).
    /// При включении: tap поднимается на session-уровень (видит проброшенные
    /// нажатия), и инстанс «уступает удалёнке», если в фокусе клиент удалёнки.
    var remoteDesktopMode: Bool {
        get { defaults.bool(forKey: Keys.remoteDesktopMode) }
        set { defaults.set(newValue, forKey: Keys.remoteDesktopMode) }
    }

    /// Показывать ли тумблер «Режим удалённого стола» (видимая бета в 2.5). По умолчанию
    /// ВКЛючён; спрятать можно явно: `defaults write com.marko.localswitcher.app com.marko.localswitcher.showRemoteDesktopBeta -bool NO`.
    var showRemoteDesktopBeta: Bool {
        get {
            // Нет записи в defaults → считаем включённым (дефолт ON для 2.5).
            if defaults.object(forKey: Keys.showRemoteDesktopBeta) == nil { return true }
            return defaults.bool(forKey: Keys.showRemoteDesktopBeta)
        }
        set { defaults.set(newValue, forKey: Keys.showRemoteDesktopBeta) }
    }

    /// Последняя версия, для которой показали окно «Что нового». Пусто = ещё не показывали.
    var lastWhatsNewVersion: String {
        get { defaults.string(forKey: Keys.lastWhatsNewVersion) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastWhatsNewVersion) }
    }

    /// Последняя бета-версия, для которой показали окно «Что нового в бете» (отдельная
    /// витрина беты — текст берётся из notes бета-фида, не из локализованного whatsnew.body).
    var lastBetaNotesShown: String {
        get { defaults.string(forKey: Keys.lastBetaNotesShown) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastBetaNotesShown) }
    }

    /// Предлагали ли уже автозамену при первом запуске (онбординг показывается один раз).
    var autoConvertOffered: Bool {
        get { defaults.bool(forKey: Keys.autoConvertOffered) }
        set { defaults.set(newValue, forKey: Keys.autoConvertOffered) }
    }

    /// issue #7: звук раскладки на первой букве после смены раскладки. По умолчанию OFF.
    var keySound: Bool {
        get { defaults.bool(forKey: Keys.keySound) }
        set { defaults.set(newValue, forKey: Keys.keySound) }
    }

    /// Иконка меню-бара в системном стиле: монохромная плашка «РУ/EN» (template)
    /// вместо цветного флага-эмодзи. По умолчанию OFF — флаг привычнее.
    var monochromeIcon: Bool {
        get { defaults.bool(forKey: Keys.monochromeIcon) }
        set { defaults.set(newValue, forKey: Keys.monochromeIcon) }
    }

    /// Приложения, где авто-конверсия выключена. Эффективный список = дефолты минус
    /// явно удалённые пользователем плюс явно добавленные. Так новые дефолты из будущих
    /// версий подхватываются автоматически, а правки пользователя сохраняются.
    var deniedApps: [String] {
        get {
            let removed = Set(defaults.stringArray(forKey: Keys.deniedAppsRemoved) ?? [])
            let added = defaults.stringArray(forKey: Keys.deniedAppsAdded) ?? []
            var result = AutoSwitchPolicy.defaultDeniedApps.filter { !removed.contains($0) }
            for a in added where !result.contains(a) { result.append(a) }
            return result
        }
        set {
            let defaultsSet = Set(AutoSwitchPolicy.defaultDeniedApps)
            let newSet = Set(newValue)
            let removed = AutoSwitchPolicy.defaultDeniedApps.filter { !newSet.contains($0) }
            let added = newValue.filter { !defaultsSet.contains($0) }
            defaults.set(removed, forKey: Keys.deniedAppsRemoved)
            defaults.set(added, forKey: Keys.deniedAppsAdded)
        }
    }

    /// Слова, которые авто-конверсия никогда не трогает.
    var deniedWords: [String] {
        get { defaults.stringArray(forKey: Keys.deniedWords) ?? [] }
        set { defaults.set(newValue, forKey: Keys.deniedWords) }
    }
    var deniedWordsSet: Set<String> { Set(deniedWords.map { $0.lowercased() }) }

    /// Слова, которые авто-конверсия переключает всегда (даже если их нет в словаре).
    var alwaysConvertWords: [String] {
        get { defaults.stringArray(forKey: Keys.alwaysConvertWords) ?? [] }
        set { defaults.set(newValue, forKey: Keys.alwaysConvertWords) }
    }
    var alwaysConvertWordsSet: Set<String> { Set(alwaysConvertWords.map { $0.lowercased() }) }

    // MARK: - GitHub coordinates
    static let githubOwner = "Marko123333"
    static let githubRepo = "TypeFlow"
    static var githubURL: String { "https://github.com/\(githubOwner)/\(githubRepo)" }
    /// GitHub does not expose a safe GET-only URL that automatically stars a repo.
    /// Open the project page so the signed-in user can make that explicit choice.
    static var starURL: String { githubURL }
    /// A project-owned page with financial and non-financial support options.
    /// It remains useful before a payment provider is configured.
    static var supportURL: String { "\(githubURL)/blob/main/SUPPORT.md" }
    /// Public contact channel that works without publishing a personal email address.
    static var contactURL: String { "\(githubURL)/issues/new/choose" }
    /// Email для «Связаться с разработчиком» (mailto с предзаполнением). Пусто → кнопка
    /// открывает GitHub Issues как фолбэк.
    static let contactEmail = ""
    /// Telegram-чат поддержки (t.me/…). Пусто → пункт меню скрыт. Инвайт-ссылка группы
    /// обсуждения канала проекта (её можно отозвать в настройках группы - тогда обновить).
    static let telegramChatURL = ""
    /// Internal updater payload keeps the legacy basename for 0.1.11. The public
    /// permanent download remains TypeFlow-macOS-arm64.dmg in README/releases.
    static func releaseDMGFilename(version: String) -> String {
        "LocalSwitcher-\(version).dmg"
    }
    static func releaseDMGURL(version: String) -> String {
        "\(githubURL)/releases/download/v\(version)/\(releaseDMGFilename(version: version))"
    }

    // MARK: - Login Item

    private func doUpdateLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                rslog("Login item registered")
            } else {
                try service.unregister()
                rslog("Login item unregistered")
            }
        } catch {
            rslog("Login item error: \(error)")
        }
    }

    /// Текущий статус автозапуска (может отличаться от настройки)
    var loginItemStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }
}
