import AppKit
import QuartzCore

/// Which screen edge summons a shelf during a drag.
enum SummonEdge: String, CaseIterable, Identifiable {
    case right
    case left

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .right: return L("edge.right")
        case .left: return L("edge.left")
        }
    }
}

/// Summons a shelf when a left-drag parks the cursor against a screen edge,
/// so the user has somewhere to drop what they're carrying.
///
/// The decision is pure (`isWithinBand` / `shouldSummon`); everything below it
/// is thin event plumbing. Only fires while the left button is held — the
/// caller's release watcher removes the shelf again if nothing lands on it,
/// which is what makes a false positive harmless.
final class EdgeSummonDetector {
    /// Carries whether a drag was in progress at fire time — see
    /// `ShakeDetector.onShake`. Edge summon only ever fires mid-drag, but the
    /// signature is shared so `summonShelfAtCursor` has one contract.
    var onTrigger: ((Bool) -> Void)?
    var edge: SummonEdge = .right

    // Tunables
    static let bandWidth: CGFloat = 4
    static let dwell: CFTimeInterval = 0.4
    private let cooldown: CFTimeInterval = 1.5

    /// True while the cursor sits inside the trigger band of `edge`.
    static func isWithinBand(point: CGPoint, screenFrame: CGRect, edge: SummonEdge) -> Bool {
        guard point.y >= screenFrame.minY, point.y <= screenFrame.maxY else { return false }
        switch edge {
        case .right: return point.x >= screenFrame.maxX - bandWidth
        case .left:  return point.x <= screenFrame.minX + bandWidth
        }
    }

    /// True once the cursor has been in the band continuously for `dwell`.
    /// `dwellStart` is nil until the cursor first enters the band.
    static func shouldSummon(
        point: CGPoint,
        screenFrame: CGRect,
        edge: SummonEdge,
        dwellStart: CFTimeInterval?,
        now: CFTimeInterval
    ) -> Bool {
        guard let dwellStart else { return false }
        guard isWithinBand(point: point, screenFrame: screenFrame, edge: edge) else { return false }
        return now - dwellStart >= dwell
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var dwellStart: CFTimeInterval?
    private var dwellTimer: Timer?
    private var lastSummon: CFTimeInterval = 0

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        resetDwell()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            resetDwell()
        case .leftMouseDragged:
            let point = NSEvent.mouseLocation
            guard Self.isWithinBand(
                point: point, screenFrame: screenFrame(containing: point), edge: edge
            ) else {
                resetDwell()
                return
            }
            guard dwellStart == nil else { return }
            dwellStart = CACurrentMediaTime()
            // Drag events stop arriving once the cursor is pinned against the
            // edge and the user holds still, so the dwell has to be timed
            // rather than counted off later events.
            // .common, not the default mode: a docked panel deliberately
            // overhangs the trigger band, so AppKit is often spinning a
            // tracking loop exactly while the dwell is being measured, and a
            // default-mode timer would not fire until the drag was over.
            let timer = Timer(timeInterval: Self.dwell, repeats: false) { [weak self] _ in
                self?.fireIfStillDwelling()
            }
            RunLoop.main.add(timer, forMode: .common)
            dwellTimer = timer
        default:
            break
        }
    }

    private func fireIfStillDwelling() {
        dwellTimer = nil
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            resetDwell()
            return
        }
        let now = CACurrentMediaTime()
        let point = NSEvent.mouseLocation
        guard Self.shouldSummon(
            point: point,
            screenFrame: screenFrame(containing: point),
            edge: edge,
            dwellStart: dwellStart,
            now: now
        ) else { return }
        // Blocked by the cooldown: leave `dwellStart` set so re-arming needs
        // the cursor to leave the band, rather than firing again the instant
        // the cooldown lapses.
        guard now - lastSummon > cooldown else { return }
        lastSummon = now
        dwellStart = nil
        // The guard at the top of this method already proved the button is
        // down, and this call is synchronous, so the drag state cannot go
        // stale between here and the handler.
        onTrigger?(true)
    }

    private func resetDwell() {
        dwellStart = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    private func screenFrame(containing point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.frame ?? .zero
    }
}
