import AppKit
import SwiftUI

enum ShelfExpiry: Int, CaseIterable, Identifiable {
    case never = 0
    case oneDay = 1
    case sevenDays = 7
    case tenDays = 10
    case thirtyDays = 30

    /// The one key and the one default, shared by the Settings picker and by
    /// `AppDelegate.runShelfExpiryPrune`. `DefaultPreferences` registers the
    /// pair at launch, so the value the picker displays on a fresh install is
    /// the value the pruner executes rather than a second literal.
    static let defaultsKey = "shelf.expiryDays"
    static let defaultValue: ShelfExpiry = .tenDays

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: return L("Never")
        case .oneDay: return L("After 1 day")
        case .sevenDays: return L("After 7 days")
        case .tenDays: return L("After 10 days")
        case .thirtyDays: return L("After 30 days")
        }
    }
}

struct SettingsView: View {
    @AppStorage(ShelfExpiry.defaultsKey) private var expiryDays: Int = ShelfExpiry.defaultValue.rawValue
    @AppStorage("shelf.autoParkTopRight") private var autoParkTopRight: Bool = false
    @AppStorage("shelf.closeOnOutsideClick") private var closeOnOutsideClick: Bool = false
    @AppStorage("shelf.clearAfterDragOut") private var clearAfterDragOut: Bool = false
    @AppStorage(AppearancePreference.defaultsKey) private var appearancePreference: AppearancePreference = .system
    @AppStorage(MenuBarVisibility.defaultsKey) private var showMenuBarIcon: Bool = MenuBarVisibility.showsByDefault
    @AppStorage("SUEnableAutomaticChecks") private var autoCheckUpdates: Bool = true
    @AppStorage(ShelfGlass.defaultsKey) private var glass: Double = ShelfGlass.defaultValue
    @AppStorage(MascotPreference.defaultsKey) private var mascotShown: Bool = true
    @AppStorage(ShelfNotch.defaultsKey) private var notchIsland: Bool = false

    /// Whether this build can check for updates at all. Read once from
    /// `UpdateAvailability` (a per-launch constant: the key is baked into
    /// Info.plist) and injectable so tests can pin what each state displays.
    /// The updates toggle and the diagnostics report both go through this, so
    /// the two cannot disagree about the same build.
    var updatesConfigured: Bool = UpdateAvailability.isConfigured

    // Summon triggers. Defaults mirror the `register(defaults:)` call in
    // AppDelegate, which is what non-SwiftUI readers see.
    @AppStorage("shelf.trigger.shake") private var triggerShake: Bool = true
    @AppStorage("shelf.trigger.hotkey") private var triggerHotkey: Bool = true
    @AppStorage("shelf.trigger.hotkeyPreset") private var hotkeyPreset: HotkeyPreset = .optionShiftS
    @AppStorage("shelf.trigger.dragToEdge") private var triggerDragToEdge: Bool = true
    @AppStorage("shelf.trigger.edge") private var summonEdge: SummonEdge = .right
    @AppStorage("shelf.trigger.menuBarClick") private var triggerMenuBarClick: Bool = true

    // Copy for chat. Not a summon trigger — it acts on the shelf that already
    // exists — but it is the same kind of setting, so it sits next to them.
    @AppStorage("shelf.chatCopy.hotkey") private var chatCopyHotkey: Bool = true
    @AppStorage("shelf.chatCopy.hotkeyPreset") private var chatCopyPreset: ChatHotkeyPreset = .optionShiftC

    // Send to agent. Where the copy-for-chat shortcut should put the shelf,
    // and whether it may type it there. Auto-paste is the only thing in Magpie
    // that needs a TCC permission, so it is off until the user switches it on,
    // and the key is deliberately not in `register(defaults:)`, so the readers
    // outside SwiftUI see the same false.
    @AppStorage("shelf.agentSend.target") private var agentTarget: AgentHarness = .claudeCode
    @AppStorage("shelf.agentSend.autoPaste") private var agentAutoPaste: Bool = false

    /// Source of truth is whether our LaunchAgent plist exists in
    /// `~/Library/LaunchAgents/`. Mirrored into local state so the toggle
    /// stays in sync if the file is removed externally.
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled

    @State private var pickedLanguage: AppLanguage = LanguagePreference.current

    /// The language this process actually launched with. Captured when the
    /// Settings window is first built, which is necessarily before the picker
    /// has been touched in this process, and never updated after — a picked
    /// language only becomes the running one at the next launch, so the
    /// relaunch affordance shows exactly while the two differ.
    @State private var languageAtProcessLaunch: AppLanguage = LanguagePreference.current

    /// Routes and their secrets. The store is the app-wide one so a reload
    /// here is the same reload the menus read from.
    @ObservedObject private var routeStore = RouteStore.shared
    @State private var secretNames: [String] = []

    /// The harnesses actually on this Mac, resolved when Settings opens. One
    /// that is not installed is never offered, so the picker cannot name a
    /// target the send path would then fail to find.
    @State private var installedHarnesses: [InstalledHarness] = []
    /// Watches for the Accessibility grant after the system prompt. Held so a
    /// second flip of the toggle cancels the first watch instead of stacking.
    @State private var trustWatch: Task<Void, Never>?

    /// Settings search. Matching lives in `SettingsSearch` so it is testable
    /// without a window; this holds only the query and the focus.
    @State private var search = SettingsSearch()
    /// A query to open with. Empty in the app; the snapshots use it to show
    /// one section without scrolling.
    var initialSearch: String = ""
    @FocusState private var searchFocused: Bool

    /// The three numbers only the shelf model knows, read when the diagnostics
    /// report is built. A closure rather than a stored value so a window that
    /// stays open for a week does not report the counts it had on day one, and
    /// so Settings never holds the model itself.
    var shelfSnapshot: @MainActor () -> Diagnostics.ShelfSnapshot = { .empty }

    /// The Clear Cache button's whole reach. A closure for the same reason as
    /// `shelfSnapshot` (Settings never holds the model), and the app wires it
    /// to `ShelfManager.clearManagedCache`, which is nothing but the ADR 0001
    /// bounded eviction with a zero budget — so this button structurally
    /// cannot touch a file Magpie does not manage. Default no-op for previews.
    var clearManagedCache: @MainActor () -> Void = {}

    /// What the cache row shows. Refreshed when Settings appears and after
    /// every clear, so the number is what is on disk, not what it was when the
    /// window first opened.
    @State private var cacheBytes: Int64 = 0

    /// Set for a moment after Copy Diagnostics, so the button says what it did.
    @State private var copiedDiagnostics = false

    var body: some View {
        Form {
            searchField
            if search.sectionMatches(shelvesTerms) { shelvesSection }
            if search.sectionMatches(summoningTerms) { summoningSection }
            if search.sectionMatches(agentSendTerms) { agentSendSection }
            if search.sectionMatches(routesTerms) { routesAndSecretsSection }
            if search.sectionMatches(appearanceTerms) { appearanceSection }
            if search.sectionMatches(updatesTerms) { updatesSection }
            if search.sectionMatches(diagnosticsTerms) { diagnosticsSection }
            if search.isActive && !anySectionMatches {
                Text(L("settings.search.no-results"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .background {
            // ⌘F with no main menu to hang it on. A zero-size button carries the
            // shortcut; SwiftUI still routes the key equivalent to it, and it
            // moves focus into the field rather than doing anything itself.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            if !initialSearch.isEmpty { search.query = initialSearch }
            launchAtLogin = LaunchAtLoginManager.isEnabled
            pickedLanguage = LanguagePreference.current
            secretNames = SecretStore.names()
            cacheBytes = shelfSnapshot().managedCacheBytes
            refreshHarnesses()
        }
    }

    // MARK: - Search

    /// The terms each section can be found by. Declared once and used for both
    /// the section-level visibility check and the empty-result state, so the
    /// two cannot disagree about whether anything matched.
    ///
    /// Each entry carries the row's visible label plus the words someone would
    /// reach for having forgotten it.
    private var shelvesTerms: [[String]] {
        [[L("Auto-delete shelves"), "expiry", "delete", "clean"],
         [L("Park new shelves at the top-right corner"), "park", "corner", "position"],
         [L("Collapse expanded shelf when clicking outside"), "collapse", "outside", "dismiss"],
         [L("Clear the shelf after dragging out"), "clear", "empty", "drag", "auto", "close"],
         [L("Launch at login"), "startup", "login", "boot", "autostart"]]
    }
    private var summoningTerms: [[String]] {
        [[L("Shake while dragging"), "shake", "gesture"],
         [L("Keyboard shortcut"), L("Shortcut"), "hotkey", "keyboard"],
         [L("Summon at the screen edge"), L("Edge"), "edge", "screen", "corner"],
         [L("Click the menu bar icon"), "menu bar", "menubar", "status", "icon"]]
    }
    private var agentSendTerms: [[String]] {
        [[L("Copy shelf shortcut"), "copy", "chat", "clipboard", "hotkey"],
         [L("Agent app"), "claude", "codex", "opencode", "terminal", "harness", "agent"],
         [L("Paste into the agent automatically"), "paste", "auto", "accessibility", "permission"]]
    }
    private var routesTerms: [[String]] {
        [[L("Routes and Secrets"), "route", "script", "secret", "key", "api", "keychain", "byok"]]
    }
    private var appearanceTerms: [[String]] {
        [[L("Appearance"), "theme", "dark", "light", "system", "colour", "color"],
         [L("settings.glass"), L("settings.glass.light"), L("settings.glass.solid"),
          "glass", "transparency", "translucent", "frost", "blur", "opacity", "solid"],
         [L("settings.mascot"), "magpie", "bird", "mascot", "pet", "animation", "bring back"],
         [L("settings.notch"), "notch", "island", "camera", "top"],
         [L("Show Magpie in the menu bar"), "menu bar", "menubar", "hide", "icon", "status"],
         [L("Language"), "language", "locale", "translate"]]
    }
    private var updatesTerms: [[String]] {
        [[L("Check for updates automatically"), "update", "sparkle", "version", "upgrade"]]
    }
    private var diagnosticsTerms: [[String]] {
        [[L("settings.diagnostics"), L("settings.diagnostics.version"),
          "diagnostics", "version", "about", "build", "support", "bug", "report",
          "log", "logs", "folder", "data", "reveal", "finder", "troubleshoot"],
         [L("settings.cache.title"), L("settings.cache.clear"),
          "cache", "clear", "storage", "disk", "space", "size"]]
    }

    private var anySectionMatches: Bool {
        [shelvesTerms, summoningTerms, agentSendTerms,
         routesTerms, appearanceTerms, updatesTerms, diagnosticsTerms]
            .contains { search.sectionMatches($0) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L("settings.search.placeholder"), text: $search.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { search.query = ""; searchFocused = false }
            if search.isActive {
                Button {
                    search.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("settings.search.clear"))
            }
        }
        .padding(.vertical, 2)
    }

    private var shelvesSection: some View {
        Section {
            Picker(L("Auto-delete shelves"), selection: $expiryDays) {
                ForEach(ShelfExpiry.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            // NSPopUpButton caches its option labels, so changing language
            // needs a fresh picker identity.
            .id(pickedLanguage)

            formNote("settings.expiry.description")

            Toggle(
                L("Park new shelves at the top-right corner"),
                isOn: $autoParkTopRight
            )
            .toggleStyle(.switch)

            formNote("settings.park.description")

            Toggle(
                L("Collapse expanded shelf when clicking outside"),
                isOn: $closeOnOutsideClick
            )
            .toggleStyle(.switch)

            formNote("settings.collapse.description")

            Toggle(
                L("Clear the shelf after dragging out"),
                isOn: $clearAfterDragOut
            )
            .toggleStyle(.switch)

            formNote("settings.clear-after-drag.description")

            Toggle(L("Launch at login"), isOn: Binding(
                get: { launchAtLogin },
                set: { applyLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            formNote("settings.launch.description")
        } header: {
            Text(L("Shelves"))
        }
    }

    /// Each trigger carries its footnote: the Summoning section is where a
    /// stranger learns what the product does, and this copy sat fully
    /// translated in all nine tables while the section rendered none of it.
    private var summoningSection: some View {
        Section {
            Toggle(L("Shake while dragging"), isOn: $triggerShake)
                .toggleStyle(.switch)

            formNote("settings.trigger.shake.description")

            Toggle(L("Keyboard shortcut"), isOn: $triggerHotkey)
                .toggleStyle(.switch)

            Picker(L("Shortcut"), selection: $hotkeyPreset) {
                ForEach(HotkeyPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .disabled(!triggerHotkey)

            formNote("settings.trigger.hotkey.description")

            Toggle(L("Summon at the screen edge"), isOn: $triggerDragToEdge)
                .toggleStyle(.switch)

            Picker(L("Edge"), selection: $summonEdge) {
                ForEach(SummonEdge.allCases) { edge in
                    Text(edge.displayName).tag(edge)
                }
            }
            .pickerStyle(.menu)
            .disabled(!triggerDragToEdge)
            .id(pickedLanguage)

            formNote("settings.trigger.edge.description")

            Toggle(L("Click the menu bar icon"), isOn: $triggerMenuBarClick)
                .toggleStyle(.switch)

            formNote("settings.trigger.menubar.description")
        } header: {
            Text(L("Summoning"))
        }
    }

    /// Where the copy shortcut sends the shelf, and whether it may type there.
    private var agentSendSection: some View {
        Section {
            Toggle(L("Copy shelf shortcut"), isOn: $chatCopyHotkey)
                .toggleStyle(.switch)

            Picker(L("Shortcut"), selection: $chatCopyPreset) {
                ForEach(ChatHotkeyPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .disabled(!chatCopyHotkey)

            if installedHarnesses.isEmpty {
                LabeledContent(L("Agent app")) {
                    Text(L("agent.none-installed"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker(L("Agent app"), selection: $agentTarget) {
                    ForEach(installedHarnesses, id: \.harness) { installed in
                        Text(installed.displayName).tag(installed.harness)
                    }
                }
                .pickerStyle(.menu)
                .id(pickedLanguage)

                Toggle(L("agent.auto-paste"), isOn: Binding(
                    get: { agentAutoPaste },
                    set: { applyAutoPaste($0) }
                ))
                .toggleStyle(.switch)

                formNote("agent.auto-paste.description")
            }
        } header: {
            Text(L("agent.section"))
        }
    }

    private var routesAndSecretsSection: some View {
        Section {
            routeRows
            secretRows
        } header: {
            Text(L("Routes and Secrets"))
        }
    }

    @ViewBuilder
    private var routeRows: some View {
        LabeledContent(L("routes.menu")) {
            ControlGroup {
                Button(L("settings.routes.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([routeStore.fileURL])
                }
                Button(L("settings.routes.reload")) {
                    routeStore.reload()
                }
            }
            .controlSize(.small)
        }

        if let error = routeStore.parseError {
            LabeledContent {
                Text(error.displayMessage)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            } label: {
                EmptyView()
            }
        } else if routeStore.routes.isEmpty {
            formNote("settings.routes.empty")
        } else {
            ForEach(routeStore.routes) { route in
                LabeledContent {
                    Text(route.id)
                        .foregroundStyle(.tertiary)
                } label: {
                    Label(route.name, systemImage: route.symbol ?? "arrow.triangle.branch")
                }
            }
        }

        formNote("settings.routes.description")
    }

    @ViewBuilder
    private var secretRows: some View {
        LabeledContent(L("settings.secrets.title")) {
            Button(L("settings.secrets.add")) { addSecret() }
                .controlSize(.small)
        }

        if secretNames.isEmpty {
            formNote("settings.secrets.empty")
        } else {
            ForEach(secretNames, id: \.self) { name in
                LabeledContent(name) {
                    Button(L("settings.secrets.delete")) {
                        SecretStore.delete(name)
                        secretNames = SecretStore.names()
                    }
                    .buttonStyle(.link)
                }
            }
        }

        formNote("settings.secrets.description")
    }

    private var appearanceSection: some View {
        Section {
            Picker(L("Appearance"), selection: $appearancePreference) {
                ForEach(AppearancePreference.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: appearancePreference) { _ in
                AppearancePreference.apply(appearancePreference)
            }

            formNote("settings.appearance.description")

            LabeledContent(L("settings.glass")) {
                Slider(value: $glass, in: 0...1) {
                    Text(L("settings.glass"))
                } minimumValueLabel: {
                    Text(L("settings.glass.light"))
                } maximumValueLabel: {
                    Text(L("settings.glass.solid"))
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }

            formNote("settings.glass.description")

            Toggle(isOn: $mascotShown) {
                HStack(spacing: Design.Space.sm) {
                    // The magpie itself, so the way back is found by sight.
                    Image(nsImage: StatusIcon.image(dropping: false, awake: false))
                        .accessibilityHidden(true)
                    Text(L("settings.mascot"))
                }
            }
            .toggleStyle(.switch)

            formNote("settings.mascot.description")

            Toggle(L("settings.notch"), isOn: $notchIsland)
                .toggleStyle(.switch)

            formNote("settings.notch.description")

            Toggle(L("Show Magpie in the menu bar"), isOn: $showMenuBarIcon)
                .toggleStyle(.switch)

            formNote("settings.menubar.description")

            if !showMenuBarIcon {
                LabeledContent {
                    Button(L("Quit Magpie")) { NSApp.terminate(nil) }
                } label: {
                    EmptyView()
                }
            }

            // The custom binding writes before SwiftUI refreshes the picker.
            Picker(L("Language"), selection: Binding(
                get: { pickedLanguage },
                set: { newValue in
                    pickedLanguage = newValue
                    LanguagePreference.current = newValue
                }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)

            formNote("settings.language.description")

            // The override is read by NSBundle once, at first lookup, so the
            // running process keeps its launch language whatever the picker
            // says. Saying nothing here left the picker looking broken; the
            // note and the button appear exactly while a change is pending.
            if pickedLanguage != languageAtProcessLaunch {
                formNote("Takes effect on next launch.")

                LabeledContent {
                    Button(L("Quit & Reopen")) { Self.quitAndReopen() }
                } label: {
                    EmptyView()
                }
            }
        } header: {
            Text(L("Appearance"))
        }
    }

    /// Relaunches as a separate process so it survives this one terminating
    /// right after. `-n` asks for a fresh instance: `open` without it would
    /// just activate the instance that is about to quit.
    private static func quitAndReopen() {
        let process = Process()
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundlePath]
        } else if let executable = Bundle.main.executablePath {
            // A raw SwiftPM binary (swift run) has no bundle for `open` to
            // launch; exec the binary itself.
            process.executableURL = URL(fileURLWithPath: executable)
        }
        if process.executableURL != nil { try? process.run() }
        NSApp.terminate(nil)
    }

    private var updatesSection: some View {
        Section {
            // The stored preference can read true on a build whose updater is
            // never started (no Sparkle signing key), so what the toggle shows
            // goes through one pure decision instead of reading the store
            // directly — the toggle must not display a state the updater does
            // not have.
            let display = UpdateAvailability.displayedAutoCheck(
                configured: updatesConfigured, stored: autoCheckUpdates
            )
            Toggle(
                L("Automatically check for updates"),
                isOn: display.isEnabled ? $autoCheckUpdates : .constant(display.isOn)
            )
            .toggleStyle(.switch)
            .disabled(!display.isEnabled)

            formNote(display.isEnabled
                ? "settings.updates.description"
                : "updates.unavailable")
        } header: {
            Text(L("Updates"))
        }
    }

    /// Version, the data folder, and one button that turns "it broke" into a
    /// sentence someone can act on.
    ///
    /// In Settings rather than on the status menu because ⌘F already indexes by
    /// section, so one terms array makes this keyboard-findable with no new
    /// machinery — and because reopening the app opens Settings unconditionally
    /// (`MenuBarVisibility`), which is the strongest reachability guarantee in
    /// the app and exactly the one a broken install needs.
    private var diagnosticsSection: some View {
        Section {
            // The app's name as it is shown wherever it stands for itself:
            // "Magpie" and Castor's terracotta asterisk.
            AppNameMark()
                .accessibilityLabel("Magpie")
            LabeledContent(L("settings.diagnostics.version")) {
                Text(appVersionDisplay)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            LabeledContent(L("settings.diagnostics.title")) {
                ControlGroup {
                    Button(L("settings.diagnostics.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
                    }
                    Button(copiedDiagnostics
                        ? L("settings.diagnostics.copied")
                        : L("settings.diagnostics.copy")) {
                        copyDiagnostics()
                    }
                }
                .controlSize(.small)
            }

            // Beside "Reveal data folder" because it is the same subject: the
            // files Magpie itself keeps. ADR 0001 named this affordance as the
            // review trigger for cache-growth pain; the size makes the cache
            // visible at all, and Clear reclaims it without waiting for the
            // budget.
            LabeledContent(L("settings.cache.title")) {
                HStack(spacing: 8) {
                    Text(ShelfItem.format(bytes: cacheBytes))
                        .foregroundStyle(.secondary)
                    Button(L("settings.cache.clear")) {
                        clearManagedCache()
                        cacheBytes = shelfSnapshot().managedCacheBytes
                    }
                    .controlSize(.small)
                    .disabled(cacheBytes == 0)
                }
            }

            formNote("settings.cache.description")

            formNote("settings.diagnostics.description")
        } header: {
            Text(L("settings.diagnostics"))
        }
    }

    private var appVersionDisplay: String {
        Diagnostics.versionDisplay(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// Where Magpie keeps its files. Derived the same way every other path in
    /// the app is, so it cannot drift from the directory actually in use.
    private var dataDirectory: URL {
        StoreLocation.applicationSupportDirectory()
    }

    @MainActor
    private func copyDiagnostics() {
        let snapshot = shelfSnapshot()
        var triggers: [Diagnostics.Trigger] = []
        if triggerShake { triggers.append(.shake) }
        if triggerHotkey { triggers.append(.hotkey) }
        if triggerDragToEdge { triggers.append(.screenEdge) }
        if triggerMenuBarClick { triggers.append(.menuBarClick) }

        let rows = Diagnostics.rows(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Diagnostics.currentArchitecture,
            language: diagnosticsLanguage,
            shelfCount: snapshot.shelfCount,
            itemCount: snapshot.itemCount,
            storeOutcome: snapshot.storeOutcome,
            managedCacheBytes: snapshot.managedCacheBytes,
            routeCount: routeStore.routes.count,
            routeFileHasError: routeStore.parseError != nil,
            secretCount: secretNames.count,
            triggers: triggers,
            agent: agentTarget,
            autoPaste: agentAutoPaste,
            menuBarVisible: showMenuBarIcon,
            updateChecks: !updatesConfigured
                ? .unavailable
                : (autoCheckUpdates ? .automatic : .manual)
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Diagnostics.text(rows), forType: .string)

        copiedDiagnostics = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copiedDiagnostics = false
        }
    }

    /// "system" alone would leave a maintainer unable to reproduce, so the
    /// resolved language goes with it. A BCP-47 tag, never anything personal.
    private var diagnosticsLanguage: String {
        guard pickedLanguage == .system else { return pickedLanguage.rawValue }
        return "system (\(Locale.preferredLanguages.first ?? "unknown"))"
    }

    /// A footnote under a row.
    ///
    /// Deliberately NOT `LabeledContent` with an empty label: that puts the note
    /// in the *value* slot, so a sentence gets squeezed into the narrow
    /// right-hand control column and trailing-aligned. A note is not a value —
    /// it spans the row and reads left to right like every other footnote on
    /// the platform.
    private func formNote(_ key: String) -> some View {
        Text(L(key))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 120 × 0.5s — a minute to walk to System Settings, find Magpie in the
    /// Accessibility list and come back.
    private static let trustWatchAttempts = 120
    private static let trustWatchInterval: UInt64 = 500_000_000

    @MainActor
    private func refreshHarnesses() {
        installedHarnesses = HarnessResolver.installed(locate: HarnessResolver.locate)
        // A target chosen and later uninstalled would leave the picker showing
        // an empty row, because no tag matches the stored value any more.
        if !installedHarnesses.contains(where: { $0.harness == agentTarget }),
           let first = installedHarnesses.first {
            agentTarget = first.harness
        }
    }

    /// Switching it on asks macOS for Accessibility and lets it put up its own
    /// dialog. The answer never comes back from that call — the user grants it
    /// in System Settings, minutes later, in another app — so the toggle waits
    /// for the grant and switches itself back off if it never arrives, rather
    /// than sitting on and silently doing nothing. Whatever it ends up showing,
    /// the send path re-reads the right and refuses without it.
    @MainActor
    private func applyAutoPaste(_ enable: Bool) {
        trustWatch?.cancel()
        trustWatch = nil
        agentAutoPaste = enable
        guard enable, !AgentAccessibility.requestShowingSystemPrompt() else { return }
        trustWatch = Task { @MainActor in
            _ = await AgentSendPolicy.poll(
                attempts: Self.trustWatchAttempts,
                condition: { Task.isCancelled || AgentAccessibility.isGranted },
                wait: { try? await Task.sleep(nanoseconds: Self.trustWatchInterval) }
            )
            // Only ever turns it off, and only if it is still on and still
            // ungranted — a grant that landed, or a second flip of the toggle,
            // both win over this.
            if agentAutoPaste, !AgentAccessibility.isGranted { agentAutoPaste = false }
        }
    }

    private func addSecret() {
        guard let entered = Self.promptForSecret() else { return }
        if SecretStore.set(entered.value, for: entered.name) {
            secretNames = SecretStore.names()
        } else {
            let alert = NSAlert()
            alert.messageText = L("settings.secrets.failed")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }

    /// Name in the clear, value in a secure field. The value is used once, to
    /// write it to the Keychain, and is never read back into the UI.
    private static func promptForSecret() -> (name: String, value: String)? {
        let alert = NSAlert()
        alert.messageText = L("settings.secrets.add")
        alert.informativeText = L("alert.secret.body")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        name.placeholderString = "GEMINI_API_KEY"
        let value = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        container.addSubview(name)
        container.addSubview(value)
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !value.stringValue.isEmpty else { return nil }
        return (trimmedName, value.stringValue)
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enable)
            launchAtLogin = LaunchAtLoginManager.isEnabled
        } catch {
            NSLog("Shelf: launch-at-login toggle failed — \(error)")
            launchAtLogin = LaunchAtLoginManager.isEnabled
            let alert = NSAlert()
            alert.messageText = L("Couldn't Update Login Items")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }
}

/// Writes a LaunchAgent plist to `~/Library/LaunchAgents/` so launchd will
/// start Shelf at the next login. Works for both `.app` bundles (uses
/// `/usr/bin/open -a` so the app activates with the right policy) and raw
/// SwiftPM debug binaries (executes them directly). Toggling off just
/// removes the plist — already-running processes keep running until the
/// user logs out, which is fine because the user is editing settings inside
/// that running process.
enum LaunchAtLoginManager {
    static let label = "com.anneo22.magpie.LaunchAgent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enable: Bool) throws {
        if enable {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        let arguments: [String]
        if let appURL = appBundleURL() {
            // Activation through `open -a` — launchd execs the binary directly
            // otherwise, which doesn't give a `.app` its expected activation
            // policy and would cause a duplicate process.
            arguments = ["/usr/bin/open", "-a", appURL.path]
        } else {
            // Dev / raw executable — launch it directly. Path is captured at
            // toggle time, so if the user later moves the binary they need
            // to re-toggle.
            arguments = [Bundle.main.executablePath ?? CommandLine.arguments[0]]
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private static func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func appBundleURL() -> URL? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? URL(fileURLWithPath: path) : nil
    }
}

/// "Magpie*": the name with the terracotta asterisk, as the app signs itself.
struct AppNameMark: View {
    var body: some View {
        (Text("Magpie") + Text("*").foregroundColor(Design.Brand.terracotta))
            .font(Design.Text.title)
    }
}
