/** What the player accepts wherever bytes go in. A Blob is read lazily, in the worker. */
export type Binary = Blob | ArrayBuffer | Uint8Array;

/** A disc as the player takes it. `discFromFiles` builds one from picked files. */
export interface DiscInput {
  bin: Binary;
  /**
   * The disc's sheet: cue or `.ccd` as a string, an `.mds` as its raw bytes
   * (it is binary). Omit for a CHD, an eboot or a raw single-track `.bin`.
   */
  cue?: string | Uint8Array;
  /** The LibCrypt sidecar some PAL discs need. */
  sbi?: Binary;
  /** A PPF patch (a translation or fix) to apply to the disc. */
  ppf?: Binary;
  /** Which disc of an eboot (`.pbp`) to open, counting from 0. Any other image answers BAD_CUE for a non-zero index. */
  disc?: number;
  /** The file the disc was picked as, for display. */
  name?: string;
}

export async function toBytes(b: Binary): Promise<Uint8Array> {
  if (b instanceof Uint8Array) return b;
  if (b instanceof ArrayBuffer) return new Uint8Array(b);
  return new Uint8Array(await b.arrayBuffer());
}
