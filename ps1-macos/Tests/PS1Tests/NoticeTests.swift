import Testing
@testable import PS1

/// Every notice says what kind of event it is with its icon, so the same
/// event always looks the same in the badge stack.
@MainActor
@Suite struct NoticeTests {
    @Test func theAnalogNoticeCarriesTheControllerIcon() {
        let model = EmulatorViewModel()
        model.simulatePadStatusForTesting(PadStatus(analog: true, small: 0, large: 0))
        #expect(model.notice == Notice(icon: NoticeIcon.analog, text: "Analog on"))
    }
}
