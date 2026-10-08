import { describe, expect, test } from 'bun:test';
import { MEMCARD_BYTES } from '../src/core';
import { bios, codeOf, hasBios, newCore } from './helpers';

describe('memory cards', () => {
  test('a card of the wrong size or slot is refused', async () => {
    const core = await newCore();
    expect(codeOf(() => core.loadMemcard(0, new Uint8Array(100)))).toBe('BAD_MEMCARD_SIZE');
    expect(codeOf(() => core.loadMemcard(2, new Uint8Array(MEMCARD_BYTES)))).toBe('BAD_SLOT');
    expect(codeOf(() => core.takeMemcard(-1))).toBe('BAD_SLOT');
  });

  test('a card the game has not written drains as null, loaded or not', async () => {
    const core = await newCore();
    expect(core.takeMemcard(0)).toBeNull();
    core.loadMemcard(1, new Uint8Array(MEMCARD_BYTES).fill(7));
    expect(core.takeMemcard(1)).toBeNull();
    core.reset();
    expect(core.takeMemcard(1)).toBeNull();
  });
});

describe('savestates', () => {
  test('a refused state leaves the machine exactly as it was', async () => {
    const core = await newCore();
    const before = core.saveState();
    expect(codeOf(() => core.loadState(new Uint8Array([1, 2, 3])))).toBe('STATE_BAD_MAGIC');
    expect(codeOf(() => core.loadState(new Uint8Array()))).toBe('STATE_BAD_MAGIC');
    expect(core.saveState()).toEqual(before);
  });

  test.skipIf(!hasBios)('save, load, save gives the same bytes', async () => {
    const core = await newCore();
    core.loadBios(bios());
    for (let i = 0; i < 120; i++) core.runFrame();
    const first = core.saveState();
    core.loadState(first);
    expect(core.saveState()).toEqual(first);
  }, 60_000);

  test.skipIf(!hasBios)('a state made under another BIOS is refused', async () => {
    const other = await newCore();
    const state = other.saveState(); // no BIOS loaded: an all-zero ROM
    const core = await newCore();
    core.loadBios(bios());
    expect(codeOf(() => core.loadState(state))).toBe('STATE_BIOS');
  });
});

describe('fast boot', () => {
  test('the setting can be changed at any time', async () => {
    const core = await newCore();
    expect(() => {
      core.setFastBoot(true);
      core.setFastBoot(false);
    }).not.toThrow();
  });
});
