// @ts-check
import {themes as prismThemes} from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Lookout Marine',
  tagline: '⚓ A fast, native chartplotter over one shared S-101 chart core.',

  url: 'https://beetlebugorg.github.io',
  baseUrl: '/lookout-marine/',

  organizationName: 'beetlebugorg',
  projectName: 'lookout-marine',

  // The full beacon, sector lights off. It carries its own DEPDW ground, so it
  // stays legible on a light or a dark tab bar. Docusaurus prefixes baseUrl here.
  favicon: 'lookout-beacon.svg',

  headTags: [
    // type= is what makes a browser prefer the SVG over a cached .ico.
    {
      tagName: 'link',
      attributes: {
        rel: 'icon',
        type: 'image/svg+xml',
        href: '/lookout-marine/lookout-beacon.svg',
      },
    },
    // Safari's pinned tab wants a single-colour mask; that is what the mono
    // mark is for. It paints in the tab's accent, so hand it the docs primary.
    {
      tagName: 'link',
      attributes: {
        rel: 'mask-icon',
        href: '/lookout-marine/lookout-beacon-mono.svg',
        color: '#0b6ea8',
      },
    },
    // NO apple-touch-icon yet: the pack's 256 raster still has the sector
    // lights baked in. Add it back when the regenerated ladder lands.
  ],

  onBrokenLinks: 'warn',

  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.js',
          editUrl: 'https://github.com/beetlebugorg/lookout-marine/tree/main/docs/',
        },
        blog: false,
        theme: {
          // One entry only. custom.css @imports the token files itself, so a
          // token edit reaches the dev server on save — a config change does
          // not, it needs a restart.
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      navbar: {
        // There is no drawn wordmark: the name is set in the UI face at
        // semibold, with the mark at the cap-height of the text and one space
        // of clearance. custom.css holds that lockup to the ratio.
        title: 'Lookout Marine',
        logo: {
          alt: '',
          src: 'lookout-beacon.svg',
        },
        items: [
          // The guide switch. activeBaseRegex lights whichever guide is being
          // read, so the capsule always states which of the two you are in.
          // (activeBasePath is the usual way to say this, but it throws during
          // static generation under bun; the regex takes the same decision.)
          {
            to: '/user-guide/getting-started',
            label: 'User guide',
            activeBaseRegex: '/user-guide/',
            position: 'left',
          },
          {
            to: '/developer-guide/architecture',
            label: 'Developer guide',
            activeBaseRegex: '/developer-guide/',
            position: 'left',
          },
          {
            href: 'https://github.com/beetlebugorg/tile57',
            label: 'Chart engine',
            position: 'right',
          },
          {
            href: 'https://github.com/beetlebugorg/lookout-marine',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        // A flat list, not columns: Docusaurus renders it as one row of links,
        // which is all a five-link footer needs. No `style: dark` either — the
        // slab it paints is Infima's own navy, the one colour on the site that
        // comes from no token; without it the footer takes --chrome-panel and
        // ends the page on the same surface the rest of the chrome uses.
        //
        // Five links, each the shortest way to somewhere a visitor might
        // actually want to go. Dropped: Introduction (this is the page it
        // links to), Chart window (a page inside the user guide, reachable in
        // two clicks), Building (likewise, inside the developer guide).
        links: [
          {label: 'Getting started', to: '/user-guide/getting-started'},
          {label: 'Developer guide', to: '/developer-guide/architecture'},
          {label: 'Roadmap', to: '/roadmap'},
          {
            label: 'GitHub',
            href: 'https://github.com/beetlebugorg/lookout-marine',
          },
          {
            label: 'Chart engine',
            href: 'https://github.com/beetlebugorg/tile57',
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Jeremy Collins.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['bash', 'json', 'c', 'zig'],
      },
    }),
};

export default config;
