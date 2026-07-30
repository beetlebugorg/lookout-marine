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
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      navbar: {
        title: 'Lookout Marine',
        items: [
          {
            href: 'https://github.com/beetlebugorg/tile57',
            label: 'tile57 (the chart engine)',
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
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              {label: 'Introduction', to: '/'},
              {label: 'Getting started', to: '/user-guide/getting-started'},
              {label: 'Chart window', to: '/user-guide/chart-window'},
              {label: 'Architecture', to: '/developer-guide/architecture'},
              {label: 'Building', to: '/developer-guide/building'},
              {label: 'Roadmap', to: '/roadmap'},
            ],
          },
          {
            title: 'More',
            items: [
              {
                label: 'GitHub',
                href: 'https://github.com/beetlebugorg/lookout-marine',
              },
              {
                label: 'tile57 (the chart engine)',
                href: 'https://github.com/beetlebugorg/tile57',
              },
            ],
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
