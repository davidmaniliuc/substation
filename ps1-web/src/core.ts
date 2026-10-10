import { Ps1Error, check } from './errors';

export type Region = 'america' | 'europe' | 'japan';

export interface BiosInfo {
  /** False for an image missing from the core's table: unidentified, not invalid. */
  known: boolean;
  region: Region | null;
  version: string | null;
  description: string | null;
}

export interface DiscInfo {
  region: Region | null;
  /** `SLUS-00530`, or empty when the disc names none. */
  serial: string;
  /** The ISO volume id: often empty, and never a title. */
  volumeId: string;
  /** The catalogued title, or null for an uncatalogued serial. */
  title: string | null;
  /** The multi-disc set this disc belongs to, or null. */
  set: { title: string; disc: number } | null;
}

/** A disc already in memory. `Ps1Player` takes `DiscInput`, which also accepts Blobs. */
export interface DiscBytes {
  bin: Uint8Array;
  cue?: string;
  sbi?: Uint8Array;
  /** A PPF patch for the disc's sectors, applied on load and not kept. */
  ppf?: Uint8Array;
}

export const AUDIO_SAMPLE_RATE = 44100;

export interface Frame {
  /** RGBA, a VIEW into wasm memory: valid until the next `runFrame`. */
  rgba: Uint8ClampedArray;
  width: number;
  height: number;
}

export type CpuEngine = 'interpreter' | 'cached';

/** Anything `Ps1Core.create` can build a module from. */
export type WasmSource = WebAssembly.Module | BufferSource | URL | string;

export const BIOS_BYTES = 512 * 1024;
export const MEMCARD_BYTES = 128 * 1024;

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
  loadDisc(
    bin: number,
    binLen: number,
    cue: number,
    cueLen: number,
    sbi: number,
    sbiLen: number,
    ppf: number,
    ppfLen: number,
  ): number;
  identifyDisc(ptr: number, len: number): number;
  renderFrame(): number;
  frameWidth(): number;
  frameHeight(): number;
  isPal(): number;
  audioPtr(): number;
  readAudio(maxFloats: number): number;
  loadMemcard(slot: number, ptr: number, len: number): number;
  takeMemcard(slot: number, dst: number): number;
  saveStateSize(): number;
  saveState(dst: number, cap: number): number;
  loadState(ptr: number, len: number): number;
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
  private readonly encoder = new TextEncoder();

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

  /**
   * Inserts a disc. The image is copied into wasm memory once and stays
   * there until the next disc; a refused disc leaves the previous one in.
   */
  loadDisc(disc: DiscBytes): void {
    const cue = disc.cue === undefined ? new Uint8Array() : this.encoder.encode(disc.cue);
    const sbi = disc.sbi ?? new Uint8Array();
    const ppf = disc.ppf ?? new Uint8Array();
    const bin = this.copyIn(disc.bin);
    let owned = false;
    try {
      this.withCopy(cue, (cuePtr) =>
        this.withCopy(sbi, (sbiPtr) =>
          this.withCopy(ppf, (ppfPtr) =>
            check(
              this.wasm.loadDisc(
                bin,
                disc.bin.byteLength,
                cuePtr,
                cue.byteLength,
                sbiPtr,
                sbi.byteLength,
                ppfPtr,
                ppf.byteLength,
              ),
            ),
          ),
        ),
      );
      owned = true; // the module keeps the image now
    } finally {
      if (!owned) this.release(bin, disc.bin.byteLength);
    }
  }

  /** Region, serial and title, with no BIOS. Pass the WHOLE image. */
  identifyDisc(bin: Uint8Array): DiscInfo {
    return this.withCopy(bin, (p) => this.result(this.wasm.identifyDisc(p, bin.byteLength)) as DiscInfo);
  }

  runFrame(): void {
    this.wasm.runFrame();
  }

  /** The displayed picture. A view, not a copy: draw it before the next `runFrame`. */
  frame(): Frame {
    const p = ptr(this.wasm.renderFrame());
    const width = this.wasm.frameWidth();
    const height = this.wasm.frameHeight();
    return { rgba: new Uint8ClampedArray(this.wasm.memory.buffer, p, width * height * 4), width, height };
  }

  /** True for a 50 Hz machine. */
  get isPal(): boolean {
    return this.wasm.isPal() !== 0;
  }

  /** Drains interleaved stereo samples at 44100 Hz. A copy, so it can be transferred. */
  readAudio(maxFloats = 8192): Float32Array {
    const n = this.wasm.readAudio(maxFloats);
    return new Float32Array(this.wasm.memory.buffer, ptr(this.wasm.audioPtr()), n).slice();
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

  /** Installs a 128 KB card image in slot 0 or 1. */
  loadMemcard(slot: number, bytes: Uint8Array): void {
    this.withCopy(bytes, (p) => check(this.wasm.loadMemcard(slot, p, bytes.byteLength)));
  }

  /** The card's image if the game has written it since the last call, else null. A drain. */
  takeMemcard(slot: number): Uint8Array | null {
    return this.withScratch(MEMCARD_BYTES, (dst) =>
      check(this.wasm.takeMemcard(slot, dst)) === 1
        ? new Uint8Array(this.wasm.memory.buffer, dst, MEMCARD_BYTES).slice()
        : null,
    );
  }

  /** The whole machine. It loads only under the same BIOS and disc. */
  saveState(): Uint8Array {
    const size = this.wasm.saveStateSize();
    if (size === 0) throw new Ps1Error('UNKNOWN', 'The machine could not be measured for a savestate');
    return this.withScratch(size, (dst) => {
      const len = check(this.wasm.saveState(dst, size));
      return new Uint8Array(this.wasm.memory.buffer, dst, len).slice();
    });
  }

  /** All-or-nothing: a refused state leaves the running machine untouched. */
  loadState(bytes: Uint8Array): void {
    this.withCopy(bytes, (p) => check(this.wasm.loadState(p, bytes.byteLength)));
  }

  /** Runs `use` on an uninitialised wasm buffer of `len` bytes, freeing it afterwards. */
  private withScratch<T>(len: number, use: (p: number) => T): T {
    const p = ptr(this.wasm.alloc(len));
    if (p === 0) throw new Ps1Error('OOM');
    try {
      return use(p);
    } finally {
      this.wasm.free(p, len);
    }
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
