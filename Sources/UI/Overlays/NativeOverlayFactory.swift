import AppKit

/// App composition injects this into BoardRootView. The factory owns no board or OS state.
@MainActor func makeNativeOverlayFactory() -> OverlayFactory {
    { kind, context in
        let route: OverlayRoute
        switch kind {
        case .event: route = .event("", nil)
        case .add: route = .newEvent
        case .search: route = .search
        case .settings: route = .settings
        case .monthPicker: route = .monthPicker
        case .calendars: route = .calendars
        case .agenda: route = .agenda(context.presentation.state.view.selectedDay, nil)
        }
        return NativeOverlayController(context: context, route: route)
    }
}
