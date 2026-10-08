import { Ps1Error, check } from './errors';

export type Region = 'america' | 'europe' | 'japan';

export interface BiosInfo {
  /** False for an image missing from the core's table: unidentified, not invalid. */
  known: boolean;
  region: Region | null;
  version: string | null;
  description: string | null;
}

export type CpuEngine = 'interpreter' | 'cached';

/** Anything `Ps1Core.create` can build a module from. */
export type WasmSource = WebAssembly.Module | BufferSource | URL | string;

export const BIOS_BYTES = 512 * 1024;

/** The wasm exports, as `ps1-wasm/src/*.zig` declares them. Pointers are `usize`. */
interface Exports {
  memory: WebAssembly.Memory;
  init(): number;
  reset(): number;
  runFrame(): void;
  setButtons(mask: number): void;
  setCpuEngine(engine: number): number;
  setFastBoot(on: number): void;
  alloc(len: number): number;
  free(ptr: number, len: number): void;
  resultPtr(): number;
  loadBios(ptr: number, len: number): number;
}

const engines: Record<CpuEngine, number> = { interpreter: 0, cached: 1 };
// Not in `CpuEngine`: the JIT emits arm64 code and no wasm build has it.
// Kept so a caller passing it gets ENGINE_UNAVAILABLE rather than a silent 0.
const jitEngine = 2;

/** wasm32 pointers arrive as signed i32: past 2 GB they read negative. */
const ptr = (p: number) => p >>> 0;

export async function compile(source: WasmSource): Promise<WebAssembly.Module> {
  if (source instanceof WebAssembly.Module) return source;
  if (source instanceof URL || typeof source === 'string') {
    const response = await fetch(source);
    if (!response.ok) throw new Error(`ps1.wasm: HTTP ${response.status} fetching ${source}`);
    return WebAssembly.compile(await response.arrayBuffer());
  }
  return WebAssembly.compile(source);
}

/**
 * One emulated PlayStation, synchronous and DOM-free: it runs in a worker
 * and under `bun test`. Every refusal throws a `Ps1Error`.
 */
export class Ps1Core {
  private readonly decoder = new TextDecoder();

  private constructor(private readonly wasm: Exports) {}

  /**
   * Instantiates the module. `machine: false` builds no machine, for a
   * caller that only identifies discs.
   */
  static async create(
    source: WasmSource = new URL('./ps1.wasm', import.meta.url),
    options: { machine?: boolean; onLog?: (line: string) => void } = {},
  ): Promise<Ps1Core> {
    const module = await compile(source);
    const log = options.onLog ?? ((line: string) => console.log('[ps1]', line));
    const decoder = new TextDecoder();
    let exports: Exports | undefined;
    const instance = await WebAssembly.instantiate(module, {
      env: {
        jsConsoleLog: (p: number, len: number) =>
          log(decoder.decode(new Uint8Array(exports!.memory.buffer, ptr(p), len))),
      },
    });
    exports = instance.exports as unknown as Exports;
    if (options.machine ?? true) {
      check(exports.init());
      exports.setButtons(0xffff);
    }
    return new Ps1Core(exports);
  }

  loadBios(bytes: Uint8Array): BiosInfo {
    return this.withCopy(bytes, (p) => this.result(this.wasm.loadBios(p, bytes.byteLength)) as BiosInfo);
  }

  runFrame(): void {
    this.wasm.runFrame();
  }

  /** `sio.zig`'s convention: a 0 bit is PRESSED, 0xFFFF is idle. */
  setButtons(mask: number): void {
    this.wasm.setButtons(mask & 0xffff);
  }

  /** A new machine with the same BIOS, disc and memory cards. */
  reset(): void {
    check(this.wasm.reset());
  }

  /** Skips the BIOS intro on the next boot of a PlayStation disc. */
  setFastBoot(on: boolean): void {
    this.wasm.setFastBoot(on ? 1 : 0);
  }

  setCpuEngine(engine: CpuEngine): void {
    check(this.wasm.setCpuEngine(engines[engine] ?? jitEngine));
  }

  /** Copies `bytes` into a fresh wasm buffer. Empty input allocates nothing and is pointer 0. */
  private copyIn(bytes: Uint8Array): number {
    if (bytes.byteLength === 0) return 0;
    const p = ptr(this.wasm.alloc(bytes.byteLength));
    if (p === 0) throw new Ps1Error('OOM');
    new Uint8Array(this.wasm.memory.buffer, p, bytes.byteLength).set(bytes);
    return p;
  }

  private release(p: number, len: number): void {
    if (len > 0) this.wasm.free(p, len);
  }

  /** Runs `use` on a wasm copy of `bytes`, freeing it afterwards. */
  private withCopy<T>(bytes: Uint8Array, use: (p: number) => T): T {
    const p = this.copyIn(bytes);
    try {
      return use(p);
    } finally {
      this.release(p, bytes.byteLength);
    }
  }

  /** Parses the JSON an export left in its result buffer; `len` is its return. */
  private result(len: number): unknown {
    const bytes = new Uint8Array(this.wasm.memory.buffer, ptr(this.wasm.resultPtr()), check(len));
    return JSON.parse(this.decoder.decode(bytes));
  }
}
