import type { SidebarsConfig } from "@docusaurus/plugin-content-docs";

const sidebars: SidebarsConfig = {
  docs: [
    "index",
    "install",
    "getting-started",
    {
      type: "category",
      label: "Connecting agents",
      collapsed: false,
      link: { type: "doc", id: "agents/index" },
      items: ["agents/claude-code", "agents/codex", "agents/opencode", "agents/pi", "agents/aider"],
    },
    "web-demo",
    "engine",
    "development",
  ],
};

export default sidebars;
