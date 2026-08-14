/** Secure-context Web APIs with insecure-context fallbacks.
 *
 * First live Windows validation (2026-08-13, real LS-5000 over the WSL
 * bridge): the shipped WebView2 runtime does not treat the Windows origin
 * `http://tauri.localhost` as a secure context, so `crypto.randomUUID` and
 * `navigator.clipboard` do not exist at runtime on Windows -- while macOS
 * (custom scheme) and every test environment (Node supplies webcrypto
 * regardless of context) have both. A bare `crypto.randomUUID()` is then a
 * synchronous TypeError that a caller's promise `.catch` can swallow whole;
 * the live symptom was a Preview button that did nothing, with no banner,
 * against a connected real scanner.
 *
 * tauri.conf.json now opts the main window into the https scheme, which
 * restores the secure context on Windows. These helpers keep every call
 * site non-throwing even if a future embedding regresses to an insecure
 * origin: ids fall back to Math.random, clipboard reports unavailability
 * instead of throwing.
 */

/** UUID-shaped correlation id. Uses Web Crypto when the context provides
 * it; otherwise builds an RFC 4122 v4-shaped id from Math.random.
 * Correlation ids need uniqueness within one app session, not
 * cryptographic strength, so the fallback is acceptable and -- unlike the
 * bare call -- can never throw. */
export function newOperationId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    // The existence check and the call are separate invariants: a runtime
    // could expose the property and still throw on invocation (the exact
    // bug class this module exists to close), so the call is guarded too.
    try {
      return crypto.randomUUID();
    } catch {
      // fall through to the Math.random fallback below
    }
  }
  let uuid = "";
  for (let index = 0; index < 32; index += 1) {
    const nibble = Math.floor(Math.random() * 16);
    if (index === 12) {
      uuid += "4";
    } else if (index === 16) {
      uuid += ((nibble & 0x3) | 0x8).toString(16);
    } else {
      uuid += nibble.toString(16);
    }
    if (index === 7 || index === 11 || index === 15 || index === 19) {
      uuid += "-";
    }
  }
  return uuid;
}

/** One-line description of the runtime's secure-context API availability,
 * shown by the Windows setup checker. This is the discriminating fact the
 * first live Windows validation never captured directly: whether the
 * webview treats its origin as a secure context, and whether the two APIs
 * this module guards actually exist. */
export function describeWebApiAvailability(): string {
  const secure =
    typeof window !== "undefined" && window.isSecureContext === true ? "yes" : "no";
  const uuid =
    typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
      ? "available"
      : "missing";
  const clipboard =
    typeof navigator !== "undefined" && navigator.clipboard !== undefined
      ? "available"
      : "missing";
  return `secure context ${secure}; uuid ${uuid}; clipboard ${clipboard}`;
}

/** Platform-correct URL for a scanstudio-preview protocol resource.
 *
 * On macOS and Linux the webview loads custom protocols directly
 * (`scanstudio-preview://localhost/...`). On Windows, wry serves every
 * custom protocol through an `http(s)://<scheme>.localhost` origin instead
 * -- the raw custom-scheme URL is unknown to WebView2 and the request
 * never reaches the Rust handler. The document's own origin reveals which
 * world we are in: a `*.localhost` hostname means the wry mapping is
 * active, and mirroring the document's protocol tracks useHttpsScheme
 * automatically. The Rust handler reads only the query string, so both
 * URL forms hit the same code path. */
export function previewImageSrc(
  imagePath: string,
  loc?: Pick<Location, "protocol" | "hostname">,
): string {
  const location =
    loc ?? (typeof window !== "undefined" && window.location ? window.location : undefined);
  const query = `?id=${encodeURIComponent(imagePath)}`;
  if (location !== undefined && location.hostname.endsWith(".localhost")) {
    return `${location.protocol}//scanstudio-preview.localhost/${query}`;
  }
  return `scanstudio-preview://localhost/${query}`;
}

/** Writes text to the system clipboard when the Clipboard API exists.
 * Returns true only when the write succeeded; false covers both an
 * insecure context (navigator.clipboard is undefined there) and a rejected
 * write, so callers can show an "unavailable" affordance instead of dying
 * on an unhandled rejection. */
export async function writeClipboardText(text: string): Promise<boolean> {
  const clipboard = typeof navigator !== "undefined" ? navigator.clipboard : undefined;
  if (clipboard === undefined || typeof clipboard.writeText !== "function") {
    return false;
  }
  try {
    await clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}
