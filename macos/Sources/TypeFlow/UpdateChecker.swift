import AppKit
import Foundation

/// Проверяет наличие обновлений через GitHub
@MainActor
enum UpdateChecker {
    // URL к JSON с информацией о версии (стабильный фид).
    private static let versionURL = "https://raw.githubusercontent.com/Marko123333/TypeFlow/main/version.json"
    // Фид пред-релизов (бет). Читается ТОЛЬКО если включён бета-канал в настройках.
    // Может отсутствовать (404) — тогда бета-клиент просто остаётся на стабильном фиде.
    private static let betaVersionURL = "https://raw.githubusercontent.com/Marko123333/TypeFlow/main/version-beta.json"

    private enum FeedResult {
        case success(UpdateManifest)
        case unavailable
        case untrusted
    }

    private enum FeedChannel {
        case stable
        case beta
    }

    private static var checkInProgress = false
    private static let maximumManifestBytes = 64 * 1024
    private static let maximumSignatureBytes = 8 * 1024

    /// Проверить при запуске (с задержкой 5 сек, не чаще раза в сутки).
    /// Отключается через настройку `checkUpdatesEnabled`. Ручная проверка (`checkNow`) работает всегда.
    static func checkOnLaunch() {
        guard shouldAutoCheck() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Task {
                guard shouldAutoCheck(), !checkInProgress else { return }
                checkInProgress = true
                await check(silent: true)
                checkInProgress = false
            }
        }
    }

    /// Периодическая тихая авто-проверка, пока приложение работает (из таймера AppDelegate).
    /// Тот же троттл (не чаще раза в сутки) и та же настройка `checkUpdatesEnabled`, что и на старте,
    /// поэтому долго-живущий инстанс тоже ловит новые версии, а не только при перезапуске.
    static func checkPeriodic() {
        guard shouldAutoCheck(), !checkInProgress else { return }
        checkInProgress = true
        Task {
            await check(silent: true)
            checkInProgress = false
        }
    }

    /// Можно ли сейчас авто-проверять: включено в настройках И прошло ≥24ч с последней проверки.
    private static func shouldAutoCheck() -> Bool {
        let settings = SettingsManager.shared
        guard settings.checkUpdatesEnabled else { return false }
        if let lastCheck = settings.lastUpdateCheck,
           Date().timeIntervalSince(lastCheck) < 86400 {
            return false // Проверяли менее суток назад
        }
        return true
    }

    /// Проверить вручную (всегда показывает результат)
    static func checkNow(completion: (() -> Void)? = nil) {
        guard !checkInProgress else {
            completion?()
            return
        }
        checkInProgress = true
        Task {
            await check(silent: false)
            checkInProgress = false
            completion?()
        }
    }

    private static func check(silent: Bool) async {
        let result = await fetchApplicableInfo()
        guard case let .success(info) = result else {
            rslog("UpdateChecker: stable feed unreachable")
            if !silent {
                switch result {
                case .untrusted: await showIntegrityErrorAlert()
                case .unavailable: await showErrorAlert()
                case .success: break
                }
            }
            return
        }

        SettingsManager.shared.lastUpdateCheck = Date()

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        if UpdateVersion.isNewer(info.version, than: currentVersion) {
            if SettingsManager.shared.skippedVersion == info.version && silent {
                return // Пользователь пропустил эту версию
            }
            guard info.sha256 != nil else {
                rslog("UpdateChecker: newer manifest has no release sha256")
                if !silent { await showIntegrityErrorAlert() }
                return
            }
            await showUpdateAlert(info: info)
        } else if !silent {
            await showUpToDateAlert()
        }
    }

    /// Выбирает применимый фид. Стабильный — всегда. Если включён бета-канал, дополнительно
    /// читает фид пред-релизов и возвращает более СВЕЖУЮ из двух версий (по semver). Так
    /// бета-тестер получает беты, но автоматически «сходит» на финальный стабильный релиз,
    /// когда тот обгонит бету. Отсутствие/ошибка бета-фида не мешает стабильному.
    private static func fetchApplicableInfo() async -> FeedResult {
        let stableResult = await fetchInfo(from: versionURL, channel: .stable)
        guard case let .success(stable) = stableResult else { return stableResult }
        guard SettingsManager.shared.betaChannelEnabled else { return .success(stable) }
        guard case let .success(beta) = await fetchInfo(from: betaVersionURL, channel: .beta) else {
            return .success(stable)
        }
        return .success(UpdateVersion.isNewer(beta.version, than: stable.version) ? beta : stable)
    }

    /// Текст изменений текущей беты (поле notes бета-фида) — для отдельной «витрины беты».
    /// nil, если бета-фид недоступен или без notes.
    static func fetchBetaNotes() async -> String? {
        guard case let .success(info) = await fetchInfo(from: betaVersionURL, channel: .beta) else { return nil }
        return info.notes
    }

    /// Загружает JSON и его detached-подпись. Даже полный контроль над GitHub-репозиторием
    /// не позволяет выпустить обновление без приватного ключа LocalSwitcher.
    private static func fetchInfo(from urlString: String, channel: FeedChannel) async -> FeedResult {
        guard let url = URL(string: urlString),
              let signatureURL = URL(string: urlString + ".sig")
        else { return .untrusted }

        async let manifestResponse = fetchData(from: url, maximumBytes: maximumManifestBytes)
        async let signatureResponse = fetchData(from: signatureURL, maximumBytes: maximumSignatureBytes)
        guard let manifestData = await manifestResponse else { return .unavailable }
        // Доступный JSON без подписи — это не «проблема сети», а небезопасный канал.
        guard let signatureData = await signatureResponse else { return .untrusted }

        guard let manifest = UpdateManifestVerifier.verify(
            manifestData: manifestData,
            signatureData: signatureData
        ) else {
            rslog("UpdateChecker: rejected unsigned or invalid manifest \(urlString)")
            return .untrusted
        }
        guard acceptMonotonicFeedVersion(manifest.version, channel: channel) else {
            rslog("UpdateChecker: rejected signed feed rollback to \(manifest.version)")
            return .untrusted
        }
        return .success(manifest)
    }

    /// A detached signature proves authenticity, but an attacker controlling the
    /// hosting path could replay an older signed file. Remember the highest version
    /// seen for each channel so a client cannot be rolled back after observing a
    /// newer feed. First-contact freshness still relies on HTTPS/GitHub availability.
    private static func acceptMonotonicFeedVersion(
        _ version: String,
        channel: FeedChannel
    ) -> Bool {
        let settings = SettingsManager.shared
        let previous: String
        switch channel {
        case .stable: previous = settings.highestStableUpdateVersion
        case .beta: previous = settings.highestBetaUpdateVersion
        }

        if !previous.isEmpty, UpdateVersion.isNewer(previous, than: version) {
            return false
        }
        if previous.isEmpty || UpdateVersion.isNewer(version, than: previous) {
            switch channel {
            case .stable: settings.highestStableUpdateVersion = version
            case .beta: settings.highestBetaUpdateVersion = version
            }
        }
        return true
    }

    private static func fetchData(from url: URL, maximumBytes: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let workDirectory = makePrivateTemporaryDirectory() else { return nil }
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let destination = workDirectory.appendingPathComponent("response", isDirectory: false)
        do {
            let downloader = BoundedDownloader(maximumBytes: Int64(maximumBytes))
            let response = try await downloader.download(
                for: request,
                to: destination
            )
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200
            else { return nil }
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maximumBytes else { return nil }
            let data = try Data(contentsOf: destination, options: .mappedIfSafe)
            return data
        } catch {
            rslog("UpdateChecker fetch \(url.absoluteString): \(error)")
            return nil
        }
    }

    private static func showUpdateAlert(info: UpdateManifest) async {
        let isBeta = info.version.last?.isLetter ?? false   // «3.2.0a» — пред-релиз
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.updateAvailable + (isBeta ? " " + L10n.updateBeta : "")
        alert.informativeText = "\(L10n.updateNewVersion) \(info.version)\n\(info.notes ?? "")"
        alert.addButton(withTitle: L10n.updateInstallRestart)  // 1st
        alert.addButton(withTitle: L10n.updateDownload)         // 2nd
        alert.addButton(withTitle: L10n.updateSkip)             // 3rd
        alert.addButton(withTitle: L10n.updateLater)            // 4th

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            await installAndRestart(info: info)
        case .alertSecondButtonReturn:
            if let url = URL(string: "\(SettingsManager.githubURL)/releases/tag/v\(info.version)") {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            SettingsManager.shared.skippedVersion = info.version
        default:
            break
        }
    }

    // MARK: - Install & Restart

    private static func installAndRestart(info: UpdateManifest) async {
        let version = info.version

        // 0. Версия приходит из сети — не доверяем вслепую (попадёт в URL и в сравнение).
        //    Разрешаем необязательную одну строчную букву-суффикс для бет: «3.2.0a».
        //    Класс [0-9.a-z] исключает slash/пробел/метасимволы — безопасно для URL/тега.
        guard UpdateVersion.isValid(version) else {
            rslog("Update: rejected malformed version '\(version)'")
            // Семантически это недоверие данным фида, а не «повреждённый файл»:
            // на этом этапе ничего ещё не скачивалось.
            await showInstallError(L10n.updateIntegrityFailed)
            return
        }

        // 0a. Хэш обязателен даже при подписанном манифесте: он привязывает подпись
        //     к точным байтам DMG и обнаруживает повреждение загрузки до монтирования.
        guard let expectedSHA = info.sha256?.lowercased() else {
            rslog("Update: signed manifest has no sha256")
            await showInstallError(L10n.updateIntegrityFailed)
            return
        }

        guard let dmgURL = URL(string: SettingsManager.releaseDMGURL(version: version)) else {
            await showInstallError(L10n.updateDownloadFailed)
            return
        }

        let progress = UpdateProgressWindow(version: version)
        progress.show()
        defer { progress.close() }

        let fm = FileManager.default
        guard let workDirectory = makePrivateTemporaryDirectory() else {
            await showInstallError(L10n.updateInstallFailed)
            return
        }
        defer { try? fm.removeItem(at: workDirectory) }
        let tmpURL = workDirectory.appendingPathComponent("update.dmg", isDirectory: false)
        let tmpPath = tmpURL.path

        // 1. Скачать потоково во временный файл URLSession, а не держать весь DMG в RAM.
        rslog("Update: downloading \(dmgURL)")
        do {
            var request = URLRequest(url: dmgURL)
            request.timeoutInterval = 120
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let downloader = BoundedDownloader(maximumBytes: 256 * 1024 * 1024)
            let response = try await downloader.download(
                for: request,
                to: tmpURL
            )
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.expectedContentLength <= 0 || http.expectedContentLength <= 256 * 1024 * 1024
            else {
                await showInstallError(L10n.updateDownloadFailed)
                return
            }
            let size = try tmpURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 256 * 1024 * 1024 else {
                await showInstallError(L10n.updateDownloadFailed)
                return
            }
        } catch {
            rslog("Update: download failed — \(error)")
            await showInstallError(L10n.updateDownloadFailed)
            return
        }

        // 2. Проверить sha256 (обязательно)
        let actualSHA = sha256OfFile(at: tmpPath)
        guard actualSHA?.lowercased() == expectedSHA else {
            rslog("Update: sha256 mismatch expected=\(expectedSHA) actual=\(actualSHA ?? "nil")")
            // Битая загрузка — НЕ «проверка не пройдена» вообще: у части пользователей сеть
            // режет/искажает скачивание с CDN GitHub (assets-хост блокируется отдельно от
            // raw.githubusercontent). Говорим прямо и предлагаем браузер.
            await showDownloadCorruptedAlert()
            return
        }
        rslog("Update: sha256 verified")

        // 3. Смонтировать DMG внутри приватного каталога с непредсказуемым именем.
        let mountURL = workDirectory.appendingPathComponent("mount", isDirectory: true)
        let mountPoint = mountURL.path
        let mount = Process()
        mount.launchPath = "/usr/bin/hdiutil"
        mount.arguments = ["attach", tmpPath, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint]
        mount.standardOutput = FileHandle.nullDevice
        mount.standardError = FileHandle.nullDevice
        do {
            try mount.run()
            mount.waitUntilExit()
            guard mount.terminationStatus == 0 else {
                rslog("Update: hdiutil attach failed with status \(mount.terminationStatus)")
                await showInstallError(L10n.updateInstallFailed)
                return
            }
        } catch {
            rslog("Update: hdiutil attach error — \(error)")
            await showInstallError(L10n.updateInstallFailed)
            return
        }

        defer { detachUpdateVolume(at: mountPoint) }   // ветки ошибок; успех чистится явно

        // 4. The dedicated updater DMG always uses the legacy physical name so
        // version 0.1.11 and TypeFlow share one signed update artifact.
        let currentApp = URL(fileURLWithPath: Bundle.main.bundlePath)
        let appName = "LocalSwitcher.app"
        let sourceApp = mountURL.appendingPathComponent(appName, isDirectory: true)
        let sourceValues = try? sourceApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let resolvedMount = mountURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolvedSource = sourceApp.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard sourceValues?.isDirectory == true,
              sourceValues?.isSymbolicLink != true,
              resolvedSource.hasPrefix(resolvedMount) else {
            rslog("Update: exact non-symlink \(appName) not found in mounted DMG")
            await showInstallError(L10n.updateInstallFailed)
            return
        }

        // 5. Проверяем подпись точным постоянным сертификатом LocalSwitcher. Это не
        //     Developer ID и не нотарификация, но подделать подпись без приватного ключа
        //     нельзя. Подпись манифеста и приложения закреплены одним ключом.
        guard verifyPinnedSignature(at: sourceApp.path) else {
            rslog("Update: pinned application signature check FAILED — aborting")
            await showInstallError(L10n.updateIntegrityFailed)
            return
        }

        // 5a. Идентичность бандла: тот же bundle id и версия совпадает с заявленной.
        //     Info.plist читаем напрямую с диска: Bundle(url:) кэширует инстансы по пути
        //     на всю жизнь процесса — у долгоживущего menu-bar приложения повторная
        //     попытка обновления получила бы данные ПРОШЛОГО смонтированного образа
        //     и упала бы с ложным «версия не совпала».
        let plistURL = sourceApp.appendingPathComponent("Contents/Info.plist")
        let mountedInfo = (try? Data(contentsOf: plistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
        let mountedID = mountedInfo?["CFBundleIdentifier"] as? String
        let mountedVersion = mountedInfo?["CFBundleShortVersionString"] as? String
        guard mountedID == Bundle.main.bundleIdentifier else {
            rslog("Update: bundle id mismatch (\(mountedID ?? "nil"))")
            await showInstallError(L10n.updateIntegrityFailed)
            return
        }
        guard mountedVersion == version else {
            rslog("Update: bundle version mismatch — announced \(version), contains \(mountedVersion ?? "nil")")
            await showInstallError(L10n.updateIntegrityFailed)
            return
        }

        // 6. Сначала сохраняем рабочую версию для ручного/аварийного отката.
        guard let backupApp = createUpdateBackup(of: currentApp, currentVersion: currentVersion()) else {
            rslog("Update: failed to create rollback copy")
            await showInstallError(L10n.updateInstallFailed)
            return
        }
        rslog("Update: rollback copy saved at \(backupApp.deletingLastPathComponent().path)")

        // 6a. Скопировать приложение в автоматически созданный item-replacement каталог
        //     на том же диске. Это устраняет фиксированный symlink-уязвимый staging path.
        guard let stagingDir = try? fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: currentApp,
            create: true
        ) else {
            await showInstallError(L10n.updateInstallFailed)
            return
        }
        let stagedApp = stagingDir.appendingPathComponent(currentApp.lastPathComponent)
        do {
            try fm.copyItem(at: sourceApp, to: stagedApp)
        } catch {
            rslog("Update: staging copy failed — \(error)")
            await showInstallError(error.localizedDescription)
            return
        }
        defer { try? fm.removeItem(at: stagingDir) }

        // Повторная проверка после копирования закрывает TOCTOU между DMG и staging.
        guard verifyPinnedSignature(at: stagedApp.path) else {
            rslog("Update: staged application signature changed")
            await showInstallError(L10n.updateIntegrityFailed)
            return
        }

        // 7. Атомарно заменить .app из staging-копии (на одном томе — работает)
        do {
            _ = try fm.replaceItemAt(currentApp, withItemAt: stagedApp)
            rslog("Update: app replaced successfully")
        } catch {
            rslog("Update: replace failed — \(error)")
            restoreBackupIfNeeded(backupApp, to: currentApp)
            await showInstallError(error.localizedDescription)
            return
        }

        // Проверяем уже установленный путь. При любом расхождении возвращаем бэкап,
        // пока старый процесс ещё жив и может показать пользователю результат.
        guard verifyPinnedSignature(at: currentApp.path),
              bundleVersion(at: currentApp) == version else {
            rslog("Update: installed application verification failed; rolling back")
            restoreBackup(backupApp, to: currentApp)
            await showInstallError(L10n.updateIntegrityFailed)
            return
        }

        // 8. Явная уборка ПЕРЕД перезапуском: relaunch завершает процесс через
        //    terminate() → exit(), поэтому defer-блоки НЕ выполняются. Без этого том
        //    оставался смонтированным до перезагрузки, а следующая попытка обновления
        //    перезаписывала backing-файл занятого образа и падала на «Resource busy»
        //    (ревью-находка, воспроизведена).
        try? fm.removeItem(at: stagingDir)
        detachUpdateVolume(at: mountPoint)
        try? fm.removeItem(at: workDirectory)

        // 9. Перезапуск
        rslog("Update: restarting...")
        guard AppRelauncher.relaunch(bundlePath: currentApp.path) else {
            rslog("Update: relaunch helper failed; rolling back")
            restoreBackup(backupApp, to: currentApp)
            await showInstallError(L10n.updateInstallFailed)
            return
        }
    }

    private static func makePrivateTemporaryDirectory() -> URL? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LocalSwitcher-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return directory
        } catch {
            rslog("Update: private temp directory failed — \(error)")
            return nil
        }
    }

    private static func createUpdateBackup(of currentApp: URL, currentVersion: String) -> URL? {
        let currentValues = try? currentApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard UpdateVersion.isValid(currentVersion),
              currentValues?.isDirectory == true,
              currentValues?.isSymbolicLink != true,
              verifyPinnedSignature(at: currentApp.path) else {
            rslog("Update: current application does not match pinned signature")
            return nil
        }
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let backupDirectory = support
            .appendingPathComponent("LocalSwitcher", isDirectory: true)
            .appendingPathComponent("UpdateBackups", isDirectory: true)
            .appendingPathComponent("\(currentVersion)-\(UUID().uuidString)", isDirectory: true)
        let backupApp = backupDirectory.appendingPathComponent(currentApp.lastPathComponent, isDirectory: true)
        do {
            try fm.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fm.copyItem(at: currentApp, to: backupApp)
            guard verifyPinnedSignature(at: backupApp.path) else {
                try? fm.removeItem(at: backupDirectory)
                return nil
            }
            return backupApp
        } catch {
            rslog("Update: backup failed — \(error)")
            try? fm.removeItem(at: backupDirectory)
            return nil
        }
    }

    private static func restoreBackupIfNeeded(_ backupApp: URL, to currentApp: URL) {
        if !FileManager.default.fileExists(atPath: currentApp.path)
            || !verifyPinnedSignature(at: currentApp.path) {
            restoreBackup(backupApp, to: currentApp)
        }
    }

    private static func restoreBackup(_ backupApp: URL, to currentApp: URL) {
        let fm = FileManager.default
        guard verifyPinnedSignature(at: backupApp.path) else {
            rslog("Update: refusing rollback from an invalid backup")
            return
        }
        do {
            if fm.fileExists(atPath: currentApp.path) {
                let replacementDirectory = try fm.url(
                    for: .itemReplacementDirectory,
                    in: .userDomainMask,
                    appropriateFor: currentApp,
                    create: true
                )
                defer { try? fm.removeItem(at: replacementDirectory) }
                let replacementApp = replacementDirectory
                    .appendingPathComponent(currentApp.lastPathComponent, isDirectory: true)
                try fm.copyItem(at: backupApp, to: replacementApp)
                guard verifyPinnedSignature(at: replacementApp.path) else {
                    rslog("Update: rollback staging signature verification failed")
                    return
                }
                _ = try fm.replaceItemAt(currentApp, withItemAt: replacementApp)
            } else {
                try fm.copyItem(at: backupApp, to: currentApp)
            }
            guard verifyPinnedSignature(at: currentApp.path) else {
                rslog("Update: restored backup signature verification failed")
                return
            }
            rslog("Update: rollback restored")
        } catch {
            rslog("Update: rollback failed — \(error)")
        }
    }

    private static func bundleVersion(at app: URL) -> String? {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dictionary = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any]
        else { return nil }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    private static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Тихо размонтирует том обновления. Вынесено из defer, потому что путь успеха
    /// завершает процесс до раскрутки стека — defer там не срабатывает.
    private static func detachUpdateVolume(at mountPoint: String) {
        let detach = Process()
        detach.launchPath = "/usr/bin/hdiutil"
        detach.arguments = ["detach", mountPoint, "-quiet"]
        detach.standardOutput = FileHandle.nullDevice
        detach.standardError = FileHandle.nullDevice
        do {
            try detach.run()
            detach.waitUntilExit()
        } catch {
            rslog("Update: hdiutil detach failed to start — \(error)")
        }
    }

    /// Проверяет целостность бандла и точный сертификат LocalSwitcher. Self-signed
    /// сертификат не даёт доверия Gatekeeper при первой установке, но обеспечивает
    /// стабильную идентичность приложения и криптографический пиннинг обновлений.
    private static func verifyPinnedSignature(at path: String) -> Bool {
        ApplicationSignatureVerifier.verify(appURL: URL(fileURLWithPath: path))
    }

    private static func sha256OfFile(at path: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.launchPath = "/usr/bin/shasum"
        process.arguments = ["-a", "256", path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return output.split(separator: " ").first.map(String.init)
        } catch {
            return nil
        }
    }

    private static func showAlert(style: NSAlert.Style, title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showInstallError(_ message: String) async {
        showAlert(style: .warning, title: L10n.updateInstallFailed, message: message)
    }

    /// Битая загрузка (sha256 не совпал): файл не тот, что публиковали. Чаще всего это
    /// сеть (обрыв/подмена на пути к CDN GitHub) — предлагаем скачать в браузере, там
    /// видна реальная сетевая ошибка, работают ретраи и Gatekeeper проверит DMG сам.
    private static func showDownloadCorruptedAlert() async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.updateInstallFailed
        alert.informativeText = L10n.updateDownloadCorrupted
        alert.addButton(withTitle: L10n.updateDownload)   // «Скачать» → страница релиза в браузере
        alert.addButton(withTitle: L10n.updateLater)
        // URL строим локально из константы, а НЕ из info.url: фид приходит по сети,
        // и остальной установщик ему сознательно не доверяет (ревью-находка).
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "\(SettingsManager.githubURL)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func showUpToDateAlert() async {
        showAlert(style: .informational, title: L10n.updateUpToDate, message: L10n.updateLatestInstalled)
    }

    private static func showErrorAlert() async {
        showAlert(style: .warning, title: L10n.updateCheckFailed, message: L10n.updateCheckFailedDetail)
    }

    private static func showIntegrityErrorAlert() async {
        showAlert(style: .warning, title: L10n.updateCheckFailed, message: L10n.updateIntegrityFailed)
    }
}

@MainActor
private final class UpdateProgressWindow {
    private let alert = NSAlert()
    private let indicator = NSProgressIndicator()

    init(version: String) {
        alert.alertStyle = .informational
        alert.messageText = L10n.updateAvailable
        alert.informativeText = "\(L10n.updateInstallRestart): \(version)"

        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.isIndeterminate = true
        indicator.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        alert.accessoryView = indicator
    }

    func show() {
        indicator.startAnimation(nil)
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
    }

    func close() {
        indicator.stopAnimation(nil)
        alert.window.orderOut(nil)
    }
}

enum BoundedDownloadError: Error {
    case exceedsLimit
    case missingDownloadedFile
}

final class BoundedDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var session: URLSession?
    private var destinationURL: URL?
    private var terminalError: Error?

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
    }

    func download(for request: URLRequest, to destinationURL: URL) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.destinationURL = destinationURL

            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = request.timeoutInterval

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard terminalError == nil else { return }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, Int64(size) <= maximumBytes else {
                terminalError = BoundedDownloadError.exceedsLimit
                return
            }
            guard let destinationURL else {
                terminalError = BoundedDownloadError.missingDownloadedFile
                return
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            terminalError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if exceedsLimit(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        ) {
            terminalError = BoundedDownloadError.exceedsLimit
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let continuation else { return }
        self.continuation = nil
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }

        if let terminalError {
            continuation.resume(throwing: terminalError)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response = task.response,
                  let destinationURL,
                  FileManager.default.fileExists(atPath: destinationURL.path) {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: BoundedDownloadError.missingDownloadedFile)
        }
    }

    func exceedsLimit(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) -> Bool {
        totalBytesWritten > maximumBytes
            || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > maximumBytes)
    }
}
