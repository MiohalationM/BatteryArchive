import Testing
@testable import BatteryBar

@Suite struct MainWindowPresentationStrategyTests {
    @Test func visibleWindowAlwaysWins() {
        #expect(MainWindowPresentationStrategy.route(
            hasVisibleWindow: true,
            hasRetainedWindow: false,
            hasSceneAction: true
        ) == .focusVisibleWindow)
    }

    @Test func retainedWindowCanBeReopenedAfterClose() {
        #expect(MainWindowPresentationStrategy.route(
            hasVisibleWindow: false,
            hasRetainedWindow: true,
            hasSceneAction: false
        ) == .restoreRetainedWindow)
    }

    @Test func sceneActionIsUsedBeforeNativeFallback() {
        #expect(MainWindowPresentationStrategy.route(
            hasVisibleWindow: false,
            hasRetainedWindow: false,
            hasSceneAction: true
        ) == .openSwiftUIScene)
    }

    @Test func missingSceneActionCreatesAWindowInsteadOfPostingToAnAbsentRelay() {
        #expect(MainWindowPresentationStrategy.route(
            hasVisibleWindow: false,
            hasRetainedWindow: false,
            hasSceneAction: false
        ) == .createNativeWindow)
    }
}
