import { describe, expect, it } from "vitest";
import { createStoredZip, type ZipEntry } from "../zip";

/** Minimal reader for the exact "stored" (uncompressed) ZIP shape
 * createStoredZip produces -- enough to round-trip-verify contents without
 * a third-party archive library in the test target. */
function readStoredZipEntries(zip: Uint8Array): { name: string; data: Uint8Array }[] {
  const view = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
  const entries: { name: string; data: Uint8Array }[] = [];
  let offset = 0;

  while (offset < zip.length) {
    if (view.getUint32(offset, true) !== 0x04034b50) break;
    const compressedSize = view.getUint32(offset + 18, true);
    const nameLength = view.getUint16(offset + 26, true);
    const extraLength = view.getUint16(offset + 28, true);
    const nameStart = offset + 30;
    const nameEnd = nameStart + nameLength;
    const name = new TextDecoder().decode(zip.slice(nameStart, nameEnd));
    const dataStart = nameEnd + extraLength;
    const dataEnd = dataStart + compressedSize;
    entries.push({ name, data: zip.slice(dataStart, dataEnd) });
    offset = dataEnd;
  }
  return entries;
}

describe("createStoredZip", () => {
  it("round-trips filenames and bytes exactly, including an empty entry", () => {
    const entries: ZipEntry[] = [
      { name: "diagnostics.jsonl", data: new TextEncoder().encode('{"event":"session.started"}') },
      { name: "report.txt", data: new TextEncoder().encode("ScanStudio error report\n") },
      { name: "empty.txt", data: new Uint8Array() },
    ];

    const zip = createStoredZip(entries);

    expect(Array.from(zip.slice(0, 4))).toEqual([0x50, 0x4b, 0x03, 0x04]);
    // The 22-byte End Of Central Directory record is the tail of the file
    // whenever the (unused) archive comment is empty, as here -- its
    // signature is the record's first 4 bytes, not the file's last 4.
    expect(Array.from(zip.slice(zip.length - 22, zip.length - 18))).toEqual([0x50, 0x4b, 0x05, 0x06]);

    const readBack = readStoredZipEntries(zip);
    expect(readBack.map((entry) => entry.name)).toEqual(entries.map((entry) => entry.name));
    readBack.forEach((entry, index) => {
      expect(Array.from(entry.data)).toEqual(Array.from(entries[index].data));
    });
  });

  it("produces a well-formed archive with zero entries", () => {
    const zip = createStoredZip([]);
    expect(zip.length).toBe(22);
    expect(Array.from(zip.slice(0, 4))).toEqual([0x50, 0x4b, 0x05, 0x06]);
    expect(readStoredZipEntries(zip)).toEqual([]);
  });

  it("supports multiple entries with distinct byte content", () => {
    const zip = createStoredZip([
      { name: "a.bin", data: new Uint8Array([1, 2, 3]) },
      { name: "b.bin", data: new Uint8Array([4, 5, 6, 7]) },
    ]);
    const readBack = readStoredZipEntries(zip);
    expect(readBack).toHaveLength(2);
    expect(Array.from(readBack[0].data)).toEqual([1, 2, 3]);
    expect(Array.from(readBack[1].data)).toEqual([4, 5, 6, 7]);
  });
});
