// A minimal, dependency-free ZIP writer using the uncompressed ("stored")
// method only -- the Tauri counterpart of StoredZipWriter
// (app/ScanStudio/Sources/ScanStudioKit/DiagnosticBundle.swift). "Save
// Diagnostic Bundle..." (T-ERR-04) favors a small, easily-audited
// implementation over a compression dependency: the JSONL log and report
// text are already small, and a preview raster is already a compressed
// image format (PNG/TIFF), so stored-only costs little.

export interface ZipEntry {
  name: string;
  data: Uint8Array;
}

// A fixed, valid DOS date/time (1980-01-01, the DOS epoch) so archive bytes
// are deterministic and never depend on wall-clock time -- the bundle's own
// report.txt already timestamps the export.
const DOS_TIME = 0;
const DOS_DATE = 0x21;
// General-purpose bit 11: filenames/comments are UTF-8, per the ZIP
// appendix D "language encoding flag" -- entry names are never guaranteed
// ASCII (e.g. a preview file's original extension).
const UTF8_NAME_FLAG = 0x0800;

const CRC_TABLE = buildCrcTable();

function buildCrcTable(): Uint32Array {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index++) {
    let value = index;
    for (let bit = 0; bit < 8; bit++) {
      value = (value & 1) !== 0 ? (0xedb88320 ^ (value >>> 1)) : value >>> 1;
    }
    table[index] = value >>> 0;
  }
  return table;
}

function crc32(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

class ByteWriter {
  #chunks: Uint8Array[] = [];
  #length = 0;

  get length(): number {
    return this.#length;
  }

  push(bytes: Uint8Array): void {
    this.#chunks.push(bytes);
    this.#length += bytes.length;
  }

  pushUint16LE(value: number): void {
    this.push(new Uint8Array([value & 0xff, (value >>> 8) & 0xff]));
  }

  pushUint32LE(value: number): void {
    this.push(
      new Uint8Array([value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff]),
    );
  }

  toUint8Array(): Uint8Array {
    const output = new Uint8Array(this.#length);
    let offset = 0;
    for (const chunk of this.#chunks) {
      output.set(chunk, offset);
      offset += chunk.length;
    }
    return output;
  }
}

export function createStoredZip(entries: ZipEntry[]): Uint8Array {
  const output = new ByteWriter();
  const central = new ByteWriter();
  let recordCount = 0;
  const nameEncoder = new TextEncoder();

  for (const entry of entries) {
    const nameBytes = nameEncoder.encode(entry.name);
    const crc = crc32(entry.data);
    const size = entry.data.length;
    const localHeaderOffset = output.length;

    output.pushUint32LE(0x04034b50);
    output.pushUint16LE(20);
    output.pushUint16LE(UTF8_NAME_FLAG);
    output.pushUint16LE(0);
    output.pushUint16LE(DOS_TIME);
    output.pushUint16LE(DOS_DATE);
    output.pushUint32LE(crc);
    output.pushUint32LE(size);
    output.pushUint32LE(size);
    output.pushUint16LE(nameBytes.length);
    output.pushUint16LE(0);
    output.push(nameBytes);
    output.push(entry.data);

    central.pushUint32LE(0x02014b50);
    central.pushUint16LE(20);
    central.pushUint16LE(20);
    central.pushUint16LE(UTF8_NAME_FLAG);
    central.pushUint16LE(0);
    central.pushUint16LE(DOS_TIME);
    central.pushUint16LE(DOS_DATE);
    central.pushUint32LE(crc);
    central.pushUint32LE(size);
    central.pushUint32LE(size);
    central.pushUint16LE(nameBytes.length);
    central.pushUint16LE(0);
    central.pushUint16LE(0);
    central.pushUint16LE(0);
    central.pushUint16LE(0);
    central.pushUint32LE(0);
    central.pushUint32LE(localHeaderOffset);
    central.push(nameBytes);

    recordCount += 1;
  }

  const centralDirectoryOffset = output.length;
  output.push(central.toUint8Array());

  output.pushUint32LE(0x06054b50);
  output.pushUint16LE(0);
  output.pushUint16LE(0);
  output.pushUint16LE(recordCount);
  output.pushUint16LE(recordCount);
  output.pushUint32LE(central.length);
  output.pushUint32LE(centralDirectoryOffset);
  output.pushUint16LE(0);

  return output.toUint8Array();
}
