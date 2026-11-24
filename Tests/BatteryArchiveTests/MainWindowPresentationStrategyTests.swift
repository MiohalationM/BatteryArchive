import Testing
@testable import BatteryArchive

@Suite struct MainWindowPresentationStrategyTests {
    @Test func visibleWindowAlwaysWins() {
        #expect(MainWindowPresentationStrategy.route(
            hasVisibleWindow: true,
            hasMinimizedWindow: false
        ) == .focusVisibleWindow)
        #expect(MainWindowPresentationStrategy.route(
            hasVisibleWindow: true,
            hasMinimizedWindow: true
        ) == .focusVisibleWindow)
    }

    @Test func minimizedWindowIsDeminiaturized() {
        #expect(MainWindowPresentationStrategy.route(
            hasVisibleWindow: false,
            hasMinimizedWindow: true
        ) == .deminiaturizeWindow)
    }

    @Test func absentWindowCreatesNativeWindowOnDemand() {
        #expect(MainWindowPresentationStrategy.route(
            hasVisibleWindow: false,
            hasMinimizedWindow: false
        ) == .createNativeWindow)
    }
}
