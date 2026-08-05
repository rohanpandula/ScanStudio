// Doc-derived real-backend fixture loader (07-02 Task 1): reads one of the
// NDJSON files under src/session/__tests__/fixtures/real-backend/ from an
// absolute path, splits on newlines, drops empty lines, and JSON.parses each
// line in file order into an array of wire-message objects (events, or
// id/error responses). No other transformation. Framework-independent so any
// test suite can reuse it.
//
// These fixtures are TEST-ONLY: they simulate engine-originated wire traffic
// and are never imported by any production module (threat T-07-05).

import { readFileSync } from "node:fs";

export type FixtureWireMessage = {
  event?: string;
  id?: number;
  error?: { code: string; message: string; recoverable: boolean };
  method?: string;
  params?: unknown;
  payload?: unknown;
};

export function loadRealBackendFixture(absolutePath: string): FixtureWireMessage[] {
  const raw = readFileSync(absolutePath, "utf8");
  const messages: FixtureWireMessage[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    messages.push(JSON.parse(trimmed) as FixtureWireMessage);
  }
  return messages;
}
