enum MainWindowPresentationRoute: Equatable {
    case focusVisibleWindow
    case restoreRetainedWindow
    case openSwiftUIScene
    case createNativeWindow
}

enum MainWindowPresentationStrategy {
    static func route(
        hasVisibleWindow: Bool,
        hasRetainedWindow: Bool,
        hasSceneAction: Bool
    ) -> MainWindowPresentationRoute {
        if hasVisibleWindow { return .focusVisibleWindow }
        if hasRetainedWindow { return .restoreRetainedWindow }
        if hasSceneAction { return .openSwiftUIScene }
        return .createNativeWindow
    }
}
