import { createContext, useContext, type ReactNode } from "react";

const ScannerControlContext = createContext(true);

export function ScannerControlProvider({
  canControl,
  children,
}: {
  canControl: boolean;
  children: ReactNode;
}) {
  return (
    <ScannerControlContext.Provider value={canControl}>
      {children}
    </ScannerControlContext.Provider>
  );
}

/** Native hosts own their local engine, while the web gate supplies lease ownership. */
export function useScannerControl(): boolean {
  return useContext(ScannerControlContext);
}
