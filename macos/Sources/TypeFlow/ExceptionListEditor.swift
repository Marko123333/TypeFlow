import AppKit
import UniformTypeIdentifiers

/// Редактор одного списка-исключений (приложения или слова): таблица + кнопки «+»/«−».
/// Привязка к данным — через замыкания get/set, чтобы один класс обслуживал любой список.
@MainActor
final class ExceptionListEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Kind { case apps, words }

    private let kind: Kind
    private let getList: () -> [String]
    private let setList: ([String]) -> Void
    private let isProtected: (String) -> Bool
    private let addWordPrompt: String

    private var items: [String] = []
    private let table = NSTableView()
    private let removeButton = NSButton()
    /// Кэш имени/иконки по bundle id, чтобы не дёргать NSWorkspace на каждый vend ячейки.
    private var infoCache: [String: (text: String, icon: NSImage?)] = [:]

    init(kind: Kind,
         get: @escaping () -> [String],
         set: @escaping ([String]) -> Void,
         isProtected: @escaping (String) -> Bool = { _ in false },
         addWordPrompt: String = "") {
        self.kind = kind
        self.getList = get
        self.setList = set
        self.isProtected = isProtected
        self.addWordPrompt = addWordPrompt
        super.init()
        self.items = get()
    }

    /// Контейнер: прокручиваемая таблица + строка кнопок «+»/«−» снизу.
    func makeContainer(frame: NSRect) -> NSView {
        let container = NSView(frame: frame)
        let stripH: CGFloat = 26

        let scroll = NSScrollView(frame: NSRect(x: 0, y: stripH, width: frame.width, height: frame.height - stripH))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        col.width = frame.width - 4
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        container.addSubview(scroll)

        let addBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        addBtn.title = "+"
        addBtn.bezelStyle = .smallSquare
        addBtn.target = self
        addBtn.action = #selector(addTapped)
        container.addSubview(addBtn)

        removeButton.frame = NSRect(x: 30, y: 0, width: 28, height: 24)
        removeButton.title = "−"
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.isEnabled = false
        container.addSubview(removeButton)

        return container
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = items[row]
        let info = cellInfo(id)
        let cell = NSTableCellView()

        let text = NSTextField(labelWithString: info.text)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        if isProtected(id) { text.textColor = .secondaryLabelColor }
        cell.addSubview(text)

        var leading: CGFloat = 4
        if kind == .apps, let icon = info.icon {
            let iv = NSImageView(image: icon)
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = 24
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        let row = table.selectedRow
        removeButton.isEnabled = row >= 0 && row < items.count && !isProtected(items[row])
    }

    // MARK: - Actions

    @objc private func addTapped() {
        switch kind {
        case .apps: addApp()
        case .words: addWord()
        }
    }

    @objc private func removeTapped() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        let value = items[row]
        guard !isProtected(value) else { return }
        items = getList()                 // пере-синхрон с живым стором (learn-from-undo и т.п.)
        items.removeAll { $0 == value }   // удаляем по значению, не по устаревшему индексу
        persist()
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        items = getList()
        guard !items.contains(id) else { return }
        items.append(id)
        persist()
    }

    private func addWord() {
        let alert = NSAlert()
        alert.messageText = addWordPrompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.commonAdd)
        alert.addButton(withTitle: L10n.commonCancel)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        items = getList()
        guard !word.isEmpty,
              !items.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        items.append(word)
        persist()
    }

    private func persist() {
        setList(items)
        table.reloadData()
        updateRemoveButton()
    }

    // MARK: - Display helpers

    private func cellInfo(_ id: String) -> (text: String, icon: NSImage?) {
        if let cached = infoCache[id] { return cached }
        let info = (text: displayText(id), icon: kind == .apps ? appIcon(id) : nil)
        infoCache[id] = info
        return info
    }

    private func displayText(_ id: String) -> String {
        guard kind == .apps else { return id }
        if id.hasSuffix("*") { return String(id.dropLast()) + "* (все)" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return id
    }

    private func appIcon(_ id: String) -> NSImage? {
        guard !id.hasSuffix("*"),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
