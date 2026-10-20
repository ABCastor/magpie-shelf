import Foundation
import IOKit.pwr_mgt

@MainActor
final class KeepAwakeController {
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    private(set) var isAwake = false
    private(set) var duration: TimeInterval?
    let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    /// Holds (or releases) an IOKit power-management assertion that prevents
    /// idle display sleep — which transitively blocks idle system sleep and
    /// the screen saver, matching Caffeine's behavior. When `duration` is
    /// non-nil, schedules an auto-off timer for that many seconds.
    func setAwake(_ enabled: Bool, duration: TimeInterval? = nil) {
        timer?.invalidate()
        timer = nil

        if enabled {
            if !isAwake {
                var assertion: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Magpie keep-awake" as CFString,
                    &assertion
                )
                guard result == kIOReturnSuccess else { return }
                self.assertion = assertion
                isAwake = true
                onChange(true)
            }
            self.duration = duration
            if let duration {
                timer = Timer.scheduledTimer(
                    withTimeInterval: duration, repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in self?.setAwake(false) }
                }
            }
        } else if isAwake {
            IOPMAssertionRelease(assertion)
            assertion = 0
            self.duration = nil
            isAwake = false
            onChange(false)
        }
    }
}
