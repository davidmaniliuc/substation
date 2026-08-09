const Voice = @import("voice.zig").Voice;

pub const AdsrState = enum {
    Off,
    Attack,
    Decay,
    Sustain,
    Release,
};

/// Advances one voice's ADSR envelope by one sample tick. Extracted from
/// `Voice.stepAdsr`; `Voice` keeps a `stepAdsr` alias to this function so
/// `voice.stepAdsr()` still works at every call site.
pub fn step(voice: *Voice) void {
    if (voice.env.state == .Off) {
        voice.env.current_ad_vol = 0;
        return;
    }

    const ar = (voice.regs.adsr1 >> 8) & 0x7F;
    const ar_shift = (ar >> 2) & 0x1F;
    const ar_step = @as(i32, ar & 3) + 4;

    const dr_shift = (voice.regs.adsr1 >> 4) & 0x0F;
    const dr_step: i32 = 8;

    var sl = (@as(i32, @intCast(voice.regs.adsr1 & 0x0F)) + 1) * 0x800;
    if (sl > 0x7FFF) sl = 0x7FFF;

    const sr = (voice.regs.adsr2 >> 6) & 0x7F;
    const sr_shift = (sr >> 2) & 0x1F;
    const sr_step = @as(i32, sr & 3) + 4;

    const rr_shift = voice.regs.adsr2 & 0x1F;
    const rr_step: i32 = 8;

    var shift: u32 = 0;
    var step_val: i32 = 0;
    var is_decrease = false;
    var is_exponential = false;

    switch (voice.env.state) {
        .Attack => {
            shift = ar_shift;
            step_val = ar_step;
            is_exponential = ((voice.regs.adsr1 & 0x8000) != 0);
            is_decrease = false;
        },
        .Decay => {
            shift = dr_shift;
            step_val = dr_step;
            is_exponential = true;
            is_decrease = true;
        },
        .Sustain => {
            shift = sr_shift;
            is_decrease = ((voice.regs.adsr2 & 0x4000) != 0);
            if (is_decrease) {
                step_val = 8;
                is_exponential = true;
            } else {
                step_val = sr_step;
                is_exponential = ((voice.regs.adsr2 & 0x8000) != 0);
            }
        },
        .Release => {
            shift = rr_shift;
            step_val = rr_step;
            is_exponential = true;
            is_decrease = true;
        },
        .Off => return,
    }

    // Exponential increase: slow down when level > 0x6000 (hardware "fake" exponential)
    var cycles = if (shift > 11) @as(u32, 1) << @as(u5, @truncate(shift - 11)) else 1;
    if (is_exponential and !is_decrease and voice.env.current_ad_vol > 0x6000) {
        cycles *= 4;
    }
    voice.env.cycles += 1;
    if (voice.env.cycles < cycles) return;
    voice.env.cycles = 0;

    const shift_diff = if (shift < 11) (11 - shift) else 0;
    var actual_step = step_val << @as(u5, @truncate(shift_diff));

    if (is_exponential and is_decrease) {
        // Exponential decrease: the step scales with the current volume.
        // Avocado (voice.cpp:67-73) keeps the step NEGATIVE and arithmetic-
        // shifts it, so the magnitude can never round down to 0 -- that is
        // what guarantees a release actually terminates. Our step is
        // positive, so negate around the shift to get the same floor-toward
        // -infinity behaviour. Scaling the positive step directly floors to
        // 0 instead and strands the voice at a small non-zero level with
        // `is_on` set forever; games that poll for a free voice then never
        // trigger another sound effect.
        actual_step = -((-actual_step * voice.env.current_ad_vol) >> 15);
    }

    if (is_decrease) {
        voice.env.current_ad_vol -= actual_step;
        if (voice.env.current_ad_vol < 0) voice.env.current_ad_vol = 0;
    } else {
        voice.env.current_ad_vol += actual_step;
        if (voice.env.current_ad_vol > 0x7FFF) voice.env.current_ad_vol = 0x7FFF;
    }

    switch (voice.env.state) {
        .Attack => {
            if (voice.env.current_ad_vol >= 0x7FFF) {
                voice.env.current_ad_vol = 0x7FFF;
                voice.env.state = .Decay;
                voice.env.cycles = 0;
            }
        },
        .Decay => {
            if (voice.env.current_ad_vol <= sl) {
                voice.env.current_ad_vol = sl;
                voice.env.state = .Sustain;
                voice.env.cycles = 0;
            }
        },
        .Sustain => {},
        .Release => {
            if (voice.env.current_ad_vol <= 0) {
                voice.env.current_ad_vol = 0;
                voice.env.state = .Off;
                voice.is_on = false;
                voice.env.cycles = 0;
            }
        },
        .Off => {},
    }
}
