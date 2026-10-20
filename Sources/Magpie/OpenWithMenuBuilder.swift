import AppKit

@MainActor
enum OpenWithMenuBuilder {
    static func make(for url: URL?, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let url else {
            let item = NSMenuItem(title: L("No File"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let allApps = NSWorkspace.shared.urlsForApplications(toOpen: url)

        if let defaultApp {
            menu.addItem(makeItem(
                for: defaultApp,
                title: OpenWithApplicationPresentation.name(for: defaultApp)
                    + L("openwith.default.suffix"),
                target: target,
                action: action
            ))
            menu.addItem(.separator())
        }

        let others = allApps
            .filter { $0 != defaultApp }
            .sorted {
                OpenWithApplicationPresentation.name(for: $0).localizedCaseInsensitiveCompare(
                    OpenWithApplicationPresentation.name(for: $1)
                ) == .orderedAscending
            }
        for app in others {
            menu.addItem(makeItem(
                for: app,
                title: OpenWithApplicationPresentation.name(for: app),
                target: target,
                action: action
            ))
        }

        if menu.items.isEmpty {
            let item = NSMenuItem(title: L("No Applications"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }

    private static func makeItem(
        for app: URL,
        title: String,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = app
        item.image = OpenWithApplicationPresentation.icon(for: app)
        return item
    }
}

enum OpenWithApplicationPresentation {
    static func name(for url: URL) -> String {
        if let bundle = Bundle(url: url),
           let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                        ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                        ?? (bundle.infoDictionary?["CFBundleName"] as? String) {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
