import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'bun:test';
import { bios, codeOf, hasBios, newCore, root, syntheticDisc } from './helpers';

const helloWorld = () => new Uint8Array(readFileSync(root + 'test-roms/peterlemon/hello-world/HelloWorld16BPP.exe'));

describe('executables', () => {
  test('identifyExe reads a PS-X EXE and refuses anything else', async () => {
    const core = await newCore(false);
    const info = core.identifyExe(helloWorld());
    expect(info.format).toBe('psexe');
    expect(info.fingerprint).toMatch(/^[0-9a-f]{16}$/);
    expect(codeOf(() => core.identifyExe(new TextEncoder().encode('MZ not a PlayStation program')))).toBe('BAD_EXE');
  });

  test('a file it cannot boot, or a libps that is not a PS-X EXE, is refused', async () => {
    const core = await newCore();
    expect(codeOf(() => core.loadExe(new Uint8Array(64)))).toBe('BAD_EXE');
    expect(codeOf(() => core.loadExe(helloWorld(), new TextEncoder().encode('\x7FELF')))).toBe('BAD_EXE');
  });

  test('a running executable has no tray to swap, and loadDisc replaces it', async () => {
    const core = await newCore();
    core.loadExe(helloWorld());
    expect(codeOf(() => core.swapDisc({ bin: syntheticDisc() }))).toBe('BUSY');
    core.loadDisc({ bin: syntheticDisc() });
    expect(() => core.swapDisc({ bin: syntheticDisc() })).not.toThrow();
  });

  test.skipIf(!hasBios)('the program runs in place of the shell, and its state names it', async () => {
    const run = async (exe: boolean) => {
      const core = await newCore();
      core.setCpuEngine('cached');
      core.loadBios(bios());
      if (exe) core.loadExe(helloWorld());
      for (let i = 0; i < 180; i++) core.runFrame();
      return core;
    };
    const program = await run(true);
    const shell = await run(false);
    expect(program.frame().rgba.join()).not.toBe(shell.frame().rgba.join());

    const state = program.saveState();
    shell.loadDisc({ bin: syntheticDisc() });
    expect(codeOf(() => shell.loadState(state))).toBe('STATE_DISC');
    program.reset();
    expect(() => program.loadState(state)).not.toThrow();
  });
});
