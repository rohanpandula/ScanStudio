import { useEffect, useRef, useState } from "react";
import { writeClipboardText } from "../session/webApis";

export type ClipboardCopyStatus = "idle" | "copied" | "unavailable";

/** Clipboard copy with a single self-clearing status.
 *
 * One status value and one timer replace the pair of independent booleans
 * an earlier revision used, which could contradict each other when clicks
 * landed inside each other's clear windows ("Copied" after a failed copy,
 * "Clipboard unavailable" after a successful one). Every new copy attempt
 * cancels the previous timer before setting the new status, and the timer
 * is cleared on unmount. */
export function useClipboardCopy(): {
  status: ClipboardCopyStatus;
  copy: (text: string) => Promise<void>;
} {
  const [status, setStatus] = useState<ClipboardCopyStatus>("idle");
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (timerRef.current !== null) clearTimeout(timerRef.current);
    };
  }, []);

  const copy = async (text: string): Promise<void> => {
    const copied = await writeClipboardText(text);
    if (timerRef.current !== null) clearTimeout(timerRef.current);
    setStatus(copied ? "copied" : "unavailable");
    timerRef.current = setTimeout(() => setStatus("idle"), copied ? 1500 : 3000);
  };

  return { status, copy };
}
