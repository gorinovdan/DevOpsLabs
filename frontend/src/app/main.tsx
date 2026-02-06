import React from "react";
import ReactDOM from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import "@mantine/core/styles.css";
import App from "./App";
import "../shared/styles/global.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <MantineProvider
      defaultColorScheme="light"
      theme={{
        fontFamily: "Golos Text, system-ui, sans-serif",
        headings: { fontFamily: "Golos Text, system-ui, sans-serif" },
        colors: {
          brand: [
            "#f1f5ff",
            "#dbe7ff",
            "#c2d7ff",
            "#a7c3ff",
            "#8aaeff",
            "#7099ff",
            "#5a86f2",
            "#496fd1",
            "#3959a7",
            "#2a437d",
          ],
        },
        primaryColor: "brand",
        defaultRadius: "lg",
      }}
    >
      <App />
    </MantineProvider>
  </React.StrictMode>
);
