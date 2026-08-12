// Precision-safe PartialDate editor (07-01 Task 2), mirroring
// BatchInspectorView.swift's PartialDateEditor (lines 1388-1490): a 4-way
// precision selector (Exact / Month / Year / Unknown) that NEVER fabricates a
// value the user didn't provide -- a value of null and {kind:"unknown"} both
// render as "Unknown" with no sub-fields, and switching to a MORE SPECIFIC
// precision than `value` currently carries holds that choice as local pending
// state until the user supplies the missing component(s) (pendingPrecision,
// distinct from `value`). Only then is onChange called with a fully-formed
// PartialDate. No placeholder day, month, or year is ever invented.

import { useEffect, useState } from "react";
import type { PartialDate } from "../session/wire/types";
import styles from "./Metadata.module.css";

export type DatePrecision = "exact" | "month" | "year" | "unknown";

export interface PartialDateEditorProps {
  value: PartialDate | null;
  onChange: (next: PartialDate | null) => void;
}

const MONTHS: number[] = Array.from({ length: 12 }, (_, i) => i + 1);

const PRECISIONS: Array<{ key: DatePrecision; label: string; testId: string }> = [
  { key: "exact", label: "Exact", testId: "date-precision-exact" },
  { key: "month", label: "Month", testId: "date-precision-month" },
  { key: "year", label: "Year", testId: "date-precision-year" },
  { key: "unknown", label: "Unknown", testId: "date-precision-unknown" },
];

function currentYearOf(value: PartialDate | null): number | null {
  switch (value?.kind) {
    case "exact": {
      const year = Number(value.date.slice(0, 4));
      return Number.isFinite(year) ? year : null;
    }
    case "monthOnly":
    case "yearOnly":
      return value.year;
    default:
      return null;
  }
}

function currentMonthOf(value: PartialDate | null): number | null {
  switch (value?.kind) {
    case "exact": {
      const parts = value.date.split("-");
      if (parts.length > 1) {
        const month = Number(parts[1]);
        return Number.isFinite(month) ? month : null;
      }
      return null;
    }
    case "monthOnly":
      return value.month;
    default:
      return null;
  }
}

function derivedPrecision(value: PartialDate | null): DatePrecision {
  switch (value?.kind) {
    case "exact":
      return "exact";
    case "monthOnly":
      return "month";
    case "yearOnly":
      return "year";
    default:
      return "unknown";
  }
}

export default function PartialDateEditor({ value, onChange }: PartialDateEditorProps) {
  // Local pending selection held while a more-specific precision was tapped
  // but the missing components have not been supplied yet -- distinct from
  // the authoritative `value` (mirrors Swift's @State pendingPrecision).
  const [pendingPrecision, setPendingPrecision] = useState<DatePrecision | null>(null);
  const [draftYear, setDraftYear] = useState("");
  const [draftMonth, setDraftMonth] = useState(1);

  const precision = pendingPrecision ?? derivedPrecision(value);

  // Content-keyed resync: when the authoritative value changes out from under
  // this view (a revert, a different frame/project's draft), drafts follow it
  // and never keep a stale pending guess visible.
  const valueKey = JSON.stringify(value ?? null);
  useEffect(() => {
    const year = currentYearOf(value);
    setDraftYear(year === null ? "" : String(year));
    setDraftMonth(currentMonthOf(value) ?? 1);
    setPendingPrecision(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [valueKey]);

  const selectPrecision = (next: DatePrecision): void => {
    switch (next) {
      case "unknown":
        setPendingPrecision(null);
        onChange({ kind: "unknown" });
        break;
      case "month": {
        const year = currentYearOf(value);
        const month = currentMonthOf(value);
        if (year !== null && month !== null) {
          // Both known components may be carried over without increasing
          // precision or inventing metadata.
          setPendingPrecision(null);
          onChange({ kind: "monthOnly", year, month });
        } else {
          if (year !== null) setDraftYear(String(year));
          // The select must display an option, but its January draft is not
          // authoritative until the operator deliberately changes it.
          setPendingPrecision("month");
        }
        break;
      }
      case "year": {
        const year = currentYearOf(value);
        if (year !== null) {
          setPendingPrecision(null);
          onChange({ kind: "yearOnly", year });
        } else {
          setPendingPrecision("year");
        }
        break;
      }
      case "exact":
        // Always defers: "Exact" implies a specific day, which is never
        // inferable from a lesser precision -- the user must pick one.
        setPendingPrecision("exact");
        break;
    }
  };

  // Digits-only, capped at 4, and never commits unless a full 4-digit year
  // exists (a partial "2"/"20" stays local, never pushed as year 2 or 20).
  const handleYearInput = (raw: string): void => {
    const digits = raw.replace(/[^0-9]/g, "").slice(0, 4);
    setDraftYear(digits);
    if (digits.length !== 4) return;
    const year = Number(digits);
    if (precision === "month") {
      onChange({ kind: "monthOnly", year, month: draftMonth });
    } else if (precision === "year") {
      onChange({ kind: "yearOnly", year });
    } else {
      return;
    }
    setPendingPrecision(null);
  };

  const handleMonthInput = (month: number): void => {
    setDraftMonth(month);
    if (draftYear.length !== 4) return;
    onChange({ kind: "monthOnly", year: Number(draftYear), month });
    setPendingPrecision(null);
  };

  return (
    <div data-testid="partial-date-editor">
      <div className={styles.radioGroup} role="radiogroup" aria-label="Date precision">
        {PRECISIONS.map(({ key, label, testId }) => (
          <div className={styles.radioRow} key={key}>
            <input
              id={`date-precision-${key}`}
              className={styles.checkboxInput}
              type="radio"
              name="date-precision"
              data-testid={testId}
              value={key}
              checked={precision === key}
              onChange={() => selectPrecision(key)}
            />
            <label className={styles.radioLabel} htmlFor={`date-precision-${key}`}>
              {label}
            </label>
          </div>
        ))}
      </div>
      {precision === "exact" && (
        <div className={styles.fieldRow}>
          <input
            id="date-exact-input"
            className={styles.selectInput}
            type="date"
            data-testid="date-exact-input"
            // Neutral starting appearance: empty when no exact date is stored.
            // Nothing is written to `value` until the user actually picks one.
            value={value?.kind === "exact" ? value.date : ""}
            onChange={(event) => {
              if (event.target.value === "") return;
              setPendingPrecision(null);
              onChange({ kind: "exact", date: event.target.value });
            }}
          />
        </div>
      )}
      {precision === "month" && (
        <div className={styles.fieldRow}>
          <input
            id="date-year-input"
            className={`${styles.textInput} ${styles.fixedWidth}`}
            type="text"
            inputMode="numeric"
            placeholder="YYYY"
            data-testid="date-year-input"
            value={draftYear}
            onChange={(event) => handleYearInput(event.target.value)}
          />
          <select
            id="date-month-select"
            className={styles.selectInput}
            data-testid="date-month-select"
            value={draftMonth}
            onChange={(event) => handleMonthInput(Number(event.target.value))}
          >
            {MONTHS.map((month) => (
              <option key={month} value={month}>
                {month}
              </option>
            ))}
          </select>
        </div>
      )}
      {precision === "year" && (
        <div className={styles.fieldRow}>
          <input
            id="date-year-input"
            className={`${styles.textInput} ${styles.fixedWidth}`}
            type="text"
            inputMode="numeric"
            placeholder="YYYY"
            data-testid="date-year-input"
            value={draftYear}
            onChange={(event) => handleYearInput(event.target.value)}
          />
        </div>
      )}
      {precision === "unknown" && null}
    </div>
  );
}
