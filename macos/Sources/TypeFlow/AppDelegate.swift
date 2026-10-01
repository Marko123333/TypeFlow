import AppKit
import ApplicationServices
import SwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let keyboardMonitor = KeyboardMonitor()
    private let textConverter = TextConverter()
    private let settingsController = SettingsWindowController()
    private let perAppLayoutManager = PerAppLayoutManager()
    private let passwordLayoutGuard = PasswordLayoutGuard()
    private var permissionCheckTimer: Timer?
    private var iconRefreshTimer: Timer?
    private var updateCheckTimer: Timer?   // периодическая авто-проверка обновлений, пока приложение работает
    private var monitoringActive = false
    private var caretIndicator: CaretIndicator?   // issue #10: флаг у каретки (бета, по умолчанию OFF)
    private let secureNotice = SecureInputNotice()  // issue #27: подсказка о защ. вводе без кражи фокуса
    private var yoRestorer: YoRestorer?
    private var lastFlagShown: String?            // идентичность раскладки для детекта смены (не title!)
    private var badgeCache: [String: NSImage] = [:]  // монохромные плашки, чтобы не перерисовывать 2с-опросом

    func applicationDidFinishLaunching(_ notification: Notification) {
        passwordLayoutGuard.onProtectedFocus = { [weak self] in
            self?.keyboardMonitor.suspendForProtectedInput()
        }
        passwordLayoutGuard.start()
        setupStatusItem()
        setupSettingsCallbacks()
        syncLoginItem()
        // «Запускались раньше?» снимаем ДО визарда: он через startMonitoring →
        // offerLaunchAtLoginIfNeeded выставляет launchAtLoginAsked уже на этом же
        // первом запуске, иначе «Что нового» ложно показалось бы на свежей установке.
        let ranBefore = SettingsManager.shared.launchAtLoginAsked
        runPermissionWizard()
        showWhatsNewIfNeeded(hasRunBefore: ranBefore)
        showBetaWhatsNewIfNeeded()   // отдельная витрина для бет (текст из бета-фида)
        UpdateChecker.checkOnLaunch()
        // Периодическая авто-проверка обновлений, пока приложение работает (не только на старте).
        // Тикает каждые 6ч; сам запрос к GitHub не чаще раза в сутки (троттл в UpdateChecker) и
        // уважает настройку «Автоматически проверять обновления» (её можно снять, чтобы отключить).
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.checkPeriodic() }
        }
        // Прогрев NSSpellChecker: первый чек поднимает XPC AppleSpell (сотни мс на main) —
        // прогреваем в тихую паузу после старта, а не на первом пробеле пользователя.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in Dict.warmUp() }
        }
        // 140k+ ё-forms are parsed off the event-tap/main thread so startup and
        // the first keystrokes never stall on dictionary construction.
        Task {
            let loaded = await Task.detached(priority: .utility) {
                BundledRussianLexicon.makeYoRestorer()
            }.value
            self.yoRestorer = loaded
        }
    }

    private func setupSettingsCallbacks() {
        settingsController.onAutoSwitchChanged = { [weak self] _ in
            // Не адресуем пункт по индексу: с 2.5.0 item(at: 0) — строка версии, а со списком
            // раскладок индексы вообще динамические. Пересборка — как у соседних колбэков.
            self?.rebuildMenu()
        }
        settingsController.onPerAppLayoutChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.startPerAppLayout()
            } else {
                self.perAppLayoutManager.stop()
            }
        }
        settingsController.onLanguageChanged = { [weak self] in
            self?.rebuildMenu()
        }
        settingsController.onTriggerChanged = { [weak self] in
            self?.reconfigureTap()
        }
        settingsController.onAutoConvertChanged = { [weak self] _ in
            self?.rebuildMenu()  // синхронизировать галочку в меню
        }
        settingsController.onRemoteDesktopChanged = { [weak self] _ in
            self?.reconfigureTap()  // уровень tap зависит от режима
            self?.rebuildMenu()
        }
        settingsController.onCaretFlagChanged = { [weak self] _ in
            self?.rebuildMenu()          // синхронизировать галочку в меню
            self?.syncCaretIndicator()   // создать/снести индикатор + обновить гейт onUserInput
        }
    }

    // MARK: - Learn-from-undo (предложить добавить слово в never-convert)

    /// Последняя авто-конвертация: исходный ввод, эквиваленты после смены раскладки и время.
    /// Нужна и для ручного отката, и для распознавания немедленного Backspace/Cmd+Z.
    private var lastAutoConverted: (word: String, alternatives: Set<String>, at: Date)?
    /// Если пользователь сразу удаляет нашу замену, не спорим с ним повторно в этой сессии.
    private var sessionCorrectionSuppression = SessionCorrectionSuppression()
    /// Анти-наг: за сессию про одно слово спрашиваем один раз.
    private var offeredExceptionWords: Set<String> = []

    /// Анти-наг для уведомления о защищённом вводе (не чаще раза в N секунд).
    private var lastSecureNoticeAt: Date?

    /// Ручной триггер нажат, но активен защищённый ввод (фокус в поле пароля — часто во
    /// вкладке браузера в фоне) → конверсия by design не трогает клавиши. Без подсказки это
    /// выглядит как «приложение сломалось» (реальный кейс: пользователь мял триггер и лез в
    /// ioreg). Показываем разовое (троттлённое) объяснение с лечением.
    private func notifySecureInputPaused() {
        guard SettingsManager.shared.secureInputNoticeEnabled else { return }
        if let last = lastSecureNoticeAt, Date().timeIntervalSince(last) < 180 { return }
        lastSecureNoticeAt = Date()
        let holder = AutoSwitchPolicy.secureInputHolderName() ?? L10n.securePausedUnknownApp
        // issue #27: неактивирующая плашка вместо NSAlert.runModal() — модалка активировала
        // приложение и уводила фокус из поля пароля (пользователь терял место в терминале).
        secureNotice.show(title: L10n.securePausedTitle,
                          body: String(format: L10n.securePausedBody, holder))
    }

    private func offerExceptionAfterUndo() {
        guard let last = lastAutoConverted, Date().timeIntervalSince(last.at) < 8 else { return }
        lastAutoConverted = nil
        let word = last.word
        let key = word.lowercased()
        guard !offeredExceptionWords.contains(key) else { return }
        offeredExceptionWords.insert(key)
        guard !SettingsManager.shared.deniedWordsSet.contains(key) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.learnQuestion(word)
        alert.addButton(withTitle: L10n.learnAdd)
        alert.addButton(withTitle: L10n.learnNotNow)
        if alert.runModal() == .alertFirstButtonReturn {
            var list = SettingsManager.shared.deniedWords
            list.append(word)
            SettingsManager.shared.deniedWords = list
            rslog("learn: added word (len=\(word.count)) to never-convert")
        }
    }

    private func recordAutoConversion(_ word: String, alternatives: [String] = []) {
        lastAutoConverted = (
            word: word,
            alternatives: Set(alternatives.map { $0.lowercased() }),
            at: Date()
        )
    }

    private func rejectLastAutoConversion() {
        guard let last = lastAutoConverted,
              Date().timeIntervalSince(last.at) < 12 else {
            lastAutoConverted = nil
            return
        }
        sessionCorrectionSuppression.remember(
            original: last.word,
            alternatives: last.alternatives
        )
        lastAutoConverted = nil
        rslog("auto: user rejected correction; one-shot override armed")
    }

    private func startPerAppLayout() {
        perAppLayoutManager.onLayoutRestored = { [weak self] in
            self?.keyboardMonitor.markConverted()
            self?.textConverter.clearState()
            self?.updateStatusIcon()
        }
        perAppLayoutManager.start()
    }

    // MARK: - Login Item Sync

    /// Синхронизирует состояние автозагрузки с системой при старте.
    /// Если галочка включена, но Login Item потерян (переустановка/обновление) — перерегистрирует.
    /// Если галочка выключена, но Login Item есть — снимает.
    private func syncLoginItem() {
        let settings = SettingsManager.shared
        let wanted = settings.launchAtLogin
        let status = settings.loginItemStatus

        rslog("Login item sync: wanted=\(wanted) status=\(status.rawValue)")

        if wanted && status != .enabled {
            // Галочка стоит, но Login Item не активен — перерегистрируем
            rslog("Re-registering login item...")
            settings.launchAtLogin = true  // setter вызовет doUpdateLoginItem
        } else if !wanted && status == .enabled {
            // Галочка снята, но Login Item активен — убираем
            rslog("Unregistering stale login item...")
            settings.launchAtLogin = false
        }
    }

    // MARK: - Permission Wizard

    private func runPermissionWizard(interactive: Bool = false) {
        let acc = AXIsProcessTrusted()
        let inp = CGPreflightListenEventAccess()
        rslog("Permissions: accessibility=\(acc) inputMonitoring=\(inp)")

        if acc && inp {
            // Запоминаем что разрешения были даны
            SettingsManager.shared.permissionsWereGranted = true
            if !monitoringActive { startMonitoring() }
            // Ручная проверка из меню должна давать видимый отклик.
            if interactive { showPermissionsOKAlert() }
            return
        }

        // Проверяем: разрешения были раньше, а теперь сброшены (обновление)
        if SettingsManager.shared.permissionsWereGranted {
            rslog("Permissions were previously granted — reset detected after update")
            SettingsManager.shared.permissionsWereGranted = false
            showPermissionsResetAlert()
            return
        }

        // Первый запуск — обычный визард
        if acc {
            showStep_InputMonitoring()
            return
        }

        showStep_Accessibility()
    }

    /// Подтверждение при ручной проверке, когда все разрешения уже выданы
    private func showPermissionsOKAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.permissionsOkTitle
        alert.informativeText = L10n.permissionsOkText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Уведомление о сбросе разрешений после обновления
    private func showPermissionsResetAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardPermissionsResetTitle
        alert.informativeText = L10n.wizardPermissionsResetText
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Ничего не удаляем из TCC автоматически. Системные разрешения принадлежат
        // пользователю; приложение лишь повторно открывает штатный запрос.
        showStep_Accessibility()
    }

    private func showStep_Accessibility() {
        guard confirmPermissionStep(
            title: L10n.wizardAccessibilityTitle,
            text: L10n.wizardAccessibilityText
        ) else {
            rslog("Accessibility request postponed by user")
            return
        }

        // AXIsProcessTrustedWithOptions с prompt=true показывает системный диалог
        // и добавляет программу в список Accessibility автоматически
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    rslog("Accessibility granted!")
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.showStep_InputMonitoring()
                }
            }
        }
    }

    private func showStep_InputMonitoring() {
        // CGRequestListenEventAccess() показывает системный диалог и добавляет
        // программу в список Input Monitoring автоматически
        let preflightOK = CGPreflightListenEventAccess()
        rslog("Preflight check = \(preflightOK)")

        if preflightOK {
            // Уже есть — сразу запускаем
            SettingsManager.shared.permissionsWereGranted = true
            startMonitoring()
            return
        }

        guard confirmPermissionStep(
            title: L10n.wizardInputMonitoringTitle,
            text: L10n.wizardInputMonitoringText
        ) else {
            rslog("Input Monitoring request postponed by user")
            return
        }

        rslog("Requesting access...")
        CGRequestListenEventAccess()

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CGPreflightListenEventAccess() {
                    rslog("Input Monitoring granted! Restarting...")
                    SettingsManager.shared.permissionsWereGranted = true
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.restartApp()
                }
            }
        }
    }

    /// LSUIElement-приложение не имеет обычного окна или Dock-иконки. Поэтому перед
    /// системным запросом явно объясняем следующий шаг и активируем приложение, иначе
    /// первый запуск выглядит как будто после открытия ничего не произошло.
    private func confirmPermissionStep(title: String, text: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L10n.wizardOpenSettings)
        alert.addButton(withTitle: L10n.wizardLater)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func restartApp() {
        rslog("Restarting from: \(Bundle.main.bundlePath)")
        AppRelauncher.relaunch()
    }

    // MARK: - Start Monitoring

    private func startMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil

        if !keyboardMonitor.start(
            onAltTap: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                // Приватность: в защищённом поле (пароль) ничего не делаем — ставим ДО
                // remote-defer, чтобы поведение точно совпадало с handleAutoConvert.
                guard !AutoSwitchPolicy.secureInputActive else { rslog("trigger: bail secure-input"); self.notifySecureInputPaused(); return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                // issue #16: в Spotlight обычный путь оставляет лишнюю букву (серое
                // автодополнение съедает Backspace). Особый путь: Cmd+A + буфер, без
                // Backspace. Гейт isActive() строгий (окно видимо + Spotlight держит поле),
                // поэтому здесь мы ТОЧНО в Spotlight — конвертим только своим путём и НЕ
                // проваливаемся в буфер/count-пути (они тут дают лишнюю букву), что бы
                // convertSpotlight ни вернул.
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                        self.lastAutoConverted = nil
                    }
                    return
                }
                // issue #24: режим «вся строка».
                if SettingsManager.shared.convertWholeLine {
                    let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    if AutoSwitchPolicy.isTerminalApp(frontID) {
                        // Терминал: нет OS-выделения → перепечатываем строку по буферу нажатий.
                        // НЕПУСТОЙ буфер (в т.ч. no-op на уже верной строке) завершаем ЗДЕСЬ и НЕ
                        // проваливаемся на последнее слово — иначе безусловный флип испортил бы
                        // верное слово, напр. «git log»→«git дщп» (скептик 3.2.0). На слово падаем
                        // только при ПУСТОМ/сброшенном буфере (пунктуация/Enter/сдвиг курсора).
                        if !self.keyboardMonitor.lineKeys.isEmpty {
                            if self.textConverter.convertLineBuffer(self.keyboardMonitor.lineKeys) {
                                self.keyboardMonitor.markConverted()
                                LayoutSwitcher.switchToOpposite()
                                self.updateStatusIcon()
                                self.lastAutoConverted = nil
                            }
                            return
                        }
                    } else {
                        // Обычные приложения: сами выделяем строку (Shift+Cmd+←) и конвертируем.
                        if self.textConverter.convertLine() {
                            self.keyboardMonitor.markConverted()
                            LayoutSwitcher.switchToOpposite()
                            self.updateStatusIcon()
                            self.lastAutoConverted = nil
                        }
                        return   // whole-line в обычной проге — всегда завершаем (не last-word)
                    }
                }
                let keys = self.keyboardMonitor.currentWordKeys
                let prevKeys = self.keyboardMonitor.prevWordKeys
                let bc = self.keyboardMonitor.boundaryCount
                let sourceKeys = keys.isEmpty ? prevKeys : keys
                var replacement: String?
                if let pair = DynamicKeyMapping.convertKeys(sourceKeys),
                   let languages = LayoutSwitcher.currentAndOppositeLanguage() {
                    let polished = self.polishWord(pair.converted, language: languages.opposite)
                    if polished != pair.converted { replacement = polished }
                }
                if self.textConverter.convert(
                    wordKeys: keys,
                    prevWordKeys: prevKeys,
                    boundaryCount: bc,
                    replacementOverride: replacement
                ) {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.lastAutoConverted = nil
                }
            },
            onAltReconvert: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                guard !AutoSwitchPolicy.secureInputActive else { rslog("reconvert: bail secure-input"); self.notifySecureInputPaused(); return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                // issue #16: в Spotlight реконверт — тот же путь (Cmd+A + буфер), он
                // реверсивен (конвертит текущее содержимое обратно). НЕ проваливаемся в
                // count-based reconvert() в Spotlight (skeptic: он вайпит буфер и селектит
                // по счётчику — ровно то, чего избегаем).
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                    }
                    return
                }
                if self.textConverter.reconvert() {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.offerExceptionAfterUndo()
                }
            }
        ) {
            rslog("Event tap failed - will retry in 5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startMonitoring()
            }
            return
        }

        monitoringActive = true
        keyboardMonitor.onWordBoundary = { [weak self] in
            self?.handleAutoConvert()
        }
        keyboardMonitor.onRejectLastConversion = { [weak self] in
            self?.rejectLastAutoConversion()
        }
        keyboardMonitor.onUserInput = { [weak self] in self?.caretIndicator?.userTyped() }  // issue #10
        // issue #14: хоткей чистого переключения раскладки (без конверсии). Буфер после
        // явной смены раскладки неактуален — тот же паттерн, что per-app restore и меню.
        keyboardMonitor.onSwitchHotkey = { [weak self] in
            guard let self, SettingsManager.shared.autoSwitchEnabled else { return }
            if AutoSwitchPolicy.shouldDeferToRemoteClient {
                // Удалёнка (фокус в клиенте Screen Sharing): переключаем только СВОЮ
                // раскладку, как defer-ветка триггера. markConverted/clearState тут лишние —
                // буфер наполняется через handleForwardedChar, а проброшенные модификаторы
                // сами переключат раскладку на контролируемой машине.
                LayoutSwitcher.switchToOpposite()
                self.updateStatusIcon()
                rslog("switch hotkey: local layout switched (remote client focused)")
                return
            }
            LayoutSwitcher.switchToOpposite()
            self.keyboardMonitor.markConverted()
            self.textConverter.clearState()
            self.updateStatusIcon()
        }
        keyboardMonitor.onToggleAutomatic = { [weak self] in
            guard let self else { return }
            SettingsManager.shared.autoConvert.toggle()
            self.settingsController.updateAutoConvertState(SettingsManager.shared.autoConvert)
            self.rebuildMenu()
            NSSound(named: SettingsManager.shared.autoConvert ? "Tink" : "Pop")?.play()
        }
        // issue #29: хоткей смены регистра последнего слова / выделения. Раскладку не трогает,
        // в защищённом поле — пас (приватность), как у триггера.
        keyboardMonitor.onCaseHotkey = { [weak self] in
            guard let self else { return }
            guard !AutoSwitchPolicy.secureInputActive else { rslog("case: bail secure-input"); self.notifySecureInputPaused(); return }
            // Скептик #29: те же гейты, что у onAltTap/onSwitchHotkey. Удалёнка — текст правит
            // контролируемый инстанс (у нас нет своей раскладки для флипа, регистр просто пропускаем).
            if AutoSwitchPolicy.shouldDeferToRemoteClient { rslog("case: bail remote-defer"); return }
            // Spotlight: count-путь оставил бы лишнюю букву (issue #16), а AX там флейкует — не трогаем.
            if SpotlightAX.isActive() { rslog("case: bail spotlight"); return }
            // issue #29: смена регистра зеркалит триггер конверсии — уважает «Convert whole line»
            // (запрос kobygold). Терминал → по буферу строки; обычное приложение → AX-выделение строки.
            if SettingsManager.shared.convertWholeLine {
                let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if AutoSwitchPolicy.isTerminalApp(frontID) {
                    if !self.keyboardMonitor.lineKeys.isEmpty {
                        if self.textConverter.changeCaseLineBuffer(self.keyboardMonitor.lineKeys) { self.textConverter.clearState() }
                        return   // непустой буфер строки — завершаем здесь (как onAltTap)
                    }
                    // пустой буфер → падаем на последнее слово ниже
                } else {
                    if self.textConverter.changeCaseLine() { self.textConverter.clearState() }
                    return   // обычное приложение, whole-line — всегда завершаем здесь
                }
            }
            // Скептик #29: НЕ markConverted() — буфер слова нужен, чтобы повторный тап циклил
            // регистр. Чистим reconvert-состояние, иначе следующий реконверт сработал бы по
            // устаревшим lastOriginal/lastConverted и испортил текст.
            let keys = self.keyboardMonitor.currentWordKeys
            if self.textConverter.changeCase(wordKeys: keys) {
                self.textConverter.clearState()
            }
        }
        updateStatusIcon()        // сначала выставляем флаг меню-бара, пока индикатора ещё нет
        syncCaretIndicator()      // затем создаём индикатор — без стартового ложного «попа»
        // Страховка к issue #9: системное уведомление о смене раскладки ненадёжно
        // (особенно через удалённый стол — на той машине оно часто не доходит), поэтому
        // флаг «застревает». Постоянный лёгкий опрос держит иконку в синхроне с системой.
        iconRefreshTimer?.invalidate()
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusIcon() }
        }
        rslog("Monitoring started successfully")

        if SettingsManager.shared.perAppLayout {
            startPerAppLayout()
        }

        // Предлагаем автозагрузку при первом запуске. Автокоррекция включена
        // по умолчанию и приостанавливается одновременным нажатием обоих Shift.
        offerLaunchAtLoginIfNeeded()
    }

    /// Авто-конвертация на границе слова: детект неправильной раскладки → конверт + смена.
    /// Точность-first: при любой неуверенности ничего не делаем. Ручной триггер не трогаем.
    private func handleAutoConvert() {
        rslog("auto: fired")
        guard SettingsManager.shared.autoSwitchEnabled else { rslog("auto: bail master-off"); return }
        guard SettingsManager.shared.autoConvert else { rslog("auto: bail flag-off"); return }
        guard !AutoSwitchPolicy.secureInputActive else { rslog("auto: bail secure-input"); return }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Удалёнка: НЕ выходим сразу — прогоняем детектор по своему (чистому) буферу, и при
        // «не той раскладке» переключаем СВОЮ раскладку (конверсию делает инстанс на той стороне).
        let deferToRemote = SettingsManager.shared.remoteDesktopMode && AutoSwitchPolicy.isRemoteDesktopClient(frontID)
        if AutoSwitchPolicy.isDeniedApp(frontID) { rslog("auto: bail denied-app \(frontID ?? "?")"); return }
        if let captured = keyboardMonitor.prevWordBundleID, captured != frontID {
            rslog("auto: bail focus-changed"); return  // фокус уехал между пробелом и сейчас
        }

        let allKeys = keyboardMonitor.prevWordKeys
        let bc = keyboardMonitor.boundaryCount
        guard !allKeys.isEmpty else { rslog("auto: bail empty-keys"); return }  // курсор уехал — небезопасно
        guard let fullPair = DynamicKeyMapping.convertKeys(allKeys) else { rslog("auto: bail convertKeys-nil"); return }
        if sessionCorrectionSuppression.consume(fullPair.original) {
            rslog("auto: bail one-shot-user-override")
            return
        }

        // Язык для детектора. Для проброшенного через удалёнку текста (все символы — char)
        // направление определяем по СКРИПТУ набранного, а не по раскладке офисной машины.
        let langs: (current: String, opposite: String)
        if allKeys.allSatisfy({ $0.char != nil }) {
            let typedIsCyrillic = fullPair.original.unicodeScalars.contains {
                $0.value >= 0x0400 && $0.value <= 0x04FF
            }
            langs = typedIsCyrillic ? ("ru", "en") : ("en", "ru")
        } else if let resolved = LayoutSwitcher.currentAndOppositeLanguage() {
            langs = resolved
        } else {
            rslog("auto: bail langs-nil"); return
        }

        // issue #15: слово с прилипшей пунктуацией ("ghbdtn,") — отщепляем хвост, детектим
        // и конвертим ядро, хвост вернётся в поле литералом. Проверка счёта — инвариант
        // «1 клавиша = 1 символ» обоих путей convertKeys; при слиянии графем не отщепляем.
        var keys = allKeys
        var suffix = ""
        let split = LayoutDetector.splitTrailingPunctuation(fullPair.original)
        let fullConvertedCurated = HighConfidenceLexicon.contains(
            fullPair.converted,
            language: langs.opposite
        )
        // The early spelling lookup is needed only to resolve a punctuation-key
        // ambiguity. Ordinary words stay on the cheap dictionary-decision path.
        let fullTargetCorrection = !split.suffix.isEmpty
            && !fullConvertedCurated
            && fullPair.converted.allSatisfy({ $0.isLetter })
            ? Dict.bestCorrection(fullPair.converted, lang: langs.opposite)
            : nil
        let keepFullToken = LayoutDetector.prefersWholeToken(
            typed: fullPair.original,
            converted: fullPair.converted,
            currentLang: langs.current,
            otherLang: langs.opposite,
            convertedHasSafeCorrection: fullTargetCorrection != nil
        )
        if !keepFullToken,
           !split.suffix.isEmpty, split.coreLength > 0,
           fullPair.original.count == allKeys.count {
            keys = Array(allKeys.prefix(split.coreLength))
            suffix = split.suffix
        }
        guard let pair = suffix.isEmpty ? fullPair : DynamicKeyMapping.convertKeys(keys) else {
            rslog("auto: bail convertKeys-nil"); return
        }
        if AutoSwitchPolicy.isDeniedWord(pair.original, pair.converted) { rslog("auto: bail denied-word"); return }

        // Same-language polish runs before layout detection. It only applies a
        // capitalization fix when the result is a known word and restores ё
        // only for an unambiguous dictionary form.
        let polishedOriginal = polishWord(pair.original, language: langs.current)
        if polishedOriginal != pair.original {
            guard !deferToRemote else {
                rslog("auto: polish deferred to remote instance")
                return
            }
            if SpotlightAX.isActive() {
                if suffix.isEmpty,
                   textConverter.convertSpotlightWord(converted: polishedOriginal, boundaryCount: bc) {
                    keyboardMonitor.markConverted()
                    recordAutoConversion(pair.original)
                }
                return
            }
            if textConverter.replace(
                wordKeys: [],
                prevWordKeys: keys,
                boundaryCount: bc,
                with: polishedOriginal,
                passthroughSuffix: suffix
            ) {
                keyboardMonitor.markConverted()
                recordAutoConversion(pair.original)
            }
            return
        }

        // Ревью-находка (#15): '.', ',', ';', ':' в EN — клавиши букв ю/б/ж/Ж в ЙЦУКЕН,
        // поэтому начало «хвоста» в целевой раскладке может оказаться буквами, а ядро +
        // эти буквы — словарным словом: «levf.» → «думаю», «levf.!» → «думаю!». Идём по
        // буквенному расширению ядра в полной конверсии и проверяем каждый префикс по
        // словарю: первое словарное расширение = неоднозначность («думаю» vs «дума.») →
        // точность важнее полноты, не делаем НИЧЕГО (ручной триггер конвертирует целиком).
        // Первая не-буква — стоп: дальше хвост пунктуация и в целевой раскладке,
        // двусмысленности нет. NSSpellChecker токенизирует («привет!» для него валиден),
        // поэтому проверять полную конверсию целиком нельзя — только буквенные префиксы.
        // Для пар с ивритом walk не нужен: направление «в иврит» авто-путём не конвертится
        // by design (см. иврит-ветку decide), а ивритский словарь принимает любые буквы —
        // walk дал бы бессмысленный bail на первом же шаге и мусорную строку в логе.
        if !suffix.isEmpty, !LayoutDetector.isHebrew(langs.opposite), Dict.isAvailable(langs.opposite) {
            let oth = String(langs.opposite.prefix(2))
            let fullConv = Array(fullPair.converted)
            var candidate = String(fullConv[..<split.coreLength])
            for ch in fullConv[split.coreLength...] {
                guard ch.isLetter else { break }
                candidate.append(ch)
                if Dict.isValidWord(candidate.lowercased(), lang: oth) {
                    rslog("auto: bail ambiguous-suffix")
                    return
                }
            }
        }

        let capsLock = keys.contains { $0.caps }
        let verdict = LayoutDetector.decide(typed: pair.original, converted: pair.converted,
                                            currentLang: langs.current, otherLang: langs.opposite,
                                            capsLock: capsLock)
        rslog("auto: len=\(pair.original.count) \(langs.current)/\(langs.opposite) verdict=\(verdict)")  // слова не логируем (приватность)
        guard verdict == .switchToConverted else {
            // Caramba-like path: the source is gibberish in the active language, while its
            // layout image is exactly one safe edit away from a target-language word.
            // This handles `gbne[` -> `питух` -> `петух`, including the `[`/`х`
            // punctuation-key ambiguity, without enabling broad fuzzy conversion.
            let targetSpelling = suffix.isEmpty
                ? (fullTargetCorrection ?? Dict.bestCorrection(pair.converted, lang: langs.opposite))
                : nil
            let sourceConfidence: Dict.Confidence = pair.original.allSatisfy({ $0.isLetter })
                ? Dict.confidence(pair.original.lowercased(), lang: langs.current)
                : .absent
            if let targetSpelling,
               sourceConfidence == .absent,
               !AutoSwitchPolicy.isDeniedWord(pair.original, targetSpelling),
               !deferToRemote {
                let polishedTarget = polishWord(targetSpelling, language: langs.opposite)
                if SpotlightAX.isActive() {
                    if textConverter.convertSpotlightWord(converted: polishedTarget, boundaryCount: bc) {
                        keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        updateStatusIcon()
                        recordAutoConversion(pair.original, alternatives: [pair.converted])
                    }
                    return
                }
                if textConverter.replace(
                    wordKeys: [],
                    prevWordKeys: keys,
                    boundaryCount: bc,
                    with: polishedTarget,
                    passthroughSuffix: ""
                ) {
                    keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    updateStatusIcon()
                    recordAutoConversion(pair.original, alternatives: [pair.converted])
                }
                return
            }

            guard let spelling = Dict.bestCorrection(pair.original, lang: langs.current),
                  !AutoSwitchPolicy.isDeniedWord(pair.original, spelling),
                  !deferToRemote else { return }
            let polishedSpelling = polishWord(spelling, language: langs.current)
            if SpotlightAX.isActive() {
                if suffix.isEmpty,
                   textConverter.convertSpotlightWord(converted: polishedSpelling, boundaryCount: bc) {
                    keyboardMonitor.markConverted()
                    recordAutoConversion(pair.original)
                }
                return
            }
            if textConverter.replace(
                wordKeys: [],
                prevWordKeys: keys,
                boundaryCount: bc,
                with: polishedSpelling,
                passthroughSuffix: suffix
            ) {
                keyboardMonitor.markConverted()
                recordAutoConversion(pair.original)
            }
            return
        }

        if deferToRemote {
            // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам.
            // Здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже в правильной.
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            rslog("auto: local layout switched, conversion handled by controlled instance")
            return
        }

        // issue #16 (авто): в Spotlight стирание по счётчику оставляет лишнюю букву (серое
        // автодополнение ест Backspace). Решение по буферу уже принято верно — меняем только
        // способ замены: по-словное выделение (Shift+Option+Left) + печать поверх, без
        // Backspace. Суффикс-случай (#15) в Spotlight редок и фиддловат — его не трогаем.
        let polishedConverted = polishWord(pair.converted, language: langs.opposite)
        if SpotlightAX.isActive() {
            if suffix.isEmpty,
               textConverter.convertSpotlightWord(converted: polishedConverted, boundaryCount: bc) {
                keyboardMonitor.markConverted()
                LayoutSwitcher.switchToOpposite()
                updateStatusIcon()
                recordAutoConversion(pair.original, alternatives: [pair.converted])
            }
            return   // Spotlight: обычный count-путь неприменим
        }

        rslog("auto: convert \(keys.count) keys (+\(suffix.count) punct, +\(bc) sp)")
        if textConverter.convert(wordKeys: [], prevWordKeys: keys, boundaryCount: bc,
                                 passthroughSuffix: suffix,
                                 replacementOverride: polishedConverted) {
            keyboardMonitor.markConverted()
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            recordAutoConversion(pair.original, alternatives: [pair.converted])
        }
    }

    /// Applies only high-confidence corrections. This is deliberately not a
    /// generic spellcheck autocorrect: a wrong replacement is worse than a miss.
    private func polishWord(_ word: String, language: String) -> String {
        var result = word
        if let capitalization = CapitalizationFixer.accidentalSecondCapital(in: result),
           Dict.isValidWord(capitalization.lowercased(), lang: language) {
            result = capitalization
        }

        guard language.lowercased().hasPrefix("ru") else { return result }
        if case let .restored(restored) = yoRestorer?.restore(result) {
            result = restored
        }
        return result
    }

    /// Предлагает включить автозагрузку при первом запуске (один раз)
    private func offerLaunchAtLoginIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.launchAtLoginAsked else { return }
        settings.launchAtLoginAsked = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardLaunchAtLoginTitle
        alert.informativeText = L10n.wizardLaunchAtLoginText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            settings.launchAtLogin = true
            rslog("User enabled launch at login")
        } else {
            rslog("User declined launch at login")
        }
    }

    /// Предлагает включить автозамену при первом запуске (один раз). Фича OFF по умолчанию,
    /// поэтому без явного предложения пользователь о ней не узнает.
    private func offerAutoConvertIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.autoConvertOffered else { return }
        settings.autoConvertOffered = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.onboardAutoConvertTitle
        alert.informativeText = L10n.onboardAutoConvertText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        if alert.runModal() == .alertFirstButtonReturn {
            settings.autoConvert = true
            rebuildMenu()  // синхронизировать галочку «Автоматическая конверсия» в меню
            rslog("User enabled auto-convert at onboarding")
        } else {
            rslog("User declined auto-convert at onboarding")
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        // issue #9: иконка должна отражать раскладку и при СИСТЕМНОЙ смене (стандартный/
        // переопределённый хоткей), а не только при нашей конверсии. Слушаем системное
        // распределённое уведомление о смене источника ввода.
        // suspensionBehavior: .deliverImmediately — иначе для фонового menu-bar-приложения
        // распределённое уведомление коалесцируется/откладывается (App Nap / suspend), и
        // иконка после переключения глобусом 🌐 меняется с задержкой до нескольких секунд
        // (ждёт пробуждения или 2-секундного опроса). deliverImmediately обновляет флаг сразу.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemInputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func systemInputSourceChanged() {
        updateStatusIcon()
        keyboardMonitor.soundArmed = true  // issue #7: следующая буква даст звук раскладки
        keyboardMonitor.resetLineBuffer()  // скептик 3.2.0: не декодировать строку старой раскладкой
    }

    /// Собирает меню статус-бара. Вызывается заново при смене языка интерфейса,
    /// иначе пункты меню остаются на старом языке.
    private func rebuildMenu() {
        let menu = NSMenu()

        // Строка версии (с dev-меткой для непубликуемых сборок) — чтобы было видно, какой билд.
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let devTag = Bundle.main.infoDictionary?["RSDevTag"] as? String ?? ""
        let verItem = NSMenuItem(title: "TypeFlow \(ver)\(devTag)", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)
        menu.addItem(NSMenuItem.separator())

        // Список раскладок как в системном меню ввода: флаг + имя, галочка на текущей,
        // клик — переключение. Актуализируется в menuWillOpen при каждом открытии.
        for item in layoutMenuItems() { menu.addItem(item) }
        menu.addItem(NSMenuItem.separator())

        let autoItem = NSMenuItem(title: L10n.menuAutoSwitch, action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = SettingsManager.shared.autoSwitchEnabled ? .on : .off
        menu.addItem(autoItem)

        let autoConvertItem = NSMenuItem(title: L10n.menuAutoConvert, action: #selector(toggleAutoConvert), keyEquivalent: "")
        autoConvertItem.target = self
        autoConvertItem.state = SettingsManager.shared.autoConvert ? .on : .off
        menu.addItem(autoConvertItem)

        let keySoundItem = NSMenuItem(title: L10n.menuKeySound, action: #selector(toggleKeySound), keyEquivalent: "")
        keySoundItem.target = self
        keySoundItem.state = SettingsManager.shared.keySound ? .on : .off
        menu.addItem(keySoundItem)

        let caretFlagItem = NSMenuItem(title: L10n.menuCaretFlag, action: #selector(toggleCaretFlag), keyEquivalent: "")
        caretFlagItem.target = self
        caretFlagItem.state = SettingsManager.shared.caretFlag ? .on : .off
        menu.addItem(caretFlagItem)

        // Единый стиль меню-бара (Sequoia): монохромная плашка вместо цветного флага.
        let monoIconItem = NSMenuItem(title: L10n.menuMonoIcon, action: #selector(toggleMonoIcon), keyEquivalent: "")
        monoIconItem.target = self
        monoIconItem.state = SettingsManager.shared.monochromeIcon ? .on : .off
        menu.addItem(monoIconItem)

        // Режим удалённого стола отложен в 2.5 — тумблер скрыт за флагом (для тестирования).
        if SettingsManager.shared.showRemoteDesktopBeta {
            let remoteDesktopItem = NSMenuItem(title: L10n.menuRemoteDesktop, action: #selector(toggleRemoteDesktop), keyEquivalent: "")
            remoteDesktopItem.target = self
            remoteDesktopItem.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
            menu.addItem(remoteDesktopItem)
        }

        menu.addItem(NSMenuItem.separator())

        let permItem = NSMenuItem(title: L10n.menuCheckPermissions, action: #selector(recheckPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        let settingsItem = NSMenuItem(title: L10n.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: L10n.menuCheckUpdates, action: #selector(checkUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let donateItem = NSMenuItem(title: L10n.menuDonate, action: #selector(openDonate), keyEquivalent: "")
        donateItem.target = self
        donateItem.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        menu.addItem(donateItem)

        let starItem = NSMenuItem(title: L10n.menuStarOnGithub, action: #selector(openGitHub), keyEquivalent: "")
        starItem.target = self
        starItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        menu.addItem(starItem)

        let shareItem = NSMenuItem(title: L10n.menuShare, action: nil, keyEquivalent: "")
        shareItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        shareItem.submenu = buildShareSubmenu()
        menu.addItem(shareItem)

        let contactItem = NSMenuItem(title: L10n.menuContactDeveloper, action: #selector(openContactEmail), keyEquivalent: "")
        contactItem.target = self
        contactItem.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil)
        menu.addItem(contactItem)

        if !SettingsManager.telegramChatURL.isEmpty {
            let tgItem = NSMenuItem(title: L10n.menuTelegramSupport, action: #selector(openTelegramSupport), keyEquivalent: "")
            tgItem.target = self
            tgItem.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: nil)
            menu.addItem(tgItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        rslog("Menu (re)built with \(menu.items.count) items")
    }

    // MARK: - Layout list in menu

    /// Метка пунктов-раскладок, чтобы находить и обновлять их группу в меню.
    private static let layoutItemTag = 741

    /// Пункты списка раскладок: «флаг + локализованное имя», галочка на текущей.
    private func layoutMenuItems() -> [NSMenuItem] {
        let currentID = LayoutSwitcher.currentLayoutID()
        return LayoutSwitcher.installedLayouts().map { source in
            let id = LayoutSwitcher.sourceID(source)
            let badge = LayoutSwitcher.languageCode(source).map(Self.flagBadge(forLanguage:))
            let title = [badge, LayoutSwitcher.sourceName(source)].compactMap { $0 }.joined(separator: " ")
            let item = NSMenuItem(title: title, action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (id == currentID) ? .on : .off
            item.tag = Self.layoutItemTag
            return item
        }
    }

    /// Пересобирает группу раскладок при каждом открытии меню: состав и галочка должны
    /// отражать систему на момент клика (раскладки добавляют/удаляют в настройках ОС,
    /// а текущую меняют и мимо нас — системным хоткеем).
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        let insertAt = menu.items.firstIndex { $0.tag == Self.layoutItemTag } ?? 2
        for old in menu.items where old.tag == Self.layoutItemTag { menu.removeItem(old) }
        for (offset, item) in layoutMenuItems().enumerated() {
            menu.insertItem(item, at: insertAt + offset)
        }
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id != LayoutSwitcher.currentLayoutID() else { return }
        LayoutSwitcher.switchTo(layoutID: id)
        // Явная смена раскладки делает набранный буфер неактуальным — как при per-app restore.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        updateStatusIcon()
    }

    func updateStatusIcon() {
        let flag = flagForCurrentLayout()
        // Каретку дёргаем ТОЛЬКО при реальной смене раскладки: updateStatusIcon зовётся ещё и
        // 2-секундным опросом-страховкой, иначе флаг у каретки выскакивал бы каждые 2с.
        // Сравниваем по флагу-идентичности, а не по title — в монохромном режиме title пуст.
        let changed = lastFlagShown != flag
        lastFlagShown = flag
        if SettingsManager.shared.monochromeIcon {
            statusItem.button?.title = ""
            statusItem.button?.image = badgeImage(for: currentBadgeLabel())
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = flag
        }
        if changed { caretIndicator?.layoutChanged() }
    }

    /// Подпись монохромной плашки — родная аббревиатура языка, как у системного индикатора.
    private func currentBadgeLabel() -> String {
        if let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty {
            // 'iw' — устаревший код иврита: нормализуем, как и flagBadge.
            let code = LayoutDetector.isHebrew(lang) ? "he" : String(lang.prefix(2))
            let labels: [String: String] = [
                "ru": "РУ", "en": "EN", "uk": "УК", "be": "БЕ",
                "de": "DE", "fr": "FR", "es": "ES", "it": "IT",
                "pt": "PT", "pl": "PL", "ja": "あ", "zh": "拼", "ko": "한",
                "he": "עב",   // иврит (3.0)
                "el": "ΕΛ", "bg": "БГ", "hy": "ՀԱ", "ka": "ქა",
            ]
            return labels[code] ?? code.uppercased()
        }
        // Язык раскладки недоступен — мягкий фолбэк по ID (как у flagForCurrentLayout).
        let id = LayoutSwitcher.currentLayoutID().lowercased()
        return (id.contains("russian") || id.hasSuffix(".ru")) ? "РУ" : "EN"
    }

    /// Монохромная плашка в стиле системного индикатора раскладки Sequoia: скруглённый
    /// прямоугольник с «выбитыми» буквами. Template-image — система сама красит её под
    /// светлый/тёмный меню-бар и пользовательский тинт.
    private func badgeImage(for label: String) -> NSImage {
        if let cached = badgeCache[label] { return cached }
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let textSize = label.size(withAttributes: [.font: font])
        let size = NSSize(width: max(ceil(textSize.width) + 8, 20), height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            // Буквы «выбиваются» из плашки (прозрачные), как у системного индикатора.
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                   y: (rect.height - textSize.height) / 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
            return true
        }
        image.isTemplate = true
        badgeCache[label] = image
        return image
    }

    /// Флаг текущей раскладки по коду языка (BCP-47), а не по подстроке в ID — иначе
    /// "Belarusian" ложно матчил "ru", а любая не-RU/EN пара показывалась как 🇺🇸.
    func flagForCurrentLayout() -> String {
        guard let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty else {
            // Язык раскладки недоступен — мягкий фолбэк по ID.
            let id = LayoutSwitcher.currentLayoutID().lowercased()
            return (id.contains("russian") || id.hasSuffix(".ru")) ? "🇷🇺" : "🇺🇸"
        }
        return Self.flagBadge(forLanguage: lang)
    }

    /// Единый бейдж раскладки для иконки меню-бара и списка раскладок в меню:
    /// «🇷🇺» для известных языков, иначе код («EL»).
    private static func flagBadge(forLanguage lang: String) -> String {
        // Иврит может прийти устаревшим кодом 'iw' — движок его понимает (isHebrew),
        // индикация должна тоже, иначе в баре будет «IW» вместо 🇮🇱.
        let code = LayoutDetector.isHebrew(lang) ? "he" : String(lang.lowercased().prefix(2))
        let flags: [String: String] = [
            "ru": "🇷🇺", "en": "🇺🇸", "uk": "🇺🇦", "be": "🇧🇾",
            "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹",
            "pt": "🇵🇹", "pl": "🇵🇱", "ja": "🇯🇵", "zh": "🇨🇳", "ko": "🇰🇷",
            "he": "🇮🇱",   // иврит (3.0). Арабский в 3.1 — глифом ع (флага нет), см. дизайн 3.0.
        ]
        return flags[code] ?? code.uppercased()
    }

    /// issue #10: создаёт/освобождает индикатор каретки по флагу настроек. Создаётся лениво,
    /// только когда фича включена И мониторинг запущен (нужны разрешения).
    private func syncCaretIndicator() {
        keyboardMonitor.caretFlagEnabled = SettingsManager.shared.caretFlag   // гейт диспатча onUserInput
        if SettingsManager.shared.caretFlag, monitoringActive {
            if caretIndicator == nil {
                let ci = CaretIndicator()
                ci.flagProvider = { [weak self] in self?.flagForCurrentLayout() ?? "" }
                caretIndicator = ci
            }
        } else {
            caretIndicator?.teardown()
            caretIndicator = nil
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        SettingsManager.shared.autoSwitchEnabled.toggle()
        let enabled = SettingsManager.shared.autoSwitchEnabled
        sender.state = enabled ? .on : .off
        settingsController.updateAutoSwitchState(enabled)
    }

    @objc private func toggleAutoConvert(_ sender: NSMenuItem) {
        SettingsManager.shared.autoConvert.toggle()
        sender.state = SettingsManager.shared.autoConvert ? .on : .off
        settingsController.updateAutoConvertState(SettingsManager.shared.autoConvert)   // #4
    }

    @objc private func toggleKeySound(_ sender: NSMenuItem) {
        SettingsManager.shared.keySound.toggle()
        sender.state = SettingsManager.shared.keySound ? .on : .off
    }

    @objc private func toggleCaretFlag(_ sender: NSMenuItem) {
        SettingsManager.shared.caretFlag.toggle()
        sender.state = SettingsManager.shared.caretFlag ? .on : .off
        settingsController.updateCaretFlagState(SettingsManager.shared.caretFlag)
        syncCaretIndicator()   // создать/снести индикатор и обновить гейт onUserInput
    }

    @objc private func toggleMonoIcon(_ sender: NSMenuItem) {
        SettingsManager.shared.monochromeIcon.toggle()
        sender.state = SettingsManager.shared.monochromeIcon ? .on : .off
        updateStatusIcon()   // перерисовать в новом стиле сразу
    }

    @objc private func toggleRemoteDesktop(_ sender: NSMenuItem) {
        SettingsManager.shared.remoteDesktopMode.toggle()
        sender.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
        settingsController.updateRemoteDesktopState(SettingsManager.shared.remoteDesktopMode)   // #5
        reconfigureTap()  // уровень event tap зависит от режима
    }

    /// Пересоздаёт event tap и, если создание не удалось (например, session-tap отклонён),
    /// ретраит — иначе тумблер «вкл», а tap'а нет, и приложение молча не реагирует на триггер.
    private func reconfigureTap() {
        guard !keyboardMonitor.reconfigure() else { return }
        rslog("reconfigure failed (tap denied) — retry in 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.keyboardMonitor.reconfigure() == false { rslog("reconfigure retry failed") }
        }
    }

    @objc private func recheckPermissions() {
        runPermissionWizard(interactive: true)
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func checkUpdates() {
        UpdateChecker.checkNow()
    }

    @objc private func openDonate() {
        if let url = URL(string: SettingsManager.supportURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: SettingsManager.starURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Окно «Что нового» — один раз после обновления, на языке приложения.
    /// НЕ показываем на свежей установке (там визард первого запуска): отличаем по
    /// launchAtLoginAsked — он выставляется на первом запуске, значит приложение уже
    /// работало ⇒ пустой lastWhatsNewVersion при hasRunBefore = обновление со старой версии.
    private func showWhatsNewIfNeeded(hasRunBefore: Bool) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard !current.isEmpty else { return }
        // Бета-версии (с буквой, напр. «3.2.0a») имеют ОТДЕЛЬНУЮ витрину
        // (showBetaWhatsNewIfNeeded) с текстом из бета-фида; локализованный whatsnew.body
        // под беты не обновляется (иначе тестер увидел бы устаревший текст).
        guard current.last?.isLetter != true else { return }
        let settings = SettingsManager.shared
        // Показываем только на РЕАЛЬНОМ повышении версии: current строго новее сохранённой
        // (numeric-сравнение, не строковое) — иначе даунгрейд 3.2→3.1 снова показал бы окно.
        guard current.compare(settings.lastWhatsNewVersion, options: .numeric) == .orderedDescending else { return }
        guard hasRunBefore else {                          // свежая установка: не показываем,
            settings.lastWhatsNewVersion = current         // но фиксируем версию (и на 2-м запуске молчим)
            return
        }
        // После обновления macOS мог сбросить права — идёт визард, мониторинг ещё не поднят.
        // Не наваливаем промо поверх запроса прав: откладываем до следующего запуска,
        // версию НЕ фиксируем (покажем, когда права выданы и мониторинг активен).
        guard monitoringActive else { return }
        settings.lastWhatsNewVersion = current             // фиксируем только когда реально показываем

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(L10n.whatsNewTitle) \(current)"
        alert.informativeText = L10n.whatsNewBody
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.whatsNewMore)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "\(SettingsManager.githubURL)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Отдельная витрина для БЕТ: текст изменений берётся из notes бета-фида
    /// (version-beta.json), а не из локализованного whatsnew.body — так его можно менять под
    /// каждую бету без пересборки и ×16-локализации. Только для подписчиков беты, один раз на
    /// версию. Текст двуязычный (RU+EN) — аудитория беты небольшая и приглашённая.
    private func showBetaWhatsNewIfNeeded() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard current.last?.isLetter == true else { return }         // только беты
        guard SettingsManager.shared.betaChannelEnabled else { return }  // только подписчики беты
        guard SettingsManager.shared.lastBetaNotesShown != current else { return }
        guard monitoringActive else { return }                        // не поверх запроса прав
        Task { @MainActor in
            guard let notes = await UpdateChecker.fetchBetaNotes(), !notes.isEmpty else { return }
            // перепроверяем после await (мог показаться параллельно / версия изменилась)
            guard SettingsManager.shared.lastBetaNotesShown != current else { return }
            SettingsManager.shared.lastBetaNotesShown = current
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "\(L10n.whatsNewTitle) \(current) \(L10n.updateBeta)"
            alert.informativeText = notes
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: L10n.whatsNewMore)
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "\(SettingsManager.githubURL)/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Подменю «Поделиться» — прямые share-intent ссылки на площадки, актуальные для
    /// аудитории (Telegram/VK — главные для RU), + копирование. Нативный NSSharingServicePicker
    /// на macOS для этого слаб (нет соцсетей/мессенджеров), поэтому свои web-intent'ы.
    private func buildShareSubmenu() -> NSMenu {
        let link = SettingsManager.githubURL
        let text = L10n.shareMessage
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: L10n.menuShareCopy, action: #selector(copyShareLink), keyEquivalent: "")
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyItem)
        menu.addItem(NSMenuItem.separator())

        // (заголовок, icon-slug, base, параметры). icon: ключ ShareIcons или "sf:<symbol>".
        let targets: [(String, String, String, [(String, String)])] = [
            ("Telegram", "telegram", "https://t.me/share/url",                 [("url", link), ("text", text)]),
            ("VK",       "vk",       "https://vk.com/share.php",                [("url", link), ("title", text)]),
            ("X",        "x",        "https://twitter.com/intent/tweet",        [("text", text), ("url", link)]),
            ("WhatsApp", "whatsapp", "https://wa.me/",                          [("text", "\(text) \(link)")]),
            ("Facebook", "facebook", "https://www.facebook.com/sharer/sharer.php", [("u", link)]),
            ("Reddit",   "reddit",   "https://www.reddit.com/submit",           [("url", link), ("title", text)]),
            (L10n.menuShareEmail, "sf:envelope", "mailto:",                     [("subject", "TypeFlow"), ("body", "\(text) \(link)")]),
        ]
        for (title, icon, base, params) in targets {
            guard let shareURL = Self.buildQueryURL(base, params) else { continue }
            let item = NSMenuItem(title: title, action: #selector(openShareLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shareURL
            if icon.hasPrefix("sf:") {
                item.image = NSImage(systemSymbolName: String(icon.dropFirst(3)), accessibilityDescription: nil)
            } else {
                item.image = ShareIcons.image(icon)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// Собирает URL с корректно закодированными query-параметрами (в т.ч. mailto).
    private static func buildQueryURL(_ base: String, _ params: [(String, String)]) -> String? {
        var comps = URLComponents(string: base)
        comps?.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents кодирует пробел как %20 (не '+'), а литеральный '+' в значении
        // оставляет как есть — но многие сервисы трактуют '+' как пробел. Поэтому
        // однозначно кодируем именно '+' → %2B (пробелы уже %20, их не трогаем).
        return comps?.url?.absoluteString.replacingOccurrences(of: "+", with: "%2B")
    }

    /// «Связаться с разработчиком»: открывает почту с предзаполненными темой и телом
    /// (версия + macOS + активные раскладки — для полезного баг-репорта). Пока адрес не задан
    /// (SettingsManager.contactEmail пуст) — фолбэк на GitHub Issues, чтобы кнопка не была мёртвой.
    @objc private func openContactEmail() {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard !SettingsManager.contactEmail.isEmpty else {
            if let url = URL(string: SettingsManager.contactURL) { NSWorkspace.shared.open(url) }
            return
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let layouts = LayoutSwitcher.currentAndOppositeLanguage().map { "\($0.current)/\($0.opposite)" } ?? "?"
        let subject = "TypeFlow \(ver) — \(L10n.contactSubject)"
        let body = "\n\n\n———\nTypeFlow \(ver)\nmacOS \(os)\nLayouts: \(layouts)"
        if let s = Self.buildQueryURL("mailto:\(SettingsManager.contactEmail)",
                                      [("subject", subject), ("body", body)]),
           let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openTelegramSupport() {
        if let url = URL(string: SettingsManager.telegramChatURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func openShareLink(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyShareLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(L10n.shareMessage) \(SettingsManager.githubURL)", forType: .string)
    }

    func applicationWillTerminate(_ notification: Notification) {
        passwordLayoutGuard.stop()
        // Не теряем буфер обмена в 2-секундном окне отложенного восстановления
        // (актуально и при само-обновлении, которое завершает процесс).
        textConverter.flushPendingClipboardRestore()
    }

    @objc private func quit() {
        textConverter.flushPendingClipboardRestore()
        perAppLayoutManager.stop()
        keyboardMonitor.stop()
        NSApplication.shared.terminate(nil)
    }
}
