import AppKit
import UniformTypeIdentifiers

/// Builds the "Routes ▸" submenu for a selection. `nil` when no route applies,
/// mirroring `ConversionMenu.makeSubmenu` — the eligibility decision itself is
/// `RouteMatch.applies`, which is pure and unit-tested.
@MainActor
enum RouteMenu {
    /// Routes whose match covers every file in the selection, in file order.
    static func applicableRoutes(_ routes: [Route], for inputs: [RouteInput]) -> [Route] {
        routes.filter { RouteMatch.applies($0.match, to: inputs) }
    }

    static func makeSubmenu(
        routes: [Route],
        items: [ShelfItem],
        target: AnyObject,
        action: Selector
    ) -> NSMenu? {
        let files = items.filter { $0.fileURL != nil }
        guard !files.isEmpty else { return nil }
        let applicable = applicableRoutes(routes, for: files.map(input(for:)))
        guard !applicable.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for route in applicable {
            let entry = NSMenuItem(title: route.name, action: action, keyEquivalent: "")
            entry.target = target
            entry.representedObject = route.id
            if let symbol = route.symbol {
                entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(entry)
        }
        return menu
    }

    /// The one place the match predicate touches the filesystem.
    static func input(for item: ShelfItem) -> RouteInput {
        guard let url = item.fileURL else {
            return RouteInput(pathExtension: "", typeIdentifier: nil)
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return RouteInput(
            pathExtension: url.pathExtension,
            typeIdentifier: type?.identifier
        )
    }
}

/// THE ONLY WAY A ROUTE EVER STARTS.
///
/// Both menu surfaces call this and nothing else does — an invariant a test
/// pins by scanning the sources (`RouteTriggerInvariantTests`). Keeping the
/// entry point single is what makes "no inbound URL, no timer, no agent can
/// run a route" checkable rather than merely intended (ADR 0003 §2, ADR 0004).
@MainActor
enum RouteLauncher {
    static func run(
        routeID: String,
        items: [ShelfItem],
        shelfID: UUID,
        store: RouteStore,
        service: RouteService
    ) {
        guard let route = store.route(id: routeID) else { return }
        // Inputs are read, never touched: the paths go to the command as
        // arguments and the shelf keeps its items exactly as they were.
        let usable = items.filter { item in
            guard let url = item.fileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard !usable.isEmpty else { return }
        service.enqueueRun(
            route: route,
            itemIDs: usable.map(\.id),
            shelfID: shelfID,
            files: usable.compactMap(\.fileURL)
        )
    }
}
