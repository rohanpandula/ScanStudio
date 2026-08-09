const CONTROL_LEASE_KEY = "scanstudio.control-lease";
export const CONTROL_LEASE_HEADER = "X-ScanStudio-Control-Lease";
export const CONTROL_TAB_LOCK_NAME = "scanstudio-controller-tab";
let activeControlLeaseToken: string | null = null;

export interface HeldControlTabLock {
  mechanism: "web-lock" | "page";
  release(): void;
}

export function getControlLeaseToken(): string | null {
  return activeControlLeaseToken;
}

export function setControlLeaseToken(token: string): void {
  activeControlLeaseToken = token;
}

export function clearControlLeaseToken(): void {
  activeControlLeaseToken = null;
  if (typeof window === "undefined") return;
  try {
    // Purge tokens written by older builds. sessionStorage is copied when a
    // tab is duplicated and is therefore never an ownership authority.
    window.sessionStorage.removeItem(CONTROL_LEASE_KEY);
  } catch {
    // The authoritative module-memory token was already cleared.
  }
}

export function controlLeaseHeaders(): Record<string, string> {
  const token = getControlLeaseToken();
  return token === null ? {} : { [CONTROL_LEASE_HEADER]: token };
}

/**
 * Adds an advisory browser-local ownership guard. Web Locks are scoped to the
 * current origin and are not copied when a tab is duplicated, but a busy or
 * unavailable lock falls back to a page guard so it cannot wedge takeover after
 * the server lease expires. The server's atomic lease remains authoritative.
 */
export async function acquireControlTabLock(): Promise<HeldControlTabLock> {
  const pageGuard = (): HeldControlTabLock => ({
    mechanism: "page",
    release(): void {
      // Module memory dies with this page; the server lease remains atomic.
    },
  });

  if (typeof navigator === "undefined") return pageGuard();
  const lockManager = Reflect.get(navigator, "locks") as LockManager | undefined;
  if (lockManager === undefined || typeof lockManager.request !== "function") {
    return pageGuard();
  }

  return new Promise<HeldControlTabLock>((resolve) => {
    let resultSettled = false;
    let releaseHold = (): void => undefined;
    const hold = new Promise<void>((release) => {
      releaseHold = release;
    });
    const settle = (result: HeldControlTabLock): void => {
      if (resultSettled) return;
      resultSettled = true;
      resolve(result);
    };

    try {
      void lockManager
        .request(
          CONTROL_TAB_LOCK_NAME,
          { ifAvailable: true, mode: "exclusive" },
          async (lock) => {
            if (lock === null) {
              // Advisory only: a frozen old tab may outlive the server lease.
              // Let the gateway's atomic claim decide whether takeover is live.
              settle(pageGuard());
              return;
            }
            let released = false;
            settle({
              mechanism: "web-lock",
              release(): void {
                if (released) return;
                released = true;
                releaseHold();
              },
            });
            await hold;
          },
        )
        .catch(() => settle(pageGuard()));
    } catch {
      settle(pageGuard());
    }
  });
}
