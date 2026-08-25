import { describe, expect, it } from "vitest";
import { buildErrorReportText, MAXIMUM_RECENT_DIAGNOSTIC_EVENTS } from "../errorReport";

const baseContext = {
  errorCode: "NOT_CONNECTED",
  errorMessage: "NOT_CONNECTED: no device is open",
  recentDiagnosticEvents: [] as string[],
};

describe("buildErrorReportText", () => {
  it("starts with the exact report header line, matching the mac build byte-for-byte", () => {
    const text = buildErrorReportText(baseContext);
    expect(text.startsWith("ScanStudio error report\n")).toBe(true);
  });

  it("renders every build-identifying header field, falling back to unknown instead of omitting it", () => {
    const text = buildErrorReportText({ ...baseContext, scanStudioVersion: "0.3.0-alpha.11" });

    expect(text).toContain("ScanStudio version: 0.3.0-alpha.11");
    expect(text).toContain("Operating system: unknown");
    expect(text).toContain("CPU architecture: unknown");
    expect(text).toContain("Scanner firmware: unknown");
    expect(text).toContain("Adapter: unknown");
    expect(text).toContain("Holder: unknown");
  });

  it("populates known scanner identity and holder state", () => {
    const text = buildErrorReportText({
      ...baseContext,
      scanStudioVersion: "0.3.0-alpha.11",
      operatingSystem: "Windows 10.0.22631",
      cpuArchitecture: "x86_64",
      scannerFirmware: "1.02",
      scannerAdapter: "SA-21",
      scannerHolder: "roll36",
    });

    expect(text).toContain("Operating system: Windows 10.0.22631");
    expect(text).toContain("CPU architecture: x86_64");
    expect(text).toContain("Scanner firmware: 1.02");
    expect(text).toContain("Adapter: SA-21");
    expect(text).toContain("Holder: roll36");
  });

  it("includes up to the last 40 diagnostic events, dropping older ones", () => {
    const events = Array.from({ length: 50 }, (_, index) => `2026-08-05T00:00:00Z-${index + 1} event-${index + 1}`);
    const text = buildErrorReportText({ ...baseContext, recentDiagnosticEvents: events });

    expect(MAXIMUM_RECENT_DIAGNOSTIC_EVENTS).toBe(40);
    expect(text).toContain("- 2026-08-05T00:00:00Z-50 event-50");
    expect(text).toContain("- 2026-08-05T00:00:00Z-11 event-11");
    expect(text).not.toContain("- 2026-08-05T00:00:00Z-10 event-10");
  });

  it("omits the Recent diagnostic events section entirely when there are none", () => {
    const text = buildErrorReportText(baseContext);
    expect(text).not.toContain("Recent diagnostic events:");
  });

  it("never exposes an absolute local log path in share-facing report text", () => {
    const withPath = buildErrorReportText({
      ...baseContext,
      diagnosticLogPath: "/Users/tester/.scanstudio/diagnostics/session-1234.jsonl",
    });
    expect(withPath).not.toContain("/Users/tester");
    expect(withPath).toContain("Local log: <redacted path>");

    const withoutPath = buildErrorReportText(baseContext);
    expect(withoutPath).not.toContain("Local log:");
  });

  it("appends the Windows setup check section only while probe results exist", () => {
    const withProbes = buildErrorReportText({
      ...baseContext,
      setupCheckProbes: [
        { id: "wsl-status", status: "Ok", detail: "WSL2 with Ubuntu-24.04 default" },
        { id: "bridge-which", status: "Fail", detail: "scanstudio-bridge not found on PATH inside WSL" },
      ],
    });
    expect(withProbes).toContain("Windows setup check:");
    expect(withProbes).toContain("- wsl-status: Ok -- WSL2 with Ubuntu-24.04 default");
    expect(withProbes).toContain("- bridge-which: Fail -- scanstudio-bridge not found on PATH inside WSL");

    const withoutProbes = buildErrorReportText(baseContext);
    expect(withoutProbes).not.toContain("Windows setup check:");

    const withEmptyProbes = buildErrorReportText({ ...baseContext, setupCheckProbes: [] });
    expect(withEmptyProbes).not.toContain("Windows setup check:");
  });

  it("sanitizes error messages, diagnostic events, setup details, paths, film metadata, and identifiers", () => {
    const privateValues = [
      "/Users/alice/Photo Work/roll.scanstudio",
      "/private/var/folders/ab/session/preview.tiff",
      "/tmp/studio-job/engine.log",
      "/Volumes/Film Archive/master.tif",
      "Ilford HP5 Plus",
      "Leica M6",
      "Summicron 50mm",
      "coolscan3:usb:libusb:000:013",
      "NK12345",
    ];
    const text = buildErrorReportText({
      ...baseContext,
      errorMessage:
        `project=${privateValues[0]}; preview=${privateValues[1]}; filmStock=${privateValues[4]}; ` +
        `camera=${privateValues[5]}; lens=${privateValues[6]}; deviceId=${privateValues[7]}; serial=${privateValues[8]}`,
      recentDiagnosticEvents: [
        `write.failed path=${privateValues[2]} filmStock=${privateValues[4]} deviceId=${privateValues[7]}`,
      ],
      setupCheckProbes: [
        { id: "bridge", status: "Fail", detail: `log=${privateValues[3]}; serial=${privateValues[8]}` },
      ],
      sensitiveValues: privateValues,
    });

    for (const value of privateValues) expect(text).not.toContain(value);
    expect(text).toContain("<redacted path>");
    expect(text).toContain("<redacted>");
  });

  it("always ends with the honest no-automatic-attachments footer", () => {
    const text = buildErrorReportText(baseContext);
    expect(text.trimEnd().endsWith("No images, receipts, or raw logs are attached automatically.")).toBe(true);
  });

  it("includes the error code and message", () => {
    const text = buildErrorReportText({
      ...baseContext,
      errorCode: "REFEED_REQUIRED",
      errorMessage: "REFEED_REQUIRED: refeed the strip and retry",
    });
    expect(text).toContain("Error code: REFEED_REQUIRED");
    expect(text).toContain("Message:\nREFEED_REQUIRED: refeed the strip and retry");
  });
});
