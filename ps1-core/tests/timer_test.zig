const std = @import("std");
const expectEqual = std.testing.expectEqual;
const ps1_core = @import("ps1_core");
const Timer = ps1_core.timer.Timer;

const mode_reset_on_target: u32 = 1 << 3;
const mode_irq_on_target: u32 = 1 << 4;
const mode_irq_on_overflow: u32 = 1 << 5;
const mode_sysclk_div8: u32 = 0x0200;

fn timerWith(mode: u32, target: u32) Timer {
    var t = Timer{};
    t.write(0x4, mode);
    t.write(0x8, target);
    return t;
}

test "a deferred counter reads back what a per-tick step would leave" {
    var fine = timerWith(mode_reset_on_target | mode_irq_on_target, 10_000);
    var coarse = timerWith(mode_reset_on_target | mode_irq_on_target, 10_000);

    var i: u32 = 0;
    while (i < 5_000) : (i += 1) _ = fine.step(1);
    var j: u32 = 0;
    while (j < 1_000) : (j += 1) _ = coarse.step(5);

    try expectEqual(fine.read(0x0), coarse.read(0x0));
    try expectEqual(@as(u32, 5_000), coarse.read(0x0));
}

test "the target IRQ fires on the exact tick, not at the end of a batch" {
    var t = timerWith(mode_reset_on_target | mode_irq_on_target, 1_000);

    var fired_at: u32 = 0;
    var i: u32 = 1;
    while (i <= 2_000) : (i += 1) {
        if (t.step(1) and fired_at == 0) fired_at = i;
    }
    try expectEqual(@as(u32, 1_000), fired_at);
}

test "a batch never merges the target and overflow crossings" {
    // No reset on target, so the counter runs on to overflow. A deadline that
    // took only the overflow would let one batch swallow the target crossing.
    const mode = mode_irq_on_target | mode_irq_on_overflow;
    var fine = timerWith(mode, 0x100);
    var batched = timerWith(mode, 0x100);

    var fine_irqs: u32 = 0;
    var i: u32 = 0;
    while (i < 0x20000) : (i += 1) {
        if (fine.step(1)) fine_irqs += 1;
    }
    var batched_irqs: u32 = 0;
    var j: u32 = 0;
    while (j < 0x20000 / 8) : (j += 1) {
        if (batched.step(8)) batched_irqs += 1;
    }

    try expectEqual(fine_irqs, batched_irqs);
    try std.testing.expect(fine_irqs >= 4);
}

test "the sysclk/8 prescaler carries across a deferred window" {
    var fine = timerWith(mode_sysclk_div8 | mode_irq_on_target, 1_000);
    var coarse = timerWith(mode_sysclk_div8 | mode_irq_on_target, 1_000);

    var i: u32 = 0;
    while (i < 3_003) : (i += 1) _ = fine.step(1);
    var j: u32 = 0;
    while (j < 1_001) : (j += 1) _ = coarse.step(3);

    try expectEqual(fine.read(0x0), coarse.read(0x0));
    try expectEqual(fine.prescale_counter, coarse.prescale_counter);
}

test "a register write settles the counter first" {
    var t = timerWith(mode_sysclk_div8, 0);
    var i: u32 = 0;
    while (i < 100) : (i += 1) _ = t.step(1);

    t.write(0x8, 50);
    try expectEqual(@as(u32, 0), t.pending_ticks);
    try expectEqual(@as(u32, 12), t.counter);
}
