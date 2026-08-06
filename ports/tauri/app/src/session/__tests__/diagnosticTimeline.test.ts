import { describe, expect, it } from "vitest";
import { DiagnosticTimeline, MAXIMUM_DIAGNOSTIC_ENTRIES, summaryLine } from "../diagnosticTimeline";

describe("DiagnosticTimeline", () => {
  it("bounds entries at 40 by default, matching the report's own event window", () => {
    expect(MAXIMUM_DIAGNOSTIC_ENTRIES).toBe(40);
    const timeline = new DiagnosticTimeline("session-test");
    for (let index = 1; index <= 50; index++) {
      timeline.record(`event-${index}`, {}, `2026-08-05T00:00:00Z-${index}`);
    }

    expect(timeline.entries).toHaveLength(40);
    expect(timeline.entries[0].event).toBe("event-11");
    expect(timeline.entries[39].event).toBe("event-50");
  });

  it("renders a stable structured summary line per entry", () => {
    const timeline = new DiagnosticTimeline("session-test", 10);
    timeline.record("device.connect.succeeded", { connected: true, kind: "real" }, "2026-07-28T00:08:18Z");
    timeline.record("preview.requested", { uiConnected: true }, "2026-07-28T00:09:00Z");

    expect(timeline.summaryLines).toEqual([
      "2026-07-28T00:08:18Z device.connect.succeeded connected=true kind=real",
      "2026-07-28T00:09:00Z preview.requested uiConnected=true",
    ]);
  });

  it("renders an event with no fields as just the timestamp and event name", () => {
    const timeline = new DiagnosticTimeline("session-test");
    timeline.record("session.started", {}, "2026-07-28T00:00:00Z");
    expect(timeline.summaryLines).toEqual(["2026-07-28T00:00:00Z session.started"]);
  });

  it("serializes to one JSON object per line, matching the mac build's durable log shape", () => {
    const timeline = new DiagnosticTimeline("session-jsonl", 10);
    timeline.record("preview.failed", { code: "NOT_CONNECTED", uiConnectedBefore: true }, "2026-07-28T00:09:01Z");

    const lines = timeline.toJsonl().split("\n");
    expect(lines).toHaveLength(1);
    const parsed = JSON.parse(lines[0]);
    expect(parsed).toEqual({
      timestamp: "2026-07-28T00:09:01Z",
      sessionId: "session-jsonl",
      event: "preview.failed",
      fields: { code: "NOT_CONNECTED", uiConnectedBefore: true },
    });
  });

  it("keeps numeric and boolean fields as real JSON types, not stringified text", () => {
    const timeline = new DiagnosticTimeline("typed-fields", 10);
    timeline.record("detector.scored", { confidence: 0.5, boxCount: 3, simulated: true });

    const parsed = JSON.parse(timeline.toJsonl());
    expect(parsed.fields.confidence).toBe(0.5);
    expect(parsed.fields.boxCount).toBe(3);
    expect(parsed.fields.simulated).toBe(true);
  });

  it("assigns every entry a session id, generating one when none is supplied", () => {
    const timeline = new DiagnosticTimeline();
    timeline.record("session.started");
    expect(timeline.entries[0].sessionId).toBe(timeline.sessionId);
    expect(timeline.sessionId.length).toBeGreaterThan(0);
  });
});

describe("summaryLine", () => {
  it("sorts fields by key, independent of insertion order", () => {
    const line = summaryLine({
      timestamp: "t",
      sessionId: "s",
      event: "e",
      fields: { b: 2, a: 1 },
    });
    expect(line).toBe("t e a=1 b=2");
  });
});
