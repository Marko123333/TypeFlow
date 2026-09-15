import AppKit
import ApplicationServices
import Carbon

/// Reads only focus metadata. Never requests a value, selection or typed text.
enum PasswordFocus {
    static func isProtected(secureInput: Bool, subrole: String?, protectedContent: Bool) -> Bool {
        secureInput || subrole == "AXSecureTextField" || protectedContent
    }

    static var active: Bool {
        if IsSecureEventInputEnabled() { return true }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.03)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let focused = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.03)
        var subrole: CFTypeRef?
        var protected: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        AXUIElementCopyAttributeValue(focused, "AXProtectedContent" as CFString, &protected)
        return isProtected(secureInput: false, subrole: subrole as? String,
                           protectedContent: (protected as? Bool) == true)
    }
}

/// Secure Input can suspend the event tap, so enforcement must also run independently.
@MainActor
final class PasswordLayoutGuard {
    private var timer: Timer?
    private var sourceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var focusObserver: AXObserver?

    var onProtectedFocus: (() -> Void)?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.observeFocus(); self?.refresh() }
        }
        observeFocus()
        refresh()
    }

    private func observeFocus() {
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PasswordLayoutGuard>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.03)
        guard AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        focusObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
        sourceObserver = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
    }

    private func refresh() {
        guard PasswordFocus.active else { return }
        onProtectedFocus?()
        LayoutSwitcher.enforcePasswordEnglish()
    }
}
