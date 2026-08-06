export interface SetupCheckProbeResult {
  id: string;
  status: string;
  detail: string;
  fixCommand: string | null;
}

type Listener = () => void;

/** Session-lifetime cache of the Windows setup checker's most recent probe
 * results (error report v2, item 5). SetupChecker.tsx writes into this
 * after every run; the error-report builder reads from it so a report
 * generated "while setup-check results exist" includes them. A plain
 * module-level singleton, deliberately kept outside SessionStore, so this
 * never touches session/store/session.ts's engine-session surface. */
class SetupCheckResultsStore {
  #results: SetupCheckProbeResult[] | null = null;
  #listeners = new Set<Listener>();

  get(): SetupCheckProbeResult[] | null {
    return this.#results;
  }

  set(results: SetupCheckProbeResult[]): void {
    this.#results = results;
    for (const listener of this.#listeners) listener();
  }

  subscribe(listener: Listener): () => void {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }
}

export const setupCheckResults = new SetupCheckResultsStore();

/** Full "id: status -- detail (fix: ...)" text for the setup checker's own
 * "Copy as text" affordance -- richer than the report's 3-field
 * (id/status/detail) inclusion, since this is the primary, standalone view
 * of the probe table itself. */
export function formatSetupCheckProbesAsText(probes: SetupCheckProbeResult[]): string {
  return probes
    .map((probe) => {
      const fix = probe.fixCommand ? ` (fix: ${probe.fixCommand})` : "";
      return `${probe.id}: ${probe.status} -- ${probe.detail}${fix}`;
    })
    .join("\n");
}
