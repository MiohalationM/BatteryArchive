enum MainWindowPresentationRoute: Equatable {
    case focusVisibleWindow
    case deminiaturizeWindow
    case createNativeWindow
}

enum MainWindowPresentationStrategy {
    static func route(
        hasVisibleWindow: Bool,
        hasMinimizedWindow: Bool
    ) -> MainWindowPresentationRoute {
        if hasVisibleWindow { return .focusVisibleWindow }
        if hasMinimizedWindow { return .deminiaturizeWindow }
        return .createNativeWindow
    }
}
