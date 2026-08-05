/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { afterEach, describe, expect, it } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import AppShell from "../AppShell";

afterEach(cleanup);

describe("AppShell", () => {
  it("renders arbitrary sidebar/workspace/inspector content inside its own region", () => {
    render(
      <AppShell
        sidebar={<p>Sidebar Marker</p>}
        workspace={<p>Workspace Marker</p>}
        inspector={<p>Inspector Marker</p>}
      />,
    );
    expect(screen.getByTestId("shell-sidebar")).toHaveTextContent("Sidebar Marker");
    expect(screen.getByTestId("shell-workspace")).toHaveTextContent("Workspace Marker");
    expect(screen.getByTestId("shell-inspector")).toHaveTextContent("Inspector Marker");
  });
});
