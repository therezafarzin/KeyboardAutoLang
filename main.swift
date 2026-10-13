import AppKit
import Carbon
import Foundation
import ApplicationServices

// Uses only Apple frameworks. Never reads keystrokes or text.
struct InputSource {
    let id: String
    let name: String
    let languages: [String]
    let source: TISInputSource
}

func propertyString(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func propertyLanguages(_ source: TISInputSource) -> [String] {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
    return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]) ?? []
}

func installedSources() -> [InputSource] {
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    return list.compactMap { source in
        guard let id = propertyString(source, kTISPropertyInputSourceID) else { return nil }
        return InputSource(id: id,
                           name: propertyString(source, kTISPropertyLocalizedName) ?? id,
                           languages: propertyLanguages(source), source: source)
    }
}

func currentSourceID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return propertyString(source, kTISPropertyInputSourceID)
}

func log(_ message: String) {
    fputs("[KeyboardAutoLang] \(message)\n", stderr)
}

let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/KeyboardAutoLang", isDirectory: true)
let memoryURL = supportDirectory.appendingPathComponent("memory.json")
let rulesURL = supportDirectory.appendingPathComponent("rules.json")

@MainActor
final class AppLanguageController {
    let sources = installedSources()
    let englishID: String?
    let persianID: String?
    var remembered: [String: String] = [:]
    var configuredRules: [String: String] = [:]
    var previousAppID: String?
    var previousAppName: String?
    var observer: NSObjectProtocol?
    var launchObserver: NSObjectProtocol?
    var exitObserver: NSObjectProtocol?
    var spotlightObservers: [pid_t: AXObserver] = [:]
    var spotlightWork: DispatchWorkItem?

    func observeSpotlight(_ app: NSRunningApplication) {
        guard ["com.apple.Spotlight", "com.apple.campo", "com.apple.finder", "com.apple.systempreferences"].contains(app.bundleIdentifier ?? ""),
              spotlightObservers[app.processIdentifier] == nil else { return }
        guard AXIsProcessTrusted() else {
            log("Spotlight: Accessibility permission required; app-switch rules remain active")
            return
        }
        var result: AXObserver?
        let status = AXObserverCreate(app.processIdentifier, { _, element, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let controller = Unmanaged<AppLanguageController>.fromOpaque(context).takeUnretainedValue()
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                controller.spotlightFocused(notification as String, pid: pid)
            }
        }, &result)
        guard status == .success, let axObserver = result else {
            log("Spotlight observer failed: \(status.rawValue)")
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                             kAXWindowCreatedNotification] {
            let error = AXObserverAddNotification(axObserver, element, notification as CFString, context)
            if error == .success { registered += 1 }
            log("Spotlight subscribe \(notification): \(error.rawValue)")
        }
        guard registered > 0 else { return }
        spotlightObservers[app.processIdentifier] = axObserver
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        log("Focus observer ready [\(app.bundleIdentifier ?? "unknown")] pid=\(app.processIdentifier)")
    }

    func spotlightFocused(_ notification: String, pid: pid_t) {
        // For these two apps the selected rule is app-wide. Apply directly on
        // their focus notification: no deferred task or synchronous AX queries
        // may sit ahead of the input-source change.
        if let app = NSRunningApplication(processIdentifier: pid),
           let id = app.bundleIdentifier,
           ["com.apple.finder", "com.apple.systempreferences"].contains(id) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let target = requiredSource(for: id, name: app.localizedName ?? id) else { return }
            select(target)
            log("Immediate focus [\(id)] input=\(currentSourceID() ?? "unknown")")
            return
        }
        spotlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let englishID = self.englishID else { return }
            // Inspect only focus state, never text, search queries, or keystrokes.
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.2)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused else { return }
            let focusElement = focused as! AXUIElement
            var isFocused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(focusElement, kAXFocusedAttribute as CFString, &isFocused) == .success,
                  (isFocused as? Bool) == true else { return }
            let id = app.bundleIdentifier ?? ""
            let isSearchApp = ["com.apple.finder", "com.apple.systempreferences"].contains(id)
            if isSearchApp {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                var subrole: CFTypeRef?
                guard AXUIElementCopyAttributeValue(focusElement, kAXSubroleAttribute as CFString, &subrole) == .success,
                      (subrole as? String) == (kAXSearchFieldSubrole as String) else { return }
                guard let target = self.requiredSource(for: id, name: app.localizedName ?? id) else { return }
                self.select(target)
                log("Search focus [\(id)] input=\(currentSourceID() ?? "unknown")")
            } else {
                let rule = self.configuredRules["com.apple.Spotlight"]
                if rule == "keep" || rule == "remember" { return }
                let target = self.requiredSource(for: "com.apple.Spotlight", name: "Spotlight") ?? englishID
                self.select(target)
                log("Spotlight focus [\(notification)] input=\(currentSourceID() ?? "unknown")")
            }
        }
        spotlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func refreshSpotlightObservers() {
        for app in NSWorkspace.shared.runningApplications { observeSpotlight(app) }
    }

    func startSpotlightObserver() {
        for app in NSWorkspace.shared.runningApplications { observeSpotlight(app) }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.observeSpotlight(app) }
        }
        exitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if let observer = self?.spotlightObservers.removeValue(forKey: app.processIdentifier) {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
            }
        }
    }

    init() {
        // Prefer Apple ABC / U.S. rather than guessing that any Latin input source is English.
        englishID = sources.first(where: { $0.id == "com.apple.keylayout.ABC" })?.id
            ?? sources.first(where: { $0.id == "com.apple.keylayout.US" })?.id
            ?? sources.first(where: {
                $0.languages.contains(where: { $0.lowercased().hasPrefix("en") }) &&
                ($0.name.lowercased().contains("english") ||
                 $0.name.lowercased().contains("british") ||
                 $0.name.lowercased() == "u.s.")
            })?.id

        persianID = sources.first(where: { $0.id == "com.apple.keylayout.Persian" })?.id
            ?? sources.first(where: { $0.id.lowercased().contains("persian") })?.id
            ?? sources.first(where: { $0.languages.contains(where: { $0.lowercased().hasPrefix("fa") }) })?.id

        if let data = try? Data(contentsOf: memoryURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            remembered = saved
        }
        if let data = try? Data(contentsOf: rulesURL),
           let rules = try? JSONDecoder().decode([String: String].self, from: data) {
            configuredRules = rules
        }
    }

    func isSpotlight(_ id: String, _ name: String) -> Bool {
        let identifier = id.lowercased()
        let display = name.lowercased()
        return identifier.contains("spotlight") || display.contains("spotlight") ||
               identifier == "com.apple.siri" || identifier == "com.apple.campo" || display == "siri ai"
    }

    func requiredSource(for id: String, name: String) -> String? {
        let rule: String
        if let match = configuredRules[id == "com.apple.campo" ? "com.apple.Spotlight" : id] {
            rule = ["en", "fa", "keep", "remember"].contains(match.lowercased()) ? match.lowercased() : match
        } else if id == "com.apple.Terminal" || name == "Terminal" {
            rule = "en"
        } else if id.lowercased().contains("telegram") || name.lowercased().contains("telegram") {
            rule = "fa"
        } else if isSpotlight(id, name) {
            rule = "en"
        } else {
            return nil // No forced rule; remember the app's last source.
        }
        if rule == "en" { return englishID }
        if rule == "fa" { return persianID }
        if rule == "keep" || rule == "remember" { return nil }
        return sources.first(where: { $0.id == rule })?.id
    }

    func hasForcedRule(for id: String, name: String) -> Bool {
        if let value = configuredRules[id == "com.apple.campo" ? "com.apple.Spotlight" : id] { return !["keep", "remember"].contains(value.lowercased()) }
        return id == "com.apple.Terminal" || name == "Terminal" ||
            id.lowercased().contains("telegram") || name.lowercased().contains("telegram") ||
            isSpotlight(id, name)
    }

    func persistMemory() {
        guard let data = try? JSONEncoder().encode(remembered) else { return }
        do { try data.write(to: memoryURL, options: .atomic) }
        catch { log("Unable to save memory: \(error.localizedDescription)") }
    }

    func select(_ id: String) {
        if currentSourceID() == id { return }
        guard let source = sources.first(where: { $0.id == id }) else {
            log("Unavailable input source: \(id)")
            return
        }
        let status = TISSelectInputSource(source.source)
        if status != noErr {
            log("TISSelectInputSource failed: \(status) for \(id)")
        } else {
            log("Selected \(id)")
        }
    }

    func activated(_ app: NSRunningApplication) {
        if let data = try? Data(contentsOf: rulesURL), let rules = try? JSONDecoder().decode([String: String].self, from: data) { configuredRules = rules }
        guard let id = app.bundleIdentifier else { return }
        if id == previousAppID { return }
        let name = app.localizedName ?? id
        let currentlySelected = currentSourceID()

        // Save any manual source change in the app being left.
        if let previousID = previousAppID,
           let previousSource = currentlySelected,
           !hasForcedRule(for: previousID, name: previousAppName ?? previousID),
           remembered[previousID] != previousSource {
            remembered[previousID] = previousSource
            persistMemory()
        }
        previousAppID = id
        previousAppName = name
        log("Activated \(name) [\(id)]")

        if configuredRules[id == "com.apple.campo" ? "com.apple.Spotlight" : id]?.lowercased() == "keep" { return }
        let desired = requiredSource(for: id, name: name) ?? remembered[id]
        if desired == nil, let current = currentlySelected {
            remembered[id] = current
            persistMemory()
        }
        guard let target = desired else { return }

        // Set immediately for the first keystroke. One bounded recheck handles
        // apps which restore their own source at the end of activation.
        select(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self, self.previousAppID == id else { return }
            self.select(target)
        }
    }

    func start() {
        let backgroundApp = NSApplication.shared
        _ = backgroundApp.setActivationPolicy(.accessory)
        let delegate = AutoLangDelegate(self)
        backgroundApp.delegate = delegate
        log("English: \(englishID ?? "NOT FOUND") | Persian: \(persianID ?? "NOT FOUND")")
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.activated(app)
            }
        }
        startSpotlightObserver()
        if let app = NSWorkspace.shared.frontmostApplication { activated(app) }
        withExtendedLifetime(delegate) { backgroundApp.run() }
    }
}

MainActor.assumeIsolated {
let controller = AppLanguageController()
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--accessibility-check") {
    print("Accessibility: \(AXIsProcessTrusted())")
} else if arguments.contains("--current") {
    print(currentSourceID() ?? "NOT FOUND")
} else if arguments.contains("--list") {
    for source in controller.sources {
        print("\(source.id) | \(source.name) | \(source.languages.joined(separator: ","))")
    }
} else if arguments.contains("--apps") {
    for app in NSWorkspace.shared.runningApplications
        .filter({ $0.activationPolicy == .regular })
        .sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
        print("\(app.localizedName ?? "?") | \(app.bundleIdentifier ?? "(no bundle id)")")
    }
} else if arguments.contains("--check") {
    print("English: \(controller.englishID ?? "NOT FOUND")")
    print("Persian: \(controller.persianID ?? "NOT FOUND")")
    if controller.englishID == nil || controller.persianID == nil { exit(2) }
} else {
    controller.start()
}

}
