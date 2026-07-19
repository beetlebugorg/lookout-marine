// @ts-check
import {themes as prismThemes} from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'lookout',
  tagline: '⚓ An embeddable SDL_GPU chart widget for tile57 — drop a live S-52 chart into your app.',

  url: 'https://beetlebugorg.github.io',
  baseUrl: '/lookout-core/',

  organizationName: 'beetlebugorg',
  projectName: 'lookout-core',

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
          editUrl: 'https://github.com/beetlebugorg/lookout-core/tree/main/docs/',
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
        title: 'lookout',
        items: [
          {
            href: 'https://github.com/beetlebugorg/tile57',
            label: 'tile57',
            position: 'right',
          },
          {
            href: 'https://github.com/beetlebugorg/lookout-core',
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
              {label: 'Installation', to: '/installation'},
              {label: 'Embedding', to: '/embedding'},
              {label: 'C API', to: '/c-api'},
            ],
          },
          {
            title: 'More',
            items: [
              {label: 'GitHub', href: 'https://github.com/beetlebugorg/lookout-core'},
              {label: 'tile57 (the chart engine)', href: 'https://github.com/beetlebugorg/tile57'},
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Jeremy Collins.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['bash', 'json', 'c', 'zig', 'swift'],
      },
    }),
};

export default config;
