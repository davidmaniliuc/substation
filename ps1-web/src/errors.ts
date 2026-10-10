/** Every failure the package reports. The numeric values are `ps1-wasm/src/codes.zig`'s. */
export type Ps1ErrorCode =
  | 'BAD_BIOS_SIZE'
  | 'BAD_CUE'
  | 'MULTI_FILE_CUE'
  | 'OOM'
  | 'BAD_SBI'
  | 'BAD_MEMCARD_SIZE'
  | 'BAD_SLOT'
  | 'STATE_BAD_MAGIC'
  | 'STATE_VERSION'
  | 'STATE_BIOS'
  | 'STATE_DISC'
  | 'STATE_CORRUPT'
  | 'STATE_NO_SPACE'
  | 'ENGINE_UNAVAILABLE'
  | 'BAD_CHD'
  | 'NO_SNAPSHOT'
  | 'NO_HISTORY'
  | 'BAD_PPF'
  | 'PPF_MISMATCH'
  | 'STATE_PATCH'
  /** The core panicked: the worker has stopped. */
  | 'CRASHED'
  | 'UNKNOWN';

const byValue: ReadonlyMap<number, Ps1ErrorCode> = new Map([
  [-1, 'BAD_BIOS_SIZE'],
  [-2, 'BAD_CUE'],
  [-3, 'MULTI_FILE_CUE'],
  [-4, 'OOM'],
  [-5, 'BAD_SBI'],
  [-6, 'BAD_MEMCARD_SIZE'],
  [-7, 'BAD_SLOT'],
  [-8, 'STATE_BAD_MAGIC'],
  [-9, 'STATE_VERSION'],
  [-10, 'STATE_BIOS'],
  [-11, 'STATE_DISC'],
  [-12, 'STATE_CORRUPT'],
  [-13, 'STATE_NO_SPACE'],
  [-14, 'ENGINE_UNAVAILABLE'],
  [-15, 'BAD_CHD'],
  [-16, 'NO_SNAPSHOT'],
  [-17, 'NO_HISTORY'],
  [-18, 'BAD_PPF'],
  [-19, 'PPF_MISMATCH'],
  [-20, 'STATE_PATCH'],
]);

const messages: Record<Ps1ErrorCode, string> = {
  BAD_BIOS_SIZE: 'A PS1 BIOS image is exactly 512 KB',
  BAD_CUE: 'The disc image or its cue sheet could not be read',
  MULTI_FILE_CUE: 'A cue with several FILEs needs its images concatenated (use discFromFiles)',
  OOM: 'Out of memory',
  BAD_SBI: 'The .sbi file is not a LibCrypt sidecar',
  BAD_MEMCARD_SIZE: 'A memory card image is exactly 128 KB',
  BAD_SLOT: 'Memory card slots are 0 and 1',
  STATE_BAD_MAGIC: 'Not a savestate',
  STATE_VERSION: 'The savestate was written by a newer version',
  STATE_BIOS: 'The savestate was made with a different BIOS',
  STATE_DISC: 'The savestate was made with a different disc',
  STATE_PATCH: 'The savestate was made with a different .ppf patch, or without one',
  STATE_CORRUPT: 'The savestate is damaged',
  STATE_NO_SPACE: 'The savestate did not fit its buffer',
  ENGINE_UNAVAILABLE: 'That CPU engine is not available in the browser',
  BAD_CHD: 'The CHD image could not be read',
  NO_SNAPSHOT: 'There is no runahead mark to return to',
  NO_HISTORY: 'There is no rewind history to step back through',
  BAD_PPF: 'The .ppf file is not a PPF patch this emulator can read',
  PPF_MISMATCH: 'The .ppf patch was made for a different version of this disc',
  CRASHED: 'The emulator stopped after an internal error',
  UNKNOWN: 'Unknown emulator error',
};

export class Ps1Error extends Error {
  override readonly name = 'Ps1Error';

  constructor(
    readonly code: Ps1ErrorCode,
    message: string = messages[code],
  ) {
    super(message);
  }
}

/** Passes a non-negative return through; throws the `Ps1Error` a negative one names. */
export function check(ret: number): number {
  if (ret >= 0) return ret;
  throw new Ps1Error(byValue.get(ret) ?? 'UNKNOWN');
}
