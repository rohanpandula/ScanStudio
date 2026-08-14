/** @vitest-environment jsdom */
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useClipboardCopy } from "../useClipboardCopy";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("useClipboardCopy", () => {
  it("reports copied and self-clears after 1500ms", async () => {
    vi.useFakeTimers();
    vi.stubGlobal("navigator", {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) },
    });
    const { result } = renderHook(() => useClipboardCopy());
    await act(async () => {
      await result.current.copy("text");
    });
    expect(result.current.status).toBe("copied");
    act(() => {
      vi.advanceTimersByTime(1500);
    });
    expect(result.current.status).toBe("idle");
  });

  it("reports unavailable when the Clipboard API is absent (insecure context)", async () => {
    vi.useFakeTimers();
    vi.stubGlobal("navigator", {});
    const { result } = renderHook(() => useClipboardCopy());
    await act(async () => {
      await result.current.copy("text");
    });
    expect(result.current.status).toBe("unavailable");
    act(() => {
      vi.advanceTimersByTime(3000);
    });
    expect(result.current.status).toBe("idle");
  });

  it("a later attempt replaces the pending status instead of racing it", async () => {
    // The earlier two-boolean design could show "Clipboard unavailable"
    // right after a successful copy (the stale failure timer outliving the
    // success flag). One status plus one cancelled-on-entry timer cannot.
    vi.useFakeTimers();
    const writeText = vi.fn().mockRejectedValueOnce(new Error("denied"));
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    const { result } = renderHook(() => useClipboardCopy());
    await act(async () => {
      await result.current.copy("first");
    });
    expect(result.current.status).toBe("unavailable");
    writeText.mockResolvedValueOnce(undefined);
    act(() => {
      vi.advanceTimersByTime(1000);
    });
    await act(async () => {
      await result.current.copy("second");
    });
    expect(result.current.status).toBe("copied");
    // The first attempt's 3000ms clear would land here; it must not fire.
    act(() => {
      vi.advanceTimersByTime(1499);
    });
    expect(result.current.status).toBe("copied");
    act(() => {
      vi.advanceTimersByTime(2);
    });
    expect(result.current.status).toBe("idle");
  });
});
