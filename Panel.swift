import AppKit
import Carbon
import ApplicationServices

struct AppEntry {
    let id: String
    let name: String
    let url: URL?
}

@MainActor
final class SettingsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    unowned let controller: AppLanguageController
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let table = NSTableView()
    let search = NSSearchField()
    let permission = NSTextField(labelWithString: "")
    var entries: [AppEntry] = []
    var filtered: [AppEntry] = []
    var choices: [(String, String)] = []

    init(_ controller: AppLanguageController) {
        self.controller = controller
        super.init()
        window.title = "Keyboard AutoLang — زبان برنامه‌ها"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 430)
        choices = [("default", "پیش‌فرض برنامه"), ("remember", "یادآوری آخرین زبان"), ("keep", "بدون تغییر"), ("en", "انگلیسی"), ("fa", "فارسی")]
        choices += controller.sources.filter { $0.id.hasPrefix("com.apple.keylayout.") }.map { ($0.id, $0.name) }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        let title = NSTextField(labelWithString: "زبان کیبورد هر برنامه را انتخاب کن")
        title.font = .boldSystemFont(ofSize: 20)
        let heading = NSStackView()
        heading.spacing = 12
        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.Name("AppIcon"))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 52).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 52).isActive = true
        heading.addArrangedSubview(icon)
        heading.addArrangedSubview(title)
        root.addArrangedSubview(heading)
        let help = NSTextField(wrappingLabelWithString: "تغییرات همان لحظه ذخیره می‌شوند و در ورود بعدی به برنامه اعمال می‌شوند. انتخاب Finder و System Settings در کادر جست‌وجوی آن‌ها هم اعمال می‌شود. پیش‌فرض سایر برنامه‌ها یادآوری زبان است.")
        root.addArrangedSubview(help)
        search.placeholderString = "جست‌وجوی نام برنامه یا شناسه"
        search.delegate = self
        root.addArrangedSubview(search)
        search.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "برنامه"; appColumn.width = 410
        let langColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lang"))
        langColumn.title = "زبان کیبورد"; langColumn.width = 260
        table.addTableColumn(appColumn); table.addTableColumn(langColumn)
        table.delegate = self; table.dataSource = self
        table.rowHeight = 48
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        permission.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(permission)
        let actions = NSStackView()
        actions.spacing = 8
        for (title, action) in [("افزودن برنامه…", #selector(addApp)), ("تازه‌سازی", #selector(refresh)), ("مجوز Spotlight…", #selector(requestPermission))] {
            actions.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        root.addArrangedSubview(actions)
        refresh()
        window.center()
    }

    func show() {
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshPermission() {
        permission.stringValue = AXIsProcessTrusted() ? "مجوز Accessibility فعال است. وضعیت Spotlight در گزارش قابل بررسی است." : "برای تشخیص پنجرهٔ Spotlight، مجوز Accessibility را فعال کن؛ قوانین سایر برنامه‌ها فعال‌اند."
    }

    @objc func refresh() {
        var apps: [String: AppEntry] = [:]
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" { insert(url, into: &apps) }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, app.activationPolicy == .regular,
               let url = app.bundleURL, FileManager.default.fileExists(atPath: url.path) {
                apps[id] = AppEntry(id: id, name: app.localizedName ?? id, url: app.bundleURL)
            }
        }
        // Rules from old installs must not create phantom application rows.
        insert(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), into: &apps)
        insert(URL(fileURLWithPath: "/System/Applications/System Settings.app"), into: &apps)
        if let entry = apps["com.apple.finder"] {
            apps[entry.id] = AppEntry(id: entry.id, name: "Finder — فایندر", url: entry.url)
        }
        if let entry = apps["com.apple.systempreferences"] {
            apps[entry.id] = AppEntry(id: entry.id, name: "System Settings — تنظیمات — Systemeinstellungen", url: entry.url)
        }
        apps.removeValue(forKey: "com.apple.campo")
        apps["com.apple.Spotlight"] = AppEntry(id: "com.apple.Spotlight", name: "Spotlight / Siri — جست‌وجوی مک", url: nil)
        entries = apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        applySearch()
        refreshPermission()
        controller.refreshSpotlightObservers()
    }

    func insert(_ url: URL, into apps: inout [String: AppEntry]) {
        guard FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        apps[id] = AppEntry(id: id, name: name, url: url)
    }

    func controlTextDidChange(_ obj: Notification) { applySearch() }
    func applySearch() {
        let query = search.stringValue
        filtered = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        if tableColumn?.identifier.rawValue == "app" {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "\(entry.name)\n\(entry.id)")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.frame = NSRect(x: 8, y: 5, width: (tableColumn?.width ?? 400) - 16, height: 38)
            label.autoresizingMask = [.width]
            cell.addSubview(label)
            return cell
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 30), pullsDown: false)
        for (id, title) in choices { popup.addItem(withTitle: title); popup.lastItem?.representedObject = id }
        let rule = controller.configuredRules[entry.id] ?? "default"
        if let index = choices.firstIndex(where: { $0.0 == rule }) { popup.selectItem(at: index) }
        else { popup.addItem(withTitle: rule); popup.lastItem?.representedObject = rule; popup.selectItem(at: popup.numberOfItems - 1) }
        popup.tag = row; popup.target = self; popup.action = #selector(changed(_:))
        popup.setAccessibilityLabel("زبان \(entry.name)")
        return popup
    }

    @objc func changed(_ sender: NSPopUpButton) {
        guard filtered.indices.contains(sender.tag), let rule = sender.selectedItem?.representedObject as? String else { return }
        let id = filtered[sender.tag].id
        var updated = controller.configuredRules
        if rule == "default" { updated.removeValue(forKey: id) } else { updated[id] = rule }
        do {
            let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: rulesURL, options: .atomic)
            controller.configuredRules = updated
        } catch {
            let alert = NSAlert(); alert.messageText = "ذخیره نشد"; alert.informativeText = error.localizedDescription; alert.runModal()
            table.reloadData()
        }
    }
    @objc func addApp() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowedContentTypes = [.applicationBundle]
        guard picker.runModal() == .OK, let url = picker.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        if !entries.contains(where: { $0.id == id }) {
            entries.append(AppEntry(id: id, name: url.deletingPathExtension().lastPathComponent, url: url)); applySearch()
        }
        search.stringValue = id; applySearch()
    }
    @objc func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

@MainActor
final class AutoLangDelegate: NSObject, NSApplicationDelegate {
    let controller: AppLanguageController
    var panel: SettingsPanel?
    var status: NSStatusItem?
    init(_ controller: AppLanguageController) { self.controller = controller }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = NSImage(named: NSImage.Name("AppIcon"))?.copy() as? NSImage {
            icon.size = NSSize(width: 22, height: 22)
            icon.isTemplate = false
            item.button?.image = icon
            NSApp.applicationIconImage = NSImage(named: NSImage.Name("AppIcon"))
        } else {
            item.button?.title = "⌨︎"
        }
        item.button?.setAccessibilityLabel("Keyboard AutoLang")
        let menu = NSMenu()
        menu.addItem(withTitle: "تنظیم زبان برنامه‌ها…", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "تازه‌سازی مجوز Spotlight", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "خروج تا ورود بعدی به مک", action: #selector(quit), keyEquivalent: "").target = self
        item.menu = menu; status = item
        if CommandLine.arguments.contains("--panel") { showPanel() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    @objc func showPanel() { if panel == nil { panel = SettingsPanel(controller) }; panel?.show() }
    @objc func refresh() { controller.refreshSpotlightObservers(); panel?.refreshPermission() }
    @objc func quit() { NSApp.terminate(nil) }
}
