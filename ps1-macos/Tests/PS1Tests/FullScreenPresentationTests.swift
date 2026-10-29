import Testing
import AppKit
@testable import PS1

/// A game in full screen hides its toolbar band with the menu bar: AppKit
/// kept it on screen and laid the picture out below it, an opaque strip
/// across the top of the game.
@Test func aFullScreenGameHidesItsToolbarWithTheMenuBar() {
    let options = CloseInterceptor.Proxy.fullScreenPresentation([.fullScreen], showsGame: true)
    #expect(options == [.fullScreen, .autoHideMenuBar, .autoHideToolbar])
}

/// The library keeps its toolbar in full screen: its controls are in it.
@Test func theFullScreenLibraryKeepsItsToolbar() {
    let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar]
    #expect(CloseInterceptor.Proxy.fullScreenPresentation(proposed, showsGame: false) == proposed)
}

/// The answer reaches AppKit only through the delegate, so the proxy must
/// claim the method SwiftUI's own delegate may not implement.
@MainActor @Test func theProxyAnswersTheFullScreenPresentationQuestion() {
    let proxy = CloseInterceptor.Proxy()
    proxy.showsGame = { true }
    let window = NSWindow()
    #expect(proxy.responds(to: #selector(NSWindowDelegate.window(_:willUseFullScreenPresentationOptions:))))
    let options = proxy.window(window, willUseFullScreenPresentationOptions: [.fullScreen])
    #expect(options.contains(.autoHideToolbar))
}
