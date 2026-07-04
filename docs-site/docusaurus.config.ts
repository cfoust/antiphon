import { themes as prismThemes } from "prism-react-renderer";
import type { Config } from "@docusaurus/types";
import type * as Preset from "@docusaurus/preset-classic";

// Served under antiphon.dev/docs/ alongside the Vite marketing site at /.
// The GitHub Pages workflow builds both into one artifact.
const config: Config = {
  title: "Antiphon",
  tagline: "Your agents, speaking. You, listening.",
  favicon: "img/favicon.svg",

  url: "https://antiphon.dev",
  baseUrl: "/docs/",
  trailingSlash: true,

  organizationName: "cfoust",
  projectName: "antiphon",

  onBrokenLinks: "throw",

  i18n: {
    defaultLocale: "en",
    locales: ["en", "ru", "zh-Hans", "zh-Hant"],
    localeConfigs: {
      en: { label: "English" },
      ru: { label: "Русский" },
      "zh-Hans": { label: "简体中文" },
      "zh-Hant": { label: "繁體中文" },
    },
  },

  presets: [
    [
      "classic",
      {
        docs: {
          routeBasePath: "/", // antiphon.dev/docs/ IS the docs
          sidebarPath: "./sidebars.ts",
          editUrl: "https://github.com/cfoust/antiphon/tree/main/docs-site/",
        },
        blog: {
          routeBasePath: "blog",
          blogTitle: "Notes",
          blogDescription: "Notes from building Antiphon",
          blogSidebarTitle: "All notes",
          blogSidebarCount: "ALL",
          showReadingTime: true,
          onInlineTags: "ignore",
          onInlineAuthors: "ignore",
          onUntruncatedBlogPosts: "ignore",
        },
        theme: {
          customCss: "./src/css/custom.css",
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: {
      defaultMode: "light",
      disableSwitch: true, // the brand is cream-and-ink; one mode, done well
      respectPrefersColorScheme: false,
    },
    navbar: {
      title: "Antiphon",
      logo: {
        alt: "Antiphon",
        src: "img/logo.svg",
        href: "https://antiphon.dev/",
        target: "_self",
      },
      items: [
        { type: "docSidebar", sidebarId: "docs", position: "left", label: "Docs" },
        { to: "/blog/", label: "Notes", position: "left" },
        { href: "https://antiphon.dev/demo.html", label: "Web demo", position: "right" },
        { type: "localeDropdown", position: "right" },
        { href: "https://github.com/cfoust/antiphon", label: "GitHub", position: "right" },
      ],
    },
    footer: {
      style: "light",
      links: [],
      copyright: "ἀντίφωνον — voices, answering across a space · © 2026 Caleb Foust · MIT",
    },
    prism: {
      theme: prismThemes.gruvboxMaterialLight,
      additionalLanguages: ["bash", "rust", "swift", "toml", "json"],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
