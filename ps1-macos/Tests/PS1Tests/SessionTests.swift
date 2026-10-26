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

    /// A started session answers a load on its emulator thread, never on the
    /// main one; a trampoline that inherits the main actor traps there.
    @Test func aLoadAnsweredOnAnotherThreadReachesTheMainActor() async {
        var answers: [Result<Data, Ps1Error>] = []
        nonisolated(unsafe) let ctx = Pending<Result<Data, Ps1Error>> { answers.append($0) }.lend()
        let undo: [UInt8] = [7, 8, 9]
        Thread.detachNewThread { Session.loadDone(ctx, PS1_OK, undo, undo.count) }
        await Self.settle { !answers.isEmpty }
        guard case .success(let data) = answers.first else {
            Issue.record("expected the undo state, got \(String(describing: answers.first))")
            return
        }
        #expect(data == Data(undo))
    }
}
