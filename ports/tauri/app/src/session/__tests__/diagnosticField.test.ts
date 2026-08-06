import { describe, expect, it } from "vitest";
import { formatDiagnosticFields, formatDiagnosticValue } from "../diagnosticField";

describe("formatDiagnosticValue", () => {
  it("renders strings verbatim", () => {
    expect(formatDiagnosticValue("real")).toBe("real");
  });

  it("renders booleans as true/false", () => {
    expect(formatDiagnosticValue(true)).toBe("true");
    expect(formatDiagnosticValue(false)).toBe("false");
  });

  it("renders whole numbers without a trailing decimal", () => {
    expect(formatDiagnosticValue(3)).toBe("3");
    expect(formatDiagnosticValue(-12)).toBe("-12");
  });

  it("renders fractional numbers with their shortest representation", () => {
    expect(formatDiagnosticValue(0.937)).toBe("0.937");
  });

  it("renders arrays as comma-joined, bracketed values", () => {
    expect(formatDiagnosticValue([0.1, 0.5, 0.9])).toBe("[0.1,0.5,0.9]");
  });

  it("renders nested objects as comma-joined key=value pairs, sorted by key", () => {
    expect(formatDiagnosticValue({ y: 20, x: 10, w: 30, h: 40 })).toBe("{h=40,w=30,x=10,y=20}");
  });

  it("renders null explicitly rather than dropping the field", () => {
    expect(formatDiagnosticValue(null)).toBe("null");
  });
});

describe("formatDiagnosticFields", () => {
  it("is a generic key=value serializer with zero per-field-name coupling", () => {
    // A mix of every value shape, including ones no current event actually
    // emits -- this is exactly what "future instrumentation appears
    // automatically" means: nothing here special-cases a key or event name.
    const fields = {
      confidence: 0.937,
      boxCount: 3,
      simulated: false,
      box: { x: 10, y: 20, w: 30, h: 40 },
      scores: [0.1, 0.5, 0.9],
    };

    expect(formatDiagnosticFields(fields)).toBe(
      "box={h=40,w=30,x=10,y=20} boxCount=3 confidence=0.937 scores=[0.1,0.5,0.9] simulated=false",
    );
  });

  it("returns an empty string for no fields", () => {
    expect(formatDiagnosticFields({})).toBe("");
  });
});
