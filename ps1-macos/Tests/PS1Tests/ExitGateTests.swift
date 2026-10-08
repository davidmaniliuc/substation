import Testing
import Foundation
@testable import PS1

@Test func nothingRunningProceedsAtOnce() {
    var gate = ExitGate()
    #expect(gate.request(.quit, playing: false) == .proceed)
    #expect(gate.pending == nil)
}

@Test func aRunningGamePromptsOnce() {
    var gate = ExitGate()
    #expect(gate.request(.eject, playing: true) == .prompted)
    #expect(gate.pending == .eject)
}

@Test func aSecondRequestWhileThePromptIsUpIsBusyAndChangesNothing() {
    // ⌘Q while the Eject sheet is up must be answered .terminateCancel by the
    // caller, never left as a .terminateLater nobody replies to.
    var gate = ExitGate()
    _ = gate.request(.eject, playing: true)
    #expect(gate.request(.quit, playing: true) == .busy)
    #expect(gate.pending == .eject)
}

@Test func takeAndCancelBothClearThePrompt() {
    var gate = ExitGate()
    _ = gate.request(.quit, playing: true)
    #expect(gate.take() == .quit)
    #expect(gate.pending == nil)
    _ = gate.request(.closeWindow, playing: true)
    #expect(gate.cancel() == .closeWindow)
    #expect(gate.pending == nil)
}

@MainActor @Test func anExitCompletionRunsAtMostOnce() {
    // The save's completion and the 3-second fallback both call fire().
    var count = 0
    let done = ExitCompletion { count += 1 }
    done.fire()
    done.fire()
    #expect(count == 1)
}

@MainActor @Test func theFallbackStandsDownOnceTheSaveIsAnswered() {
    var count = 0
    let done = ExitCompletion { count += 1 }
    done.noteAnswered()
    done.fireFallback()                // the write is still running
    #expect(count == 0)
    done.fire()                        // the write finished
    #expect(count == 1)
}

@MainActor @Test func theFallbackFiresWhenNoAnswerComes() {
    var count = 0
    let done = ExitCompletion { count += 1 }
    done.fireFallback()
    #expect(count == 1)
}

@Test func theQuestionNamesWhatIsBeingLeft() {
    #expect(ExitIntent.quit.question == "Are you sure you want to exit the application?")
    #expect(ExitIntent.closeWindow.question == "Are you sure you want to exit the application?")
    #expect(ExitIntent.eject.question == "Are you sure you want to exit the game?")
    #expect(ExitIntent.open(URL(fileURLWithPath: "/x.cue")).question == "Are you sure you want to exit the game?")
}
