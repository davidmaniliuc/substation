import CPs1
import Foundation
import Synchronization
import Testing
@testable import PS1

/// The real `Session` over the C ABI, built and freed but never started:
/// `start()` needs an audio device, and the session's own Zig tests cover
/// that path. A never-started session has no thread to answer a request, so
/// every answer here is the one `ps1_session_free` or a superseding swap
/// gives.
@MainActor
struct SessionTests {
    /// How many times the session handed a disc box's bytes back.
    final class Releases: Sendable {
        let count = Atomic<Int>(0)
    }

    /// The boxes a session made, held weakly so a test can see them go.
    final class Boxes {
        private var made: [() -> DiscBox?] = []
        private(set) var releases: [Releases] = []

        func make(_ bin: Data) -> DiscBox {
            let tally = Releases()
            let box = DiscBox(bin) { tally.count.add(1, ordering: .relaxed) }
            made.append { [weak box] in box }
            releases.append(tally)
            return box
        }

        func alive(_ i: Int) -> Bool { made[i]() != nil }
        func released(_ i: Int) -> Int { releases[i].count.load(ordering: .relaxed) }
    }

    static let bios = Data(repeating: 0, count: 512 * 1024)

    static func config(bios: Data = bios, disc: DiscBytes? = nil) -> SessionConfig {
        let cards = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTests-\(UUID().uuidString)", isDirectory: true)
        return SessionConfig(bios: bios, disc: disc, resumeState: nil, cardDirectory: cards,
                             view: nil, cpuEngine: .interpreter, fastBoot: false)
    }

    static func disc() -> DiscBytes {
        DiscBytes(bin: Data(repeating: 0, count: 2352 * 16), cue: nil, sbi: nil, ppf: nil)
    }

    /// Lets the main queue run the trampolines' hops until `done` holds or
    /// `timeout` passes.
    static func settle(within timeout: Duration = .seconds(1), until done: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !done(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aSessionBuildsAndFreesHeadless() throws {
        let session = try Session(Self.config())
        session.free()
        session.free()
    }

    @Test func aRequestWaitingAtFreeIsAnsweredSessionStopped() async throws {
        let session = try Session(Self.config())
        var answers: [Result<ResumeSnapshot, Ps1Error>] = []
        session.requestSave { answers.append($0) }
        session.free()
        await Self.settle { !answers.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answers.count == 1)
        guard case .failure(.sessionStopped) = answers.first else {
            Issue.record("expected .sessionStopped, got \(String(describing: answers.first))")
            return
        }
    }

    @Test func aRequestAnsweredDuringFreeDoesNotDeadlock() async throws {
        let session = try Session(Self.config())
        var answers: [Result<Data, Ps1Error>] = []
        session.requestLoad(Data([1, 2, 3])) { answers.append($0) }
        session.free()
        await Self.settle { !answers.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answers.count == 1)
        guard case .failure(.sessionStopped) = answers.first else {
            Issue.record("expected .sessionStopped, got \(String(describing: answers.first))")
            return
        }
    }

    @Test func aSupersededSwapReleasesItsBytesOnce() async throws {
        let boxes = Boxes()
        let session = try Session(Self.config(), makeBox: boxes.make)
        var first: [Ps1Error?] = []
        var second: [Ps1Error?] = []
        session.requestSwap(Self.disc()) { first.append($0) }
        session.requestSwap(Self.disc()) { second.append($0) }

        await Self.settle { !first.isEmpty }
        #expect(first == [.superseded])
        #expect(!boxes.alive(0))
        #expect(boxes.released(0) == 1)
        #expect(second.isEmpty)
        #expect(boxes.alive(1))

        session.free()
        await Self.settle { !second.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(first.count == 1)
        #expect(second == [.sessionStopped])
        #expect(!boxes.alive(1))
        #expect(boxes.released(1) == 1)
    }

    @Test func aRefusedNewReleasesTheDiscBoxOnce() {
        let boxes = Boxes()
        #expect(throws: Ps1Error.badBIOSSize) {
            _ = try Session(Self.config(bios: Data([1, 2, 3]), disc: Self.disc()), makeBox: boxes.make)
        }
        #expect(!boxes.alive(0))
        #expect(boxes.released(0) == 0)
    }

    @Test func everyNewErrorCodeMaps() {
        let mapped = (-25 ... -21).reversed().map { Ps1Error.from(Int32($0)) }
        #expect(mapped == [.audio, .noMetal, .sessionStopped, .busy, .superseded])
    }

    /// A started session answers every request on its emulator thread, never
    /// on the main one; a trampoline that inherits the main actor traps there.
    @Test func everyTrampolineRunsOffTheMainThread() async {
        var saves: [Result<ResumeSnapshot, Ps1Error>] = []
        var loads: [Result<Data, Ps1Error>] = []
        var shots: [Data?] = []
        var simple: [Ps1Error?] = []
        nonisolated(unsafe) let save = Pending<Result<ResumeSnapshot, Ps1Error>> { saves.append($0) }.lend()
        nonisolated(unsafe) let load = Pending<Result<Data, Ps1Error>> { loads.append($0) }.lend()
        nonisolated(unsafe) let shot = Pending<Data?> { shots.append($0) }.lend()
        nonisolated(unsafe) let done = Pending<Ps1Error?> { simple.append($0) }.lend()
        let tally = Releases()
        nonisolated(unsafe) let box = Unmanaged.passRetained(
            DiscBox(Data([1])) { tally.count.add(1, ordering: .relaxed) }).toOpaque()
        let bytes: [UInt8] = [7, 8, 9]
        Thread.detachNewThread {
            Session.saveDone(save, PS1_OK, bytes, bytes.count, nil, 0)
            Session.loadDone(load, PS1_OK, bytes, bytes.count)
            Session.screenshotDone(shot, bytes, bytes.count)
            Session.simpleDone(done, PS1_OK)
            Session.discReleased(box)
        }
        await Self.settle { !saves.isEmpty && !loads.isEmpty && !shots.isEmpty && !simple.isEmpty }
        if case .success(let s) = saves.first { #expect(s.state == Data(bytes)) } else { Issue.record("save: \(saves)") }
        if case .success(let d) = loads.first { #expect(d == Data(bytes)) } else { Issue.record("load: \(loads)") }
        #expect(shots == [Data(bytes)])
        #expect(simple.count == 1 && simple[0] == nil)
        #expect(tally.count.load(ordering: .relaxed) == 1)
    }

    @Test func theEventDecodesEveryKind() {
        let pad = Ps1PadStatus(analog: 1, small: 255, large: 0x40)
        let idle = Ps1PadStatus()
        #expect(SessionEvent(Ps1Event(kind: PS1_EVENT_PAD, pad: pad, card_writes: 0, value: 0))
                == .pad(PadStatus(analog: true, small: 255, large: 0x40)))
        #expect(SessionEvent(Ps1Event(kind: PS1_EVENT_CARD_WRITE, pad: idle, card_writes: 3, value: 0))
                == .cardWrites(3))
        #expect(SessionEvent(Ps1Event(kind: PS1_EVENT_REWIND, pad: idle, card_writes: 0, value: 2.5))
                == .rewindSeconds(2.5))
        #expect(SessionEvent(Ps1Event(kind: PS1_EVENT_FRAME_RATE, pad: idle, card_writes: 0, value: 59.9))
                == .frameRate(59.9))
        #expect(SessionEvent(Ps1Event(kind: 99, pad: idle, card_writes: 0, value: 0)) == nil)
    }

    /// The session calls the trampoline on its emulator thread with the
    /// context it was given; the event reaches `onEvent` on the main actor.
    nonisolated static func sendFrameRate(_ ctx: UnsafeMutableRawPointer?) {
        var ev = Ps1Event(kind: PS1_EVENT_FRAME_RATE, pad: Ps1PadStatus(), card_writes: 0, value: 60)
        Session.eventReceived(ctx, &ev)
    }

    @Test func theTrampolineDeliversOnTheMainActor() async throws {
        let session = try Session(Self.config())
        defer { session.free() }
        var seen: [SessionEvent] = []
        session.onEvent = { seen.append($0) }
        let ctx = UInt(bitPattern: session.eventContextForTesting)
        await Task.detached { Self.sendFrameRate(UnsafeMutableRawPointer(bitPattern: ctx)) }.value
        await Self.settle { !seen.isEmpty }
        #expect(seen == [.frameRate(60)])
    }

    @Test func anEventAfterFreeIsDropped() async throws {
        let session = try Session(Self.config())
        var seen: [SessionEvent] = []
        session.onEvent = { seen.append($0) }
        Self.sendFrameRate(session.eventContextForTesting)
        session.free()
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.isEmpty)
    }
}
