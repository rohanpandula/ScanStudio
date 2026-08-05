import type { ReactNode } from "react";
import styles from "./AppShell.module.css";

export interface AppShellProps {
  sidebar: ReactNode;
  workspace: ReactNode;
  inspector: ReactNode;
}

export default function AppShell({ sidebar, workspace, inspector }: AppShellProps) {
  const hasInspector = inspector !== null && inspector !== undefined && inspector !== false;

  return (
    <div className={styles.shell} data-has-inspector={hasInspector}>
      <aside className={styles.sidebar} data-testid="shell-sidebar">
        {sidebar}
      </aside>
      <main className={styles.workspace} data-testid="shell-workspace">
        {workspace}
      </main>
      {hasInspector && (
        <section className={styles.inspector} data-testid="shell-inspector">
          {inspector}
        </section>
      )}
    </div>
  );
}
