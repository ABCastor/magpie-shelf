import AppKit
import Combine
import Sparkle
import SwiftUI

@main
struct MagpieApp {
    static func main() {
        // Must run before any localized lookup — NSBundle reads
        // AppleLanguages once at first resolution.
        LanguagePreference.applyAtLaunch()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate

        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Optional on purpose: with the menu-bar item hideable, nil is a normal
    /// state, not an impossible one. `NSStatusItem!` encoded a claim that is no
    /// longer true and force-unwrapped at two sites.
    private var statusItem: NSStatusItem?
    private let manager: ShelfManager
    private let flushOnTermination: @MainActor () -> Void
    private let chatCopyWriter: ([ShelfItem]) -> Bool
    private let shakeDetector = ShakeDetector()
    private let hotkeyManager = HotkeyManager()
    private let edgeSummonDetector = EdgeSummonDetector()

    // Which summon triggers are currently live. Kept so a user-defaults
    // change only touches the detector that actually changed — the
    // notification fires for every preference write in the process.
    private var shakeRunning = false
    private var edgeSummonRunning = false
    private var activeHotkeyPreset: HotkeyPreset?
    /// Same bookkeeping for the copy-for-chat shortcut, which is not a summon
    /// trigger but is applied live through the same path.
    private var activeChatHotkeyPreset: ChatHotkeyPreset?

    // One panel per shelf.
    private var panels: [UUID: FloatingPanel<ShelfContainerView>] = [:]
    private var expandedShelfIDs: Set<UUID> = []

    private var summonReleaseGlobalMonitor: Any?
    private var summonReleaseLocalMonitor: Any?
    private var pendingShelfID: UUID?
    private var itemCountOnSummon: Int = 0

    // Shelves summoned mid-drag auto-close when emptied; menu-created shelves don't.
    private var ephemeralShelfIDs: Set<UUID> = []
    private var shelvesCancellable: AnyCancellable?

    // Conversion service — owns all in-progress format conversions.
    private let conversionService = ConversionService()
    private var conversionCompletedCancellable: AnyCancellable?
    private var conversionFailedCancellable: AnyCancellable?

    // OCR service — owns all in-progress OCR jobs.
    private let ocrService = OCRService()
    private var ocrCompletedSearchableCancellable: AnyCancellable?
    private var ocrCompletedExtractedCancellable: AnyCancellable?
    private var ocrFailedCancellable: AnyCancellable?

    // Route service — owns all in-progress route runs. Started only from a
    // menu item the user clicked; see `RouteLauncher`.
    private let routeService = RouteService()
    private var routeCompletedCancellable: AnyCancellable?
    private var routeFailedCancellable: AnyCancellable?

    // Sparkle-driven auto-update — owns SPUStandardUpdaterController.
    private let updateController = UpdateController()

    // Toast presentation.
    private let toastPresenter = ToastPresenter()
    private var duplicateToastCancellable: AnyCancellable?
    private var concealedClipboardToastCancellable: AnyCancellable?
    private var closeRequestedCancellable: AnyCancellable?

    // Settings window (accessory app — created lazily, reused).
    private var settingsWindow: NSWindow?

    // The status menu is popped by hand on right-click, so we keep it here
    // instead of leaving it assigned to the status item (which would swallow
    // the left-click we now use to toggle the shelf).
    private var statusMenu: NSMenu?

    // Hourly check that prunes shelves whose last activity is older than the
    // user's configured retention duration (in @AppStorage as `shelf.expiryDays`).
    private var expiryTimer: Timer?

    // Polls for files that disappeared (e.g. moved to Trash from Finder) so
    // ghost entries vanish from a shelf the user is looking at. Armed only
    // while a panel is on screen — see `updateMissingFileSweep`.
    private var missingFileSweepTimer: Timer?
    private let visibleSweepInterval: TimeInterval = 2.0

    // Inbound `magpie://` links: 10 at once, then one a second. Any web page
    // can fire the scheme in a loop and every accepted link shows a panel, so
    // the bucket is what turns "hundreds of panels" into one toast.
    private var inboundLinkBudget = TokenBucket(capacity: 10, refillPerSecond: 1)
    private var lastInboundRefusalToast: Date?

    private var statusItemIconCancellable: AnyCancellable?

    private lazy var keepAwakeController = KeepAwakeController { [weak self] awake in
        self?.applyStatusIcon(awake: awake)
    }
    private var statusIconAwake = false
    private var dropTargetActive: Bool = false

    // Auto-park (top-right stack) state — populated only when the
    // "shelf.autoParkTopRight" preference is on. We track per-shelf item
    // counts so we only park on the 0→non-empty transition (the first drop
    // after creation), not on every subsequent change.
    private var lastItemCounts: [UUID: Int] = [:]
    private var parkedShelfIDs: Set<UUID> = []
    private var parkedShelfOrder: [UUID] = []
    private let parkMargin: CGFloat = 12
    private let parkSpacing: CGFloat = 12

    // Outside-click watcher: a single global mouse-down monitor that's
    // always installed; the "shelf.closeOnOutsideClick" flag is checked
    // inside the handler so toggling the setting takes effect immediately
    // without needing to install/uninstall the monitor.
    private var outsideClickMonitor: Any?

    override init() {
        let manager = ShelfManager()
        self.manager = manager
        self.flushOnTermination = { manager.flushPendingSave() }
        self.chatCopyWriter = { items in
            ShelfClipboardPayload.write(items: items, to: .general)
        }
        super.init()
    }

    init(
        manager: ShelfManager,
        flushOnTermination: @escaping @MainActor () -> Void,
        chatCopyWriter: @escaping ([ShelfItem]) -> Bool = { items in
            ShelfClipboardPayload.write(items: items, to: .general)
        }
    ) {
        self.manager = manager
        self.flushOnTermination = flushOnTermination
        self.chatCopyWriter = chatCopyWriter
        super.init()
    }

    /// Creates or tears down the menu-bar item to match the preference.
    ///
    /// Idempotent — called at launch and on every user-defaults change, so it
    /// must only act when the desired state differs from the live one.
    ///
    /// Tearing the item down is what actually removes it from the bar:
    /// `isVisible = false` leaves a gap on some macOS versions, and the whole
    /// point is that nothing remains. The way back in is
    /// `applicationShouldHandleReopen` — see `MenuBarVisibility`.
    private func applyMenuBarVisibility() {
        let want = MenuBarVisibility.shouldShowStatusItem(
            preferenceIsVisible: MenuBarVisibility.isVisible
        )
        guard want != (statusItem != nil) else { return }

        if want {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            // Left-click toggles the shelf, right-click opens the menu.
            // Assigning `statusItem.menu` permanently would make every click
            // open the menu, so the button gets an action and the menu is
            // popped by hand.
            if let button = item.button {
                button.target = self
                button.action = #selector(statusItemClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            applyStatusIcon()
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
            }
            statusItem = nil
        }
    }

    private func applyStatusIcon(dropping: Bool? = nil, awake: Bool? = nil) {
        if let dropping { dropTargetActive = dropping }
        if let awake { statusIconAwake = awake }
        guard let button = statusItem?.button else { return }
        button.image = StatusIcon.image(dropping: dropTargetActive, awake: statusIconAwake)
    }

    // Panel geometry has one home: `ShelfLayout`. It used to live here as a
    // hand-written `chrome: CGFloat = 130` plus a second copy of the grid's
    // column arithmetic, which is why every attempt at changing the shelf's
    // rhythm broke the panel height silently.
    private let dockedSize = ShelfLayout.docked
    private let dockedOffscreen = ShelfLayout.dockedOffscreen

    /// The collapsed panel is a strip the height of its own contents, so its
    /// size is a question about a shelf rather than a constant.
    private func collapsedSize(for shelfID: UUID) -> NSSize {
        ShelfLayout.collapsedSize(itemCount: manager.items(of: shelfID).count)
    }

    /// The expanded panel size that hugs this shelf's contents.
    private func expandedSize(for shelfID: UUID) -> NSSize {
        ShelfLayout.expandedSize(itemCount: manager.items(of: shelfID).count)
    }

    /// The panel a shelf should be wearing right now, in whichever state it is
    /// in. Docked panels are a fixed tab and are left alone.
    private func panelSize(for shelfID: UUID) -> NSSize {
        expandedShelfIDs.contains(shelfID)
            ? expandedSize(for: shelfID)
            : collapsedSize(for: shelfID)
    }

    /// A strip sized to its contents has to follow them. Every add, remove and
    /// undo changes how tall a collapsed shelf should be, and the panel is an
    /// AppKit window that will not notice on its own.
    ///
    /// Top edge and horizontal centre are held, so the strip grows downwards
    /// from where the user put it rather than jumping. Docked panels, expanded
    /// panels and a shelf being dragged are left where they are: a window that
    /// resizes under an in-flight drag is a window that loses the drag.
    private func syncCollapsedPanelSizes() {
        guard !manager.isDragging else { return }
        for (shelfID, panel) in panels {
            guard panel.isVisible,
                  !dockedShelfIDs.contains(shelfID),
                  !expandedShelfIDs.contains(shelfID)
            else { continue }
            let size = collapsedSize(for: shelfID)
            guard abs(panel.frame.height - size.height) > 0.5
                    || abs(panel.frame.width - size.width) > 0.5
            else { continue }
            let frame = NSRect(
                x: panel.frame.midX - size.width / 2,
                y: panel.frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
            animate(panel: panel, to: frame)
        }
    }

    // Docked-to-edge state.
    private var dockedShelfIDs: Set<UUID> = []
    private var preDockFrames: [UUID: NSRect] = [:]
    private var dockedFrames: [UUID: NSRect] = [:]
    private var windowMoveObserver: NSObjectProtocol?
    private var suppressMoveCheck = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window exists, so the first shelf is summoned already in
        // the right appearance rather than repainting once Settings is opened.
        AppearancePreference.apply(AppearancePreference.current)

        // One registration, shared with the values Settings displays. The
        // expiry default in particular is displayed by the Settings picker and
        // executed by `runShelfExpiryPrune`, and until they shared this one
        // registered value they disagreed on every fresh install.
        DefaultPreferences.register()

        statusMenu = NSMenu()
        // The status menu's key equivalents fire only while that menu is open;
        // app-wide they fire through the main menu, which an accessory app
        // never draws but AppKit still consults. See `MainMenu`.
        NSApp.mainMenu = MainMenu.build(delegate: self)
        // Creates the status item, or not, per the preference. Must run AFTER
        // `statusMenu` exists, because a right-click on the button pops it.
        applyMenuBarVisibility()
        // Flip the glyph while any panel is being targeted by a drop so the
        // menubar mirrors the "ready to receive" state visually.
        statusItemIconCancellable = manager.$isAnyShelfDropTarget
            .removeDuplicates()
            .sink { [weak self] dropping in
                self?.applyStatusIcon(dropping: dropping)
            }

        shakeDetector.onShake = { [weak self] dragging in
            self?.summonShelfAtCursor(dragging: dragging)
        }
        hotkeyManager.onTrigger = { [weak self] action, dragging in
            switch action {
            case .summonShelf: self?.summonShelfAtCursor(dragging: dragging)
            case .copyForChat: self?.copyShelfForChat()
            }
        }
        edgeSummonDetector.onTrigger = { [weak self] dragging in
            self?.summonShelfAtCursor(dragging: dragging)
        }
        applyTriggerPreferences()
        // Settings writes straight to user defaults, so mirror every change
        // back onto the detectors instead of waiting for a relaunch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDefaultsChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        QuickLookController.shared.urlsProvider = { [weak self] in
            self?.urlsForKeyPanel() ?? []
        }

        HandoffCoordinator.shared.onToast = { [weak self] message in
            self?.showToast(message)
        }

        // A drag the source refused because nothing was reachable, or a ⌘-move
        // the destination answered with a copy; this is the only place that can
        // say either one to the user.
        DragToast.handler = { [weak self] notice, window in
            self?.showDragToast(notice, near: window)
        }

        DragBin.handler = { [weak self] urls, window in
            self?.binDraggedFiles(urls, from: window)
        }

        installPasteShortcut()

        shelvesCancellable = manager.$shelves
            .sink { [weak self] shelves in
                self?.reconcileEmptyEphemeralShelves(shelves)
                self?.syncCollapsedPanelSizes()
                self?.checkAutoPark(shelves)
            }

        installOutsideClickWatcher()

        duplicateToastCancellable = manager.duplicateRejected
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] shelfID in
                self?.showDuplicateToast(for: shelfID)
            }

        // A shelf a drag out emptied, asking to be dismissed because the user
        // switched that on. Answered here because panels live here — and
        // through `hidePanel`, the same call the ✕ button and ⌘W make, which
        // also tears an empty shelf down rather than leaving a zombie in
        // Recent Shelves.
        //
        // A runloop hop, because the removal that emptied the shelf is still
        // inside a SwiftUI update when this fires; closing the window out from
        // under that is how a view ends up reading a shelf that no longer
        // exists.
        closeRequestedCancellable = manager.closeRequested
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shelfID in
                self?.hidePanel(for: shelfID)
            }

        concealedClipboardToastCancellable = manager.concealedClipboardRejected
            // "New Shelf From Clipboard" imports before it opens the panel,
            // so hop a runloop turn and let the panel exist first.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shelfID in
                self?.showConcealedClipboardToast(for: shelfID)
            }

        conversionCompletedCancellable = conversionService.completed
            .sink { [weak self] (url, shelfID) in
                guard let self else { return }
                self.manager.addFile(url: url, to: shelfID)
            }

        conversionFailedCancellable = conversionService.failed
            .sink { [weak self] error in
                // .cancelled is silent — the user initiated it, no toast needed.
                guard error != .cancelled else { return }
                self?.showConversionFailureToast(message: error.displayMessage)
            }

        ocrCompletedSearchableCancellable = ocrService.completedSearchable
            .sink { [weak self] (url, shelfID) in
                self?.manager.addFile(url: url, to: shelfID)
            }

        ocrCompletedExtractedCancellable = ocrService.completedExtracted
            .sink { [weak self] (text, shelfID) in
                self?.manager.addText(text, to: shelfID)
            }

        ocrFailedCancellable = ocrService.failed
            .sink { [weak self] error in
                guard error != .cancelled else { return }
                self?.showConversionFailureToast(message: error.displayMessage)
            }

        routeCompletedCancellable = routeService.completed
            .sink { [weak self] (success, shelfID) in
                guard let self else { return }
                // Whatever the command left in its output folder becomes a
                // card. Nothing it read was touched.
                for url in success.producedFiles {
                    self.manager.addFile(url: url, to: shelfID)
                }
                self.showToast(
                    String(format: L("routes.finished"), success.routeName),
                    symbol: "checkmark.circle.fill"
                )
            }

        routeFailedCancellable = routeService.failed
            .sink { failure in
                // An alert, not a toast: the stderr tail is the point, and a
                // 2.5-second banner cannot carry one.
                presentRouteFailure(failure)
            }

        runShelfExpiryPrune()
        expiryTimer = Timer.scheduledTimer(
            withTimeInterval: 3600, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.runShelfExpiryPrune() }
        }

        // Sweep stale entries (files trashed from Finder while we were idle).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppOrFocusChange),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        manager.pruneMissingFiles()
        updateMissingFileSweep()

        // Last, and a runloop turn later, so the app is fully up before a modal
        // alert takes over: this is the only thing in Magpie that can stop the
        // launch dead, and it should never be what launch is waiting on.
        DispatchQueue.main.async { [weak self] in
            self?.presentStoreOutcomeIfNeeded()
        }
    }

    /// Says out loud what the store load found.
    ///
    /// The store has always detected a corrupt file and a newer-schema file and
    /// then said nothing at all, which is how a user ends up reporting "every
    /// shelf vanished one morning" with nothing else to add. An alert rather
    /// than a toast for the same reason `presentRouteFailure` is one: a
    /// 2.5-second banner cannot carry the sentence, and this one has to survive
    /// being read twice.
    ///
    /// `StoreOutcomeNotice` is what stops it becoming a nag — see the reasoning
    /// there; `readOnlyNewerSchema` is permanent, so "warn every launch" would
    /// mean warning at every login until the user reinstalls.
    private func presentStoreOutcomeIfNeeded() {
        let outcome = manager.loadOutcome
        let defaults = UserDefaults.standard
        let lastReported = defaults.string(forKey: StoreOutcomeNotice.defaultsKey)
        guard StoreOutcomeNotice.shouldPresent(outcome, lastReported: lastReported) else {
            // A store that came back healthy forgets, so a real failure later is
            // heard rather than swallowed as "already reported".
            if case .healthy = outcome {
                defaults.removeObject(forKey: StoreOutcomeNotice.defaultsKey)
            }
            return
        }
        defaults.set(
            StoreOutcomeNotice.signature(for: outcome),
            forKey: StoreOutcomeNotice.defaultsKey
        )

        let alert = NSAlert()
        alert.alertStyle = .warning
        var preservedFile: URL?
        switch outcome {
        case .healthy:
            return
        case .quarantined(let url):
            preservedFile = url
            alert.messageText = L("store.alert.quarantined.title")
            alert.informativeText = L("store.alert.quarantined.body")
        case .readOnlyNewerSchema:
            alert.messageText = L("store.alert.read-only.title")
            alert.informativeText = L("store.alert.read-only.body")
        case .unreadable:
            alert.messageText = L("store.alert.unreadable.title")
            alert.informativeText = L("store.alert.unreadable.body")
        }

        if preservedFile != nil {
            // Default button, so Return reveals the file the user is being told
            // about, and Escape, wired by hand below, dismisses. Both paths are
            // on the keyboard; neither needs the mouse.
            alert.addButton(withTitle: L("Show in Finder"))
            alert.addButton(withTitle: L("OK")).keyEquivalent = "\u{1b}"
        } else {
            alert.addButton(withTitle: L("OK"))
        }

        // Accessory app with no dock icon: without this the alert can come up
        // behind whatever the user is already looking at.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if let preservedFile, response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([preservedFile])
        }
    }

    @objc private func handleAppOrFocusChange() {
        manager.pruneMissingFiles()
    }

    /// A ghost entry is only a defect where it can be seen, so the sweep runs
    /// while a panel is on screen and not at all otherwise: `openPanel` sweeps
    /// before a shelf is drawn, `popStatusMenu` before Recent Shelves is built,
    /// and app activation covers the rest. That is what stops an idle app from
    /// republishing its model — and rewriting `shelf.json` — around the clock.
    private func updateMissingFileSweep() {
        guard panels.values.contains(where: { $0.isVisible }) else {
            missingFileSweepTimer?.invalidate()
            missingFileSweepTimer = nil
            return
        }
        guard missingFileSweepTimer == nil else { return }
        missingFileSweepTimer = Timer.scheduledTimer(
            withTimeInterval: visibleSweepInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.sweepMissingFiles() }
        }
    }

    private func sweepMissingFiles() {
        manager.pruneMissingFiles()
        // Panels can be ordered out from paths that do not funnel through
        // `hidePanel`, so the tick that finds an empty screen is also the one
        // that stops the timer.
        updateMissingFileSweep()
    }

    // MARK: - Summon triggers

    @objc nonisolated private func handleDefaultsChange() {
        // Posted on whichever thread wrote the value; hop to the main actor
        // before touching the detectors.
        Task { @MainActor in
            self.applyTriggerPreferences()
            self.applyMenuBarVisibility()
        }
    }

    /// THE ESCAPE HATCH. With the menu-bar item hidden and no dock icon, this
    /// is the only way back into Settings — and therefore the only way to turn
    /// the icon back on or to quit. Launching Magpie again from Applications,
    /// Spotlight or `open -a Magpie` lands here.
    ///
    /// AppKit calls this for an already-running app even when it owns no
    /// windows, which is the case that matters for an `LSUIElement` accessory.
    /// Returning `false` tells AppKit not to do its own un-hiding on top.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if MenuBarVisibility.reopenShouldOpenSettings() {
            openSettingsAction()
        }
        return false
    }

    /// Starts/stops each detector to match the `shelf.trigger.*` preferences,
    /// plus the copy-for-chat hotkey, which is not a summon trigger but is
    /// applied live the same way. Idempotent — called on every user-defaults
    /// change, so it must only act when a desired state actually differs from
    /// the live one.
    private func applyTriggerPreferences() {
        let defaults = UserDefaults.standard

        let wantShake = defaults.bool(forKey: "shelf.trigger.shake")
        if wantShake != shakeRunning {
            if wantShake { shakeDetector.start() } else { shakeDetector.stop() }
            shakeRunning = wantShake
        }

        edgeSummonDetector.edge =
            SummonEdge(rawValue: defaults.string(forKey: "shelf.trigger.edge") ?? "") ?? .right
        let wantEdge = defaults.bool(forKey: "shelf.trigger.dragToEdge")
        if wantEdge != edgeSummonRunning {
            if wantEdge { edgeSummonDetector.start() } else { edgeSummonDetector.stop() }
            edgeSummonRunning = wantEdge
        }

        let wantPreset: HotkeyPreset? = defaults.bool(forKey: "shelf.trigger.hotkey")
            ? HotkeyPreset(rawValue: defaults.string(forKey: "shelf.trigger.hotkeyPreset") ?? "")
                ?? .optionShiftS
            : nil
        if wantPreset != activeHotkeyPreset {
            activeHotkeyPreset = wantPreset
            if let wantPreset {
                if !hotkeyManager.start(.summonShelf, preset: wantPreset) {
                    showToast(
                        String(format: L("toast.hotkey-unavailable"), wantPreset.displayName)
                    )
                }
            } else {
                hotkeyManager.stop(.summonShelf)
            }
        }

        // Copy-for-chat. Registered on the same manager under its own action,
        // so the two hotkeys coexist; toggling one never disturbs the other.
        let wantChatPreset: ChatHotkeyPreset? = defaults.bool(forKey: "shelf.chatCopy.hotkey")
            ? ChatHotkeyPreset(rawValue: defaults.string(forKey: "shelf.chatCopy.hotkeyPreset") ?? "")
                ?? .optionShiftC
            : nil
        if wantChatPreset != activeChatHotkeyPreset {
            activeChatHotkeyPreset = wantChatPreset
            if let wantChatPreset {
                if !hotkeyManager.start(.copyForChat, preset: wantChatPreset) {
                    showToast(
                        String(format: L("toast.hotkey-unavailable"), wantChatPreset.displayName)
                    )
                }
            } else {
                hotkeyManager.stop(.copyForChat)
            }
        }
    }

    // MARK: - Copy for chat

    /// The point of this shortcut is that it works where Cmd-C cannot: the
    /// user is in a chat composer, no Magpie panel is key, and an accessory
    /// app is not in the Cmd-Tab switcher. It therefore takes no strip
    /// selection and asks for no focused panel — it copies the resolved shelf.
    /// The resolved shelf is still chosen by the existing frontmost/current
    /// fallback below; only the subject within that shelf is settled here.
    func copyShelfForChat() {
        // The whole precondition for this shortcut is that NO Magpie panel is
        // key because the user is typing in a chat, so the fallbacks below are
        // what actually decide, every time. `panels` is a Dictionary whose iteration
        // order is randomly seeded per process, so "first visible" would copy
        // an arbitrary shelf whenever more than one is on screen, and parked
        // stacks make that a designed state rather than an edge case.
        let shelfID = panels.first(where: { $0.value.isKeyWindow })?.key
            ?? frontmostVisibleShelfID()
            ?? manager.currentShelfID
            ?? manager.shelves.last?.id

        guard let shelfID,
              chatCopyWriter(ShelfChatCopy.items(for: manager, shelfID: shelfID))
        else {
            showToast(L("toast.chat-copy-empty"))
            return
        }

        // The copy above already happened, so every branch below leaves the
        // shelf on the clipboard and one ⌘V away — a failed paste costs the
        // user nothing they did not already have.
        switch agentSendPlan() {
        case .copyOnly:
            showToast(L("toast.chat-copied"), symbol: "checkmark.circle.fill")
        case .targetMissing(let harness):
            showToast(String(format: L("agent.toast.not-installed"), harness.displayName))
        case .permissionMissing:
            showToast(L("agent.toast.no-accessibility"))
        case .paste(let target):
            pasteShelfIntoAgent(target)
        }
    }

    /// Reads the two `shelf.agentSend.*` preferences and resolves the target.
    /// The decision itself stays in `AgentSendPolicy`, which is pure and
    /// tested; this only gathers the three facts it needs.
    ///
    /// Nothing is resolved while the toggle is off: the shortcut fires many
    /// times a day in that state, and neither a LaunchServices lookup nor an
    /// Accessibility read should be on that path.
    private func agentSendPlan() -> AgentSendPlan {
        let defaults = UserDefaults.standard
        // Off unless the user turned it on. The key is deliberately absent
        // from `register(defaults:)`, so an unset key reading false is the
        // right answer rather than a lucky one.
        let enabled = defaults.bool(forKey: "shelf.agentSend.autoPaste")
        let target = AgentHarness(rawValue: defaults.string(forKey: "shelf.agentSend.target") ?? "")
            ?? .claudeCode
        return AgentSendPolicy.plan(
            autoPasteEnabled: enabled,
            target: target,
            installed: enabled
                ? HarnessResolver.resolve(target, locate: HarnessResolver.locate)
                : nil,
            accessibilityTrusted: enabled && AgentAccessibility.isGranted
        )
    }

    /// The only call site of the only thing in Magpie that types. Reached from
    /// the copy-for-chat shortcut the user pressed and from nowhere else —
    /// `AgentSendInvariantTests` reads this file and fails if that stops being
    /// true.
    private func pasteShelfIntoAgent(_ target: InstalledHarness) {
        Task { @MainActor in
            switch await AgentPasteSender.send(to: target) {
            case .pasted:
                showToast(
                    String(format: L("agent.toast.pasted"), target.displayName),
                    symbol: "checkmark.circle.fill"
                )
            case .notTrusted:
                showToast(L("agent.toast.no-accessibility"))
            case .couldNotPaste:
                showToast(String(format: L("agent.toast.could-not-paste"), target.displayName))
            case .modifiersHeld:
                showToast(L("agent.toast.modifiers-held"))
            }
        }
    }

    /// The visible shelf the user most plausibly means, resolved deterministically.
    /// Prefers the last-opened shelf when it is still on screen; otherwise walks
    /// `NSApp.orderedWindows`, which is front-to-back z-order, so "the one in
    /// front" is decided by what the user can actually see rather than by hash
    /// order.
    private func frontmostVisibleShelfID() -> UUID? {
        if let current = manager.currentShelfID, panels[current]?.isVisible == true {
            return current
        }
        for window in NSApp.orderedWindows {
            if let match = panels.first(where: { $0.value === window && $0.value.isVisible }) {
                return match.key
            }
        }
        return nil
    }

    @objc private func statusItemClicked() {
        // Control-click is macOS's right-click equivalent, so both open the
        // menu. A plain left-click toggles the shelf unless that trigger is off.
        // Anything that is not a mouse-up — keyboard activation via Control-F8,
        // VoiceOver, or no current event at all — also opens the menu: it is
        // the only route to Settings, Check for Updates and Quit, so leaving it
        // mouse-only would strand a keyboard user with no way in.
        let event = NSApp.currentEvent
        let isMouseUp = event?.type == .leftMouseUp || event?.type == .rightMouseUp
        let wantsMenu = !isMouseUp
            || event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        guard !wantsMenu,
              UserDefaults.standard.bool(forKey: "shelf.trigger.menuBarClick")
        else {
            popStatusMenu()
            return
        }
        toggleShelfFromMenuBar()
    }

    private func popStatusMenu() {
        guard let statusMenu, let button = statusItem?.button else { return }
        // `statusItem.menu` stays unassigned — assigning it is what would make
        // every click open the menu — so the menu is built and shown by hand.
        // That replaces the old `menuNeedsUpdate` delegate hop, which rebuilt
        // asynchronously while AppKit was already displaying the menu.
        // `popUp` runs modally until dismissed and never re-sends the button
        // action, so there is no way back into `statusItemClicked` from here.
        // The origin is the button's bottom-left (the view is not flipped),
        // which drops the menu directly beneath the icon.
        //
        // Recent Shelves is built from item names and counts, so it gets the
        // same sweep a panel gets before it is drawn.
        manager.pruneMissingFiles()
        rebuildStatusMenu(statusMenu)
        button.highlight(true)
        statusMenu.popUp(positioning: nil, at: .zero, in: button)
        button.highlight(false)
    }

    private func toggleShelfFromMenuBar() {
        let visible = panels.filter { $0.value.isVisible }
        guard visible.isEmpty else {
            for shelfID in visible.keys { hidePanel(for: shelfID) }
            return
        }
        // Bring back the most recent shelf that still holds something, else the
        // most recent shelf at all, else start a fresh one like New Shelf does.
        if let shelf = manager.shelves.last(where: { !$0.items.isEmpty }) ?? manager.shelves.last {
            openPanel(for: shelf.id, nearCursor: false)
        } else {
            newShelfAction()
        }
    }

    private func runShelfExpiryPrune() {
        let days = UserDefaults.standard.integer(forKey: ShelfExpiry.defaultsKey)
        guard days > 0 else { return }
        let removed = manager.pruneShelves(olderThanDays: days)
        for shelfID in removed {
            panels[shelfID]?.orderOut(nil)
            panels.removeValue(forKey: shelfID)
            ephemeralShelfIDs.remove(shelfID)
        }
        if manager.shelves.isEmpty {
            _ = manager.createShelf()
        }
    }

    /// What Quick Look previews: the space bar, ⌘Y and the menu's Quick Look row
    /// all end up here.
    ///
    /// **It is the pick, not the shelf.** It used to be `items(of:)`, so a strip
    /// narrowed to one row still opened a five-file preview — the same lie the
    /// strip's context menu was telling, without the user's files at stake. The
    /// answer comes through `carriedItemsOnStrip`, which resolves the pick the
    /// visible strip published with `ShelfSelection.effective`, so an untouched
    /// shelf previews all of itself exactly as before.
    private func urlsForKeyPanel() -> [URL] {
        guard let (shelfID, _) = panels.first(where: { $0.value.isKeyWindow })
                ?? panels.first(where: { $0.value.isVisible })
        else { return [] }
        return manager.carriedItemsOnStrip(of: shelfID).compactMap { $0.fileURL }
    }

    // MARK: - Status menu

    func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let keepAwake = NSMenuItem(
            title: L("Keep Mac Awake"),
            action: #selector(toggleKeepAwakeAction),
            keyEquivalent: ""
        )
        keepAwake.target = self
        keepAwake.state = keepAwakeController.isAwake ? .on : .off
        menu.addItem(keepAwake)

        let activateFor = NSMenuItem(title: L("Activate for"), action: nil, keyEquivalent: "")
        activateFor.submenu = buildKeepAwakeDurationsMenu()
        menu.addItem(activateFor)

        menu.addItem(.separator())

        let newShelf = NSMenuItem(
            title: L("New Shelf"),
            action: #selector(newShelfAction),
            keyEquivalent: "n"
        )
        newShelf.target = self
        newShelf.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(newShelf)

        let newFromClip = NSMenuItem(
            title: L("New Shelf From Clipboard"),
            action: #selector(newShelfFromClipboardAction),
            keyEquivalent: "a"
        )
        newFromClip.target = self
        newFromClip.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(newFromClip)

        let recent = NSMenuItem(title: L("Recent Shelves"), action: nil, keyEquivalent: "")
        recent.submenu = buildRecentShelvesMenu()
        menu.addItem(recent)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: L("Settings…"),
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        // Wire the menu item directly to SPUStandardUpdaterController so AppKit's
        // responder chain calls its `validateMenuItem(_:)` — the item auto-grays
        // out while a check or download is already in flight.
        let checkUpdates = NSMenuItem(
            title: L("Check for Updates…"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = updateController.updaterController
        // A build with no Sparkle key cannot check. Offering the row anyway is
        // how the "updater failed to start" alert got in front of the user in
        // the first place; a greyed row that says why is the honest version.
        if !updateController.isAvailable {
            checkUpdates.action = nil
            checkUpdates.target = nil
            checkUpdates.isEnabled = false
            checkUpdates.toolTip = L("updates.unavailable")
        }
        menu.addItem(checkUpdates)

        let quit = NSMenuItem(
            title: L("Quit"),
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    @objc private func toggleKeepAwakeAction() {
        keepAwakeController.setAwake(!keepAwakeController.isAwake)
    }

    @objc private func keepAwakeForAction(_ sender: NSMenuItem) {
        // representedObject carries the duration in seconds; nil = indefinite.
        let duration = sender.representedObject as? TimeInterval
        keepAwakeController.setAwake(true, duration: duration)
    }

    private func buildKeepAwakeDurationsMenu() -> NSMenu {
        let submenu = NSMenu()
        // (title, duration in seconds; nil = indefinite)
        let options: [(String, TimeInterval?)] = [
            (L("Indefinitely"), nil),
            (L("5 minutes"),  5 * 60),
            (L("10 minutes"), 10 * 60),
            (L("15 minutes"), 15 * 60),
            (L("20 minutes"), 20 * 60),
            (L("1 hour"),     60 * 60),
            (L("2 hours"),    2 * 60 * 60),
            (L("3 hours"),    3 * 60 * 60),
            (L("5 hours"),    5 * 60 * 60),
        ]
        for (title, duration) in options {
            let item = NSMenuItem(
                title: title,
                action: #selector(keepAwakeForAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = duration
            // Tick the row that matches the current state. "Indefinitely"
            // matches when keep-awake is on with no auto-off timer.
            if keepAwakeController.isAwake, duration == keepAwakeController.duration {
                item.state = .on
            }
            submenu.addItem(item)
        }
        return submenu
    }

    @objc func openSettingsAction() {
        if settingsWindow == nil {
            // The closure, not the numbers: a Settings window lives for as long
            // as the app does, so a snapshot taken here would be the counts from
            // whenever it was first opened.
            let manager = self.manager
            let hosting = NSHostingController(rootView: SettingsView(
                shelfSnapshot: {
                    Diagnostics.ShelfSnapshot(
                        shelfCount: manager.shelves.count,
                        itemCount: manager.shelves.reduce(0) { $0 + $1.items.count },
                        storeOutcome: manager.loadOutcome,
                        managedCacheBytes: manager.managedCacheBytes()
                    )
                },
                clearManagedCache: { manager.clearManagedCache() }
            ))
            let window = NSWindow(contentViewController: hosting)
            // Set once at creation; the title doesn't refresh on language
            // change. Pre-existing accepted limitation from v1.4.
            window.title = L("Magpie Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // Accessory app: temporarily bring to front so the window receives focus.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildRecentShelvesMenu() -> NSMenu {
        let submenu = NSMenu()

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true

        // Pinned shelves float to the top; remaining shelves stay in
        // most-recent-first order (the tail of the array is newest).
        let nonEmpty = manager.shelves.filter { !$0.items.isEmpty }
        let pinned = nonEmpty.filter { $0.pinned }.reversed()
        let rest = nonEmpty.filter { !$0.pinned }.reversed()
        let ordered = Array(pinned) + Array(rest)

        var shown = 0
        for shelf in ordered {
            shown += 1
            let item = NSMenuItem(
                title: "",
                action: #selector(openShelfAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = shelf.id

            let title: String
            if let n = shelf.name, !n.isEmpty {
                title = n
            } else if shelf.items.count == 1 {
                title = shelf.items[0].displayName
            } else {
                title = String(format: L("%lld Files"), shelf.items.count)
            }
            var subtitle = formatter.string(from: shelf.createdAt)
            if shelf.name?.isEmpty == false {
                let count = shelf.items.count == 1
                    ? L("1 file")
                    : String(format: L("%lld files"), shelf.items.count)
                subtitle = "\(count) · \(subtitle)"
            }

            let attr = NSMutableAttributedString()
            if shelf.pinned {
                let pin = NSTextAttachment()
                pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
                attr.append(NSAttributedString(attachment: pin))
                attr.append(NSAttributedString(string: " "))
            }
            attr.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
            attr.append(NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = attr

            if let accentImage = recentMenuIcon(for: shelf) {
                item.image = accentImage
            } else if let first = shelf.items.first, let url = first.fileURL {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 28, height: 28)
                item.image = icon
            }
            submenu.addItem(item)
        }

        if shown == 0 {
            let empty = NSMenuItem(title: L("No Recent Shelves"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            submenu.addItem(.separator())
            let clear = NSMenuItem(
                title: L("Clear Recent Shelves"),
                action: #selector(clearAllShelvesAction),
                keyEquivalent: ""
            )
            clear.target = self
            submenu.addItem(clear)
        }

        return submenu
    }

    /// When the shelf has an accent (color or emoji), render a 28×28 swatch
    /// for the menu item icon so the accent dominates the visual identity.
    /// Returns nil when no accent is set, letting the caller fall back to
    /// the file icon.
    private func recentMenuIcon(for shelf: Shelf) -> NSImage? {
        guard let accent = shelf.accent else { return nil }
        let size = NSSize(width: 28, height: 28)
        switch accent {
        case .color(let hex):
            return NSImage(size: size, flipped: false) { rect in
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
                (NSColor(hex: hex) ?? .systemGray).setFill()
                path.fill()
                NSColor.black.withAlphaComponent(0.15).setStroke()
                path.lineWidth = 0.5
                path.stroke()
                return true
            }
        case .emoji(let glyph):
            return NSImage(size: size, flipped: false) { rect in
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 18)
                ]
                let s = (glyph as NSString)
                let measured = s.size(withAttributes: attrs)
                let origin = NSPoint(
                    x: rect.midX - measured.width / 2,
                    y: rect.midY - measured.height / 2
                )
                s.draw(at: origin, withAttributes: attrs)
                return true
            }
        }
    }

    @objc func newShelfAction() {
        let shelfID = manager.createShelf()
        openPanel(for: shelfID, nearCursor: false)
    }

    @objc func newShelfFromClipboardAction() {
        let shelfID = manager.createShelf()
        _ = manager.addFromClipboard(to: shelfID)
        openPanel(for: shelfID, nearCursor: false)
    }

    @objc private func openShelfAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openPanel(for: id, nearCursor: false)
    }

    @objc private func clearAllShelvesAction() {
        // Pinned shelves are deliberately preserved — the pin is the user's
        // signal to keep that shelf around regardless of cleanup actions, and
        // matches the auto-expiry behavior (which also skips pinned shelves).
        let doomed = manager.shelves.filter { !$0.pinned }
        guard !doomed.isEmpty else { return }
        guard confirmClearAllShelves(
            shelfCount: doomed.count,
            itemCount: doomed.reduce(0) { $0 + $1.items.count }
        ) else { return }
        for id in manager.clearAllUnpinnedShelvesUndoably() {
            panels[id]?.orderOut(nil)
            panels.removeValue(forKey: id)
            ephemeralShelfIDs.remove(id)
        }
        if manager.shelves.isEmpty {
            _ = manager.createShelf()
        }
    }

    /// The one bulk-destructive action in the app, so it says what it is
    /// about to do before doing it. Keyboard-first: Return keeps everything
    /// (the safe choice is the default button), ⌘Return clears.
    private func confirmClearAllShelves(shelfCount: Int, itemCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("alert.clear-all.title")
        alert.informativeText = ClearAllShelvesConfirmation.summary(
            shelfCount: shelfCount, itemCount: itemCount
        )
        alert.alertStyle = .warning
        // First button = default = Return = keep everything.
        alert.addButton(withTitle: L("Cancel"))
        let clear = alert.addButton(withTitle: L("Clear Recent Shelves"))
        clear.keyEquivalent = "\r"
        clear.keyEquivalentModifierMask = .command
        clear.hasDestructiveAction = true
        // The app is an LSUIElement accessory: without activation the alert
        // can appear behind the frontmost app's windows and never take keys.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Summon

    /// Shared entry point for every summon trigger (shake, hotkey, screen edge).
    ///
    /// Summoned mid-drag the shelf is ephemeral: the release watcher tears it
    /// down when the drag ends with nothing on it, so a false positive leaves
    /// nothing behind. Summoned with no button held (hotkey pressed while not
    /// dragging) it behaves like a menu-created shelf and stays put.
    /// `dragging` is sampled by the detector at detection time, not re-read
    /// here: the callbacks hop through main, and a user who releases in that
    /// window would otherwise get a non-ephemeral shelf with no release
    /// watcher — a permanent empty panel instead of a self-cleaning one.
    private func summonShelfAtCursor(dragging: Bool) {
        // Ignore further triggers while a summoned shelf is still pending.
        // Otherwise rapid triggers pile up panels and only the latest one's
        // release watcher survives, leaving earlier empties on screen.
        if let pending = pendingShelfID,
           let panel = panels[pending], panel.isVisible {
            return
        }
        let shelfID = manager.createShelf()
        if dragging {
            // Must precede openPanel — makePanel reads the ephemeral flag when
            // it builds the view.
            ephemeralShelfIDs.insert(shelfID)
            pendingShelfID = shelfID
            itemCountOnSummon = 0
        }
        openPanel(for: shelfID, nearCursor: true)
        if dragging { armSummonReleaseWatcher(for: shelfID) }
    }

    private func armSummonReleaseWatcher(for shelfID: UUID) {
        disarmSummonReleaseWatcher()

        let handle: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            self.disarmSummonReleaseWatcher()
            // Drop handlers run asynchronously after mouseUp — NSItemProvider
            // load + temp-file write + MainActor hop. 1.2s gives the chain
            // time to land before we decide whether to close the shelf.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                if self.manager.items(of: shelfID).count == self.itemCountOnSummon,
                   let panel = self.panels[shelfID], panel.isVisible {
                    panel.orderOut(nil)
                    self.manager.removeShelf(id: shelfID)
                    self.panels.removeValue(forKey: shelfID)
                    self.ephemeralShelfIDs.remove(shelfID)
                }
                self.pendingShelfID = nil
            }
        }

        summonReleaseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp
        ) { event in
            handle(event)
        }
        summonReleaseLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseUp
        ) { event in
            handle(event)
            return event
        }
    }

    private func reconcileEmptyEphemeralShelves(_ shelves: [Shelf]) {
        let existingIDs = Set(shelves.map { $0.id })

        // Drop tracking for shelves that no longer exist.
        ephemeralShelfIDs.formIntersection(existingIDs)
        dockedShelfIDs.formIntersection(existingIDs)
        preDockFrames = preDockFrames.filter { existingIDs.contains($0.key) }
    }

    private func disarmSummonReleaseWatcher() {
        if let m = summonReleaseGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = summonReleaseLocalMonitor { NSEvent.removeMonitor(m) }
        summonReleaseGlobalMonitor = nil
        summonReleaseLocalMonitor = nil
    }

    // MARK: - Inbound links

    /// SECURITY INVARIANT — any web page the user visits can fire `magpie://`
    /// from a link, an iframe or a redirect, so this is an attacker-reachable
    /// entry point and is bounded on purpose: an inbound URL may only ever
    /// cause `manager.addFile` and `openPanel`. It must never run a route, a
    /// script, a shell command, a conversion, an OCR job or any other action,
    /// now or later — the moment a URL can act, a registered scheme becomes a
    /// drive-by execution surface. A future "run a route" feature gets a menu
    /// item, not a URL verb. The grammar and every rejection live in
    /// `MagpieURL`, which is pure and tested; this stays trivially thin.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { addFiles(from: url) }
    }

    private func addFiles(from url: URL) {
        let now = Date()
        // Spent before the URL is even parsed, so a flood costs nothing at all
        // — the same reason `MagpieURL` counts paths before touching disk.
        guard inboundLinkBudget.take(now: now) else {
            // One toast per burst, not one per refused link: a toast per link
            // is the same denial of service wearing a different hat.
            if lastInboundRefusalToast.map({ now.timeIntervalSince($0) >= 5 }) ?? true {
                lastInboundRefusalToast = now
                showToast(L("toast.link-rate-limited"))
            }
            NSLog("Magpie: refused an inbound link — too many in too little time")
            return
        }
        switch MagpieURL.parse(url) {
        case .failure(let rejection):
            // A refused link is not a no-op: silence here is indistinguishable
            // from a broken app, and the CLI wrapper has no other way to report.
            NSLog("Magpie: refused an inbound link — \(rejection.logDescription)")
            showToast(L("toast.link-refused"))
        case .success(let request):
            // The named shelf if it still exists, else the one the user is on,
            // else the most recent, else a fresh one.
            let shelfID = [request.shelfID, manager.currentShelfID, manager.shelves.last?.id]
                .compactMap { $0 }
                .first { manager.shelf(id: $0) != nil }
                ?? manager.createShelf()
            for path in request.paths {
                // The only ingest path — copy-in, dedupe, UTType sniff, thumbnail.
                manager.addFile(url: path, to: shelfID)
            }
            guard panels[shelfID]?.isVisible != true else {
                // Already on screen, so repeat links targeting it coalesce into
                // the panel that is already the answer. The files still land.
                manager.setCurrentShelf(id: shelfID)
                return
            }
            // Below the menu-bar icon, not at the cursor: the trigger is an
            // agent finishing work, not the user's hand, so the pointer is
            // wherever they happen to be typing and is not an anchor. Never
            // activating: this is the one path a web page can reach.
            openPanel(for: shelfID, nearCursor: false, activating: false)
        }
    }

    // MARK: - Panel management

    /// `activating` is threaded explicitly rather than inferred from the call
    /// site: a user-initiated summon must take focus, and an inbound link must
    /// never do so, and guessing which is which from panel state is exactly
    /// the kind of inference that goes wrong quietly.
    private func openPanel(for shelfID: UUID, nearCursor: Bool, activating: Bool = true) {
        manager.setCurrentShelf(id: shelfID)
        // Drop any items whose files have disappeared since we last looked,
        // so a freshly-opened panel never shows ghost entries.
        manager.pruneMissingFiles()

        let panel: FloatingPanel<ShelfContainerView>
        if let existing = panels[shelfID] {
            panel = existing
        } else {
            panel = makePanel(for: shelfID)
            panels[shelfID] = panel
        }

        let size = panelSize(for: shelfID)

        if nearCursor {
            positionPanelNearCursor(panel, size: size)
        } else if panel.frame.size == .zero || !panel.isVisible {
            positionPanelBelowStatusItem(panel, size: size)
        }

        if activating {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Shown, never focused. A key panel takes the user's keystrokes and
            // owns the Cmd-key monitor, so a page looping `magpie://` would sit
            // in front of their next ⌘V. `orderFrontRegardless` puts the panel
            // on screen without making this app active or the panel key.
            panel.orderFrontRegardless()
        }
        updateMissingFileSweep()
    }

    private func hidePanel(for shelfID: UUID) {
        panels[shelfID]?.orderOut(nil)
        // Empty shelves are invisible in Recent Shelves, so dismissing them
        // would otherwise leave a zombie behind. Tear them down completely
        // when the user clicks X on an empty shelf.
        if manager.items(of: shelfID).isEmpty {
            panels.removeValue(forKey: shelfID)
            ephemeralShelfIDs.remove(shelfID)
            manager.removeShelf(id: shelfID)
        }
        updateMissingFileSweep()
    }

    private func makePanel(for shelfID: UUID) -> FloatingPanel<ShelfContainerView> {
        let rect = NSRect(origin: .zero, size: collapsedSize(for: shelfID))
        let isEphemeral = ephemeralShelfIDs.contains(shelfID)
        return FloatingPanel(contentRect: rect) { [weak self, manager, conversionService, ocrService, routeService] in
            ShelfContainerView(
                manager: manager,
                conversionService: conversionService,
                ocrService: ocrService,
                routeService: routeService,
                shelfID: shelfID,
                isEphemeral: isEphemeral,
                onClose: { self?.hidePanel(for: shelfID) },
                onResize: { expanded in self?.setPanelExpanded(shelfID, expanded: expanded) },
                onDockChanged: { docked in self?.setPanelDocked(shelfID, docked: docked) }
            )
        }
    }

    private func setPanelExpanded(_ shelfID: UUID, expanded: Bool) {
        guard let panel = panels[shelfID] else { return }
        if expanded { expandedShelfIDs.insert(shelfID) } else { expandedShelfIDs.remove(shelfID) }

        let newSize = expanded ? expandedSize(for: shelfID) : collapsedSize(for: shelfID)

        let currentFrame = panel.frame
        let topY = currentFrame.maxY
        let centerX = currentFrame.midX

        var originX = centerX - newSize.width / 2
        var originY = topY - newSize.height

        if let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            originX = max(screenFrame.minX + 8,
                          min(originX, screenFrame.maxX - newSize.width - 8))
            originY = max(screenFrame.minY + 8, originY)
        }

        let newFrame = NSRect(x: originX, y: originY,
                              width: newSize.width, height: newSize.height)

        animate(panel: panel, to: newFrame)
    }

    private func setPanelDocked(_ shelfID: UUID, docked: Bool) {
        guard let panel = panels[shelfID] else { return }

        if docked {
            preDockFrames[shelfID] = panel.frame
            dockedShelfIDs.insert(shelfID)
            installWindowMoveObserverIfNeeded()

            let currentFrame = panel.frame
            let screenFrame = panel.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? currentFrame
            // Position so the right-side curve sits past the screen edge,
            // giving a flat flush-to-edge look on the visible side.
            let originX = screenFrame.maxX - dockedSize.width + dockedOffscreen
            var originY = currentFrame.midY - dockedSize.height / 2
            originY = max(screenFrame.minY + 4,
                          min(originY, screenFrame.maxY - dockedSize.height - 4))
            let newFrame = NSRect(
                x: originX, y: originY,
                width: dockedSize.width, height: dockedSize.height
            )
            dockedFrames[shelfID] = newFrame
            animate(panel: panel, to: newFrame)
        } else {
            dockedShelfIDs.remove(shelfID)
            dockedFrames.removeValue(forKey: shelfID)
            if dockedShelfIDs.isEmpty { removeWindowMoveObserver() }
            let restore: NSRect
            if let saved = preDockFrames.removeValue(forKey: shelfID) {
                // The display set can change between dock and undock; a saved
                // frame restored verbatim can animate the panel to coordinates
                // no screen has any more, with no in-app way back.
                restore = PanelFrameClamp.clamp(
                    saved, into: NSScreen.screens.map(\.visibleFrame)
                )
            } else {
                let size = panelSize(for: shelfID)
                let currentFrame = panel.frame
                let screenFrame = panel.screen?.visibleFrame
                    ?? NSScreen.main?.visibleFrame
                    ?? currentFrame
                let originX = max(screenFrame.minX + 8,
                                  screenFrame.maxX - size.width - 8)
                let originY = max(screenFrame.minY + 8,
                                  currentFrame.midY - size.height / 2)
                restore = NSRect(origin: NSPoint(x: originX, y: originY), size: size)
            }
            animate(panel: panel, to: restore)
        }
    }

    // MARK: - Auto-park (top-right)

    /// Detects 0→non-empty transitions per shelf and, if the setting is on,
    /// slides the shelf's panel up to the top-right corner where it stacks
    /// behind any other parked shelves. Also prunes tracking for shelves
    /// that have been removed.
    private func checkAutoPark(_ shelves: [Shelf]) {
        let live = Set(shelves.map(\.id))
        // Drop tracking for shelves that no longer exist so the stacking
        // index stays compact when shelves are dismissed.
        if parkedShelfOrder.contains(where: { !live.contains($0) }) {
            parkedShelfOrder.removeAll { !live.contains($0) }
            parkedShelfIDs.formIntersection(live)
            // Reposition remaining parked shelves into the now-tighter stack.
            relayoutParkedShelves()
        }
        lastItemCounts = lastItemCounts.filter { live.contains($0.key) }

        let enabled = UserDefaults.standard.bool(forKey: "shelf.autoParkTopRight")
        for shelf in shelves {
            let prev = lastItemCounts[shelf.id] ?? 0
            let now = shelf.items.count
            lastItemCounts[shelf.id] = now
            // Park on the very first drop into a freshly-empty shelf.
            // Subsequent drops are ignored so the user can drag the panel
            // anywhere they like without it snapping back.
            if enabled, prev == 0, now > 0, !parkedShelfIDs.contains(shelf.id) {
                parkShelf(id: shelf.id)
            }
        }
    }

    private func parkShelf(id: UUID) {
        guard panels[id] != nil else { return }
        parkedShelfIDs.insert(id)
        // Newest-parked shelf goes on top; existing shelves slide down a slot
        // so the just-dropped panel always lands at the top-right corner.
        parkedShelfOrder.insert(id, at: 0)
        // Tiny pause so the just-dropped item visibly lands before the
        // panel starts gliding away — but short enough that it doesn't look
        // like the panel got stuck at the drop location.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.relayoutParkedShelves()
        }
    }

    /// Park animation uses a longer duration and a softer ease-in/out curve
    /// than the regular panel resize so the shelf glides up to the top-right
    /// corner instead of snapping there. Keeps `animate(panel:to:)` snappy
    /// for everything else (expand, dock, drag-restore).
    private func animateParked(panel: NSPanel, to frame: NSRect) {
        move(panel: panel, to: frame, timing: Design.Motion.panelGlide)
    }

    private func relayoutParkedShelves() {
        for id in parkedShelfOrder {
            guard let panel = panels[id] else { continue }
            animateParked(panel: panel, to: parkedFrame(for: id, on: panel.screen))
        }
    }

    private func parkedFrame(for id: UUID, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let index = parkedShelfOrder.firstIndex(of: id) ?? 0
        let size = collapsedSize(for: id)
        // Each strip is as tall as its own contents, so the shelf below the
        // stack cannot be found by multiplying one height by an index.
        let above = parkedShelfOrder.prefix(index)
            .reduce(CGFloat(0)) { $0 + collapsedSize(for: $1).height + parkSpacing }
        let originY = visible.maxY - size.height - parkMargin - above
        return NSRect(
            x: visible.maxX - size.width - parkMargin,
            y: max(visible.minY + parkMargin, originY),
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Close on outside click

    private func installOutsideClickWatcher() {
        guard outsideClickMonitor == nil else { return }
        // Global monitor only fires for clicks NOT in our app, so clicks on
        // the panels themselves (and on our menu bar item) don't trigger
        // this — exactly the semantics we want.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOutsideClick()
            }
        }
    }

    private func handleOutsideClick() {
        guard UserDefaults.standard.bool(forKey: "shelf.closeOnOutsideClick") else { return }
        let visible = panels.filter { $0.value.isVisible }
        guard !visible.isEmpty else { return }
        let location = NSEvent.mouseLocation
        // Inside-panel safety net: a click that lands on a panel's frame is
        // treated as inside even if the global monitor still routed it to
        // us (e.g. the panel is non-activating and the OS counted the click
        // as "outside the app").
        let inside = visible.contains { $0.value.frame.contains(location) }
        guard !inside else { return }
        // Only collapse panels that are currently in expanded mode — the
        // user wants the detail view to fold back to the pill, not for the
        // whole shelf to disappear.
        for shelfID in expandedShelfIDs where visible.keys.contains(shelfID) {
            manager.collapseRequested.send(shelfID)
        }
    }

    private func animate(panel: NSPanel, to frame: NSRect) {
        move(panel: panel, to: frame, timing: Design.Motion.panelFrame)
    }

    /// The single path a panel frame ever changes through. `timing` is nil
    /// under Reduce Motion, where the panel lands at its new frame outright.
    /// The animation group is kept in both cases so `suppressMoveCheck` is
    /// cleared on the same completion path either way — the docked drag-off
    /// detector reads it, and clearing it too early reads a programmatic move
    /// as the user pulling the panel off the edge.
    private func move(
        panel: NSPanel,
        to frame: NSRect,
        timing: Design.Motion.PanelTiming?
    ) {
        suppressMoveCheck = true
        NSAnimationContext.runAnimationGroup({ ctx in
            guard let timing else {
                ctx.duration = 0
                panel.setFrame(frame, display: true)
                return
            }
            ctx.duration = timing.duration
            ctx.timingFunction = timing.mediaTimingFunction
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            // NSAnimationContext calls this on the main thread, but the closure
            // is `Sendable` and the compiler cannot know that, so the hop is
            // written out rather than assumed. Without it this is a main
            // actor-isolated property being mutated from a Sendable closure,
            // which is a data race the language is right to flag.
            Task { @MainActor in self?.suppressMoveCheck = false }
        })
    }

    // MARK: - Docked drag-off detection

    private func installWindowMoveObserverIfNeeded() {
        guard windowMoveObserver == nil else { return }
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSPanel else { return }
            Task { @MainActor in self.handleDockedPanelMoved(window) }
        }
    }

    private func removeWindowMoveObserver() {
        if let obs = windowMoveObserver {
            NotificationCenter.default.removeObserver(obs)
            windowMoveObserver = nil
        }
    }

    private func handleDockedPanelMoved(_ window: NSPanel) {
        if suppressMoveCheck { return }
        guard let (shelfID, _) = panels.first(where: { $0.value === window }) else { return }
        guard dockedShelfIDs.contains(shelfID) else { return }
        guard let anchored = dockedFrames[shelfID] else { return }

        let dx = abs(window.frame.minX - anchored.minX)
        let dy = abs(window.frame.minY - anchored.minY)
        guard dx > 4 || dy > 4 else { return }

        undockInPlace(shelfID: shelfID, fromFrame: window.frame)
    }

    private func undockInPlace(shelfID: UUID, fromFrame: NSRect) {
        guard let panel = panels[shelfID] else { return }
        dockedShelfIDs.remove(shelfID)
        dockedFrames.removeValue(forKey: shelfID)
        preDockFrames.removeValue(forKey: shelfID)
        if dockedShelfIDs.isEmpty { removeWindowMoveObserver() }

        let size = panelSize(for: shelfID)
        // Keep the current top-left roughly where the user let go.
        let topY = fromFrame.maxY
        let newFrame = NSRect(
            x: fromFrame.minX,
            y: topY - size.height,
            width: size.width,
            height: size.height
        )
        animate(panel: panel, to: newFrame)
        manager.undockRequested.send(shelfID)
    }

    // MARK: - Positioning

    private func positionPanelNearCursor(_ panel: NSPanel, size: NSSize) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let edgeMargin: CGFloat = 12
        let dockThreshold: CGFloat = 72
        let cursorGap: CGFloat = 16

        let distLeft = cursor.x - frame.minX
        let distRight = frame.maxX - cursor.x
        let distTop = frame.maxY - cursor.y
        let distBottom = cursor.y - frame.minY

        var originX: CGFloat
        if distRight < dockThreshold {
            originX = frame.maxX - size.width - edgeMargin
        } else if distLeft < dockThreshold {
            originX = frame.minX + edgeMargin
        } else {
            let rightCandidate = cursor.x + cursorGap
            originX = rightCandidate + size.width <= frame.maxX - edgeMargin
                ? rightCandidate
                : cursor.x - size.width - cursorGap
        }

        var originY: CGFloat
        if distTop < dockThreshold {
            originY = frame.maxY - size.height - edgeMargin
        } else if distBottom < dockThreshold {
            originY = frame.minY + edgeMargin
        } else {
            let belowCandidate = cursor.y - size.height - cursorGap
            originY = belowCandidate >= frame.minY + edgeMargin
                ? belowCandidate
                : cursor.y + cursorGap
        }

        originX = max(frame.minX + edgeMargin,
                      min(originX, frame.maxX - size.width - edgeMargin))
        originY = max(frame.minY + edgeMargin,
                      min(originY, frame.maxY - size.height - edgeMargin))

        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: size),
            display: true
        )
    }

    private func positionPanelBelowStatusItem(_ panel: NSPanel, size: NSSize) {
        guard
            let button = statusItem?.button,
            let buttonWindow = button.window
        else {
            // No status item to hang under — the user hid it. Returning here
            // would leave the panel at whatever frame it last had, which for a
            // fresh panel is `.zero`: a hotkey summon would drop a shelf in the
            // bottom-left corner, or off-screen entirely. Anchor to the
            // top-right of the active screen instead, which is where
            // `autoParkTopRight` already puts shelves.
            let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            let margin: CGFloat = 8
            panel.setFrame(
                NSRect(
                    x: screenFrame.maxX - size.width - margin,
                    y: screenFrame.maxY - size.height - margin,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
            return
        }

        let buttonFrameOnScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8

        var originX = buttonFrameOnScreen.midX - size.width / 2
        originX = max(screenFrame.minX + 8,
                      min(originX, screenFrame.maxX - size.width - 8))
        let originY = buttonFrameOnScreen.minY - size.height - gap

        panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size),
                       display: true)
    }

    // MARK: - Duplicate toast

    private func showDuplicateToast(for shelfID: UUID) {
        guard let shelfPanel = panels[shelfID], shelfPanel.isVisible else { return }
        toastPresenter.show(L("toast.duplicate"), near: shelfPanel)
    }

    private func showConcealedClipboardToast(for shelfID: UUID) {
        guard let anchor: NSWindow = panels[shelfID].flatMap({ $0.isVisible ? $0 : nil })
                ?? panels.first(where: { $0.value.isVisible })?.value
        else {
            NSLog("Shelf: declined a concealed clipboard item (no window for toast)")
            return
        }
        toastPresenter.show(L("toast.concealed-clipboard"), near: anchor)
    }

    /// Surfaces wherever the user is looking: the Settings window they just
    /// changed a preference in, else a visible shelf, else the menu bar icon.
    /// The menu-bar fallback is what makes a global shortcut reportable at
    /// all — when it fires there is usually no panel on screen, and a silent
    /// NSLog would read as a dead shortcut.
    private func showToast(_ message: String, symbol: String = "exclamationmark.circle.fill") {
        guard let anchor: NSWindow = settingsWindow.flatMap({ $0.isVisible ? $0 : nil })
                ?? panels.first(where: { $0.value.isVisible })?.value
                ?? statusItem?.button?.window
        else {
            NSLog("Shelf: \(message) (no window for toast)")
            return
        }
        toastPresenter.show(message, near: anchor, symbol: symbol)
    }

    /// Anchored to the panel the drag started from when it is still on
    /// screen, because that is where the user is looking when nothing moves.
    /// A card was dropped on the Bin. Put the files there.
    ///
    /// Through `ShelfTrash`, which is the whole of why this is safe enough to
    /// happen without a modifier: the files are recycled rather than deleted,
    /// the rows leave with them, and ⌘Z moves each file back out of the Bin to
    /// the folder it came from. Reasoning in ADR 0018.
    ///
    /// The window is how the drop finds its shelf. It is the panel the drag
    /// started from, so a second shelf open at the same time cannot be the one
    /// that loses cards; if the panel has gone by the time this runs, nothing
    /// happens, which is the right answer rather than a guess at which shelf
    /// was meant.
    private func binDraggedFiles(_ urls: [URL], from window: NSWindow?) {
        guard let window,
              let shelfID = panels.first(where: { $0.value === window })?.key
        else { return }
        let dropped = Set(urls)
        let items = manager.items(of: shelfID).filter {
            $0.fileURL.map(dropped.contains) == true
        }
        guard !items.isEmpty else { return }
        ShelfTrash.move(items: items, in: shelfID, manager: manager)
    }

    private func showDragToast(_ notice: DragNotice, near window: NSWindow?) {
        let message = String(format: L(notice.messageKey), notice.count)
        if let window, window.isVisible {
            toastPresenter.show(message, near: window)
        } else {
            showToast(message)
        }
    }

    private func showConversionFailureToast(message: String) {
        // Reuse the toast panel infrastructure with custom text. If no shelf
        // panel is currently visible, fall back to a banner attached to the
        // first available shelf, or no-op (we'd rather drop the toast than
        // pop a modal).
        guard let firstVisible = panels.first(where: { $0.value.isVisible }) else {
            NSLog("Shelf: \(message) (no visible panel for toast)")
            return
        }
        toastPresenter.show(message, near: firstVisible.value)
    }

    // MARK: - Quit

    func applicationWillTerminate(_ notification: Notification) {
        conversionService.cancelAll()
        ocrService.cancelAll()
        routeService.cancelAll()
        flushOnTermination()
    }

    // MARK: - Keyboard

    /// The app's only keyboard surface, and the reason it needs no Accessibility
    /// permission: a **local** monitor, which sees a key press only when this app
    /// is active and one of its panels is key. Anything system-wide goes through
    /// `HotkeyManager` (Carbon) instead.
    private func installPasteShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let (shelfID, panel) = self.panels.first(where: { $0.value.isKeyWindow }) else {
                return event
            }
            // A field editor owns every key while it holds first responder — the
            // ⌘K palette's query field, or any text field a future sheet puts
            // inside the panel. Reading keys out from under it would eat the
            // user's typing, and the palette handles its own arrows, Return and
            // Escape through the field's delegate. No panel had a text field
            // before the palette, so this changes nothing that already worked.
            if panel.firstResponder is NSText { return event }

            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers {
                case "v":
                    let added = self.manager.addFromClipboard(to: shelfID)
                    return added > 0 ? nil : event
                case "a":
                    // Forward to whichever view is on screen via Combine; it
                    // owns the selection state and decides what "all" means
                    // (shelf root, folder browse, or the collapsed strip). A
                    // docked tab shows no rows, so the key falls through
                    // rather than being swallowed into nothing.
                    guard !self.dockedShelfIDs.contains(shelfID) else { return event }
                    self.manager.selectAllRequested.send(shelfID)
                    return nil
                case "c":
                    self.manager.copyRequested.send(shelfID)
                    return nil
                case "z":
                    guard self.manager.canUndo else { return event }
                    self.manager.performUndo()
                    return nil
                case "k":
                    // NOT gated on the shelf being expanded. It was, and that
                    // made ⌘K do nothing at all in the state a shelf is
                    // actually in most of the time: a summoned shelf starts
                    // COLLAPSED, so the first ⌘K anyone ever pressed was
                    // swallowed here. The view expands itself before showing
                    // the palette — the user should not have to know the
                    // difference between a pill and a panel to reach an action.
                    self.manager.paletteRequested.send(shelfID)
                    return nil
                case "y":
                    guard self.expandedShelfIDs.contains(shelfID) else { return event }
                    return self.sendKeyCommand(.quickLook, to: shelfID)
                case "w":
                    // Closes this shelf, and only ever while it is the key
                    // panel — which is the whole of the scoping the owner
                    // asked for ("only when it's highlighted"). Nothing here
                    // is system-wide: a LOCAL monitor lives in this process
                    // and sees a key press only when Magpie is active, so no
                    // other app's ⌘W is touched, and a Carbon hotkey (which
                    // would take it globally) is deliberately not used.
                    //
                    // It also closes a gap AGENTS.md names as a rule: the ✕
                    // in the strip header had no keyboard path at all. This is
                    // the same call that button makes, so the two cannot
                    // drift.
                    //
                    // Not Escape, which already means something else here and
                    // means it in two different states — collapse an expanded
                    // panel, or undo a narrowed selection.
                    self.hidePanel(for: shelfID)
                    return nil
                default:
                    // Fall through to `ShelfKey.command` rather than returning
                    // here. This branch is entered by every ⌘-key that carries
                    // no other modifier, including the ones that produce no
                    // letter, so returning the event was a trapdoor: ⌘⌫ landed
                    // in this `default` and could never reach the model that
                    // claims it. ⌘↑/⌘↓ escaped it only by accident, because an
                    // arrow key also sets `.function` and so never enters this
                    // branch at all. Falling through costs nothing — the model
                    // returns nil for every key it does not claim, and the
                    // guard below hands those straight back.
                    break
                }
            }

            // Escape stops a drop that is still landing, from any shelf state —
            // files land on a collapsed pill far more often than on an expanded
            // panel, so this has to sit above the expanded-only guard below.
            if ShelfKey.cancelsIngest(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isIngesting: self.manager.isIngesting(shelfID: shelfID)
            ) {
                self.manager.cancelIngest(shelfID: shelfID)
                return nil
            }

            guard let command = ShelfKey.command(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            ) else { return event }
            // Focus-cursor keys. An expanded panel answers all of them. A
            // collapsed strip is a selection surface and answers only the
            // selection ones — swallowing the rest there would turn Return, ⌫
            // and Escape into silent dead keys, which is the failure this repo
            // has already shipped once. A docked tab and an empty shelf have no
            // rows at all, so nothing is taken from them.
            //
            // Escape is the exception, and only when the user has narrowed the
            // strip to fewer rows than it holds: then it is the way back to
            // "a drag takes the whole shelf". With nothing picked it still
            // falls straight through.
            if !self.expandedShelfIDs.contains(shelfID) {
                guard !self.dockedShelfIDs.contains(shelfID),
                      !self.manager.items(of: shelfID).isEmpty,
                      ShelfKey.isCollapsedStripCommand(
                          command,
                          hasNarrowedSelection:
                              self.manager.shelvesWithNarrowedSelection.contains(shelfID)
                      )
                else { return event }
            }
            // The space bar belongs to Quick Look until the user has actually
            // started navigating with the keyboard. A pointer user never has a
            // focus cursor, so for them this key still falls through the
            // responder chain to `QuickLookController` exactly as before.
            if command == .toggleSelection,
               !self.manager.shelvesWithKeyboardFocus.contains(shelfID) {
                return event
            }
            return self.sendKeyCommand(command, to: shelfID)
        }
    }

    /// Hands a parsed command to the shelf's expanded view and swallows the
    /// event. Returning nil is what keeps AppKit from beeping at a key the
    /// panel has just acted on.
    private func sendKeyCommand(_ command: ShelfKey.Command, to shelfID: UUID) -> NSEvent? {
        manager.keyCommandRequested.send(
            KeyCommandRequest(shelfID: shelfID, command: command)
        )
        return nil
    }
}

/// Refuses a flood without taxing a real caller: `capacity` links may arrive
/// back to back, then one every `1 / refillPerSecond` seconds. Pure apart from
/// the clock its caller passes in, which is what makes it testable without
/// waiting for real time to pass.
struct TokenBucket {
    let capacity: Double
    let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Date

    init(capacity: Double, refillPerSecond: Double, now: Date = Date()) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = now
    }

    /// Spends one token, or refuses.
    mutating func take(now: Date = Date()) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
