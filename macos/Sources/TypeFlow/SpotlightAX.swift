import AppKit
import ApplicationServices
import CoreGraphics

/// issue #16: Spotlight «съедает» первый Backspace серого автодополнения, из-за чего
/// обычная конверсия (стирание клавишами) оставляет лишнюю букву. Spotlight — защищённая
/// поверхность: не отдаётся как frontmost-приложение и не участвует в system-wide AX-фокусе,
/// НО его окно видно в CGWindowList (owner "Spotlight"), а процесс com.apple.Spotlight
/// отдаёт своё поле адресным AX-запросом (проверено живым захватом 2026-08-01).
enum SpotlightAX {
    /// Активен ли Spotlight ПРЯМО СЕЙЧАС как цель ввода. Гейт намеренно строгий: перед
    /// деструктивной заменой (Cmd+A + вставка) нельзя ошибиться — иначе затрём документ в
    /// другом приложении (skeptic-находка). Поэтому требуем ОБА признака:
    ///   1) окно Spotlight на экране и полностью видимо (alpha≈1, не в анимации закрытия —
    ///      во время fade-out окно ещё в списке, но фокус уже ушёл в редактор);
    ///   2) процесс com.apple.Spotlight реально держит сфокусированное текстовое поле
    ///      (когда Spotlight закрывается, фокус уходит → поля нет → гейт закрыт).
    @MainActor
    static func isActive() -> Bool {
        // 1) полностью видимое окно Spotlight (alpha≈1, а не гаснущее)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let visibleWindow = list.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "Spotlight"
            && (($0[kCGWindowAlpha as String] as? Double) ?? 0) > 0.9
        }
        guard visibleWindow else { return false }

        // 2) Spotlight реально держит текстовое поле в фокусе (истинная цель ввода)
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Spotlight"
        }) else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        var fRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &fRaw) == .success,
              let f = fRaw else { return false }
        var roleRaw: AnyObject?
        AXUIElementCopyAttributeValue(f as! AXUIElement, kAXRoleAttribute as CFString, &roleRaw)
        return (roleRaw as? String) == (kAXTextFieldRole as String)
    }
}
