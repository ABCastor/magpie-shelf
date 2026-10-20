import AppKit

/// A failed route has to stay on screen with the reason the command gave.
///
/// This is an `NSAlert` rather than a toast on purpose: `ToastPresenter` is
/// two lines, mouse-transparent and gone in 2.5 seconds, which cannot carry a
/// stderr tail the user is meant to read. The rest of the app already reports
/// failures this way (zip, rename, trash, image actions), and the text field
/// is selectable so the message can be copied into a terminal.
@MainActor
func presentRouteFailure(_ failure: RouteFailure) {
    // The user asked for the cancellation, so there is nothing to report.
    if case .cancelled = failure { return }

    let alert = NSAlert()
    alert.messageText = L("routes.failed.title")
    alert.informativeText = failure.displayMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("OK"))
    if case .exited(_, _, let detail) = failure {
        alert.accessoryView = detailView(
            text: detail.isEmpty ? L("routes.failed.no-detail") : detail
        )
    }
    alert.runModal()
}

@MainActor
private func detailView(text: String) -> NSView {
    let textView = NSTextView()
    textView.string = text
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.textContainerInset = NSSize(width: 4, height: 4)

    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = textView
    textView.frame = NSRect(x: 0, y: 0, width: 320, height: 110)
    textView.autoresizingMask = [.width]
    return scroll
}
