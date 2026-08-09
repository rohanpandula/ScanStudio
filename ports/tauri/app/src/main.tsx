import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import WebRuntimeGate from "./WebRuntimeGate";
import "./global.css";

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <WebRuntimeGate>
      <App />
    </WebRuntimeGate>
  </React.StrictMode>,
);
