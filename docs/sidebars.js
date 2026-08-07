// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    'intro',
    {
      type: 'category',
      label: 'User guide',
      collapsed: false,
      items: [
        'user-guide/getting-started',
        'user-guide/chart-window',
        'user-guide/moving-the-chart',
        'user-guide/mariner-settings',
        'user-guide/raster-charts',
      ],
    },
    {
      type: 'category',
      label: 'Developer guide',
      collapsed: false,
      items: [
        'developer-guide/architecture',
        'developer-guide/macos',
        'developer-guide/linux',
        'developer-guide/windows',
        'developer-guide/android',
        'developer-guide/screenshots',
        {
          type: 'category',
          label: 'Plugins',
          link: {type: 'doc', id: 'developer-guide/plugins/index'},
          items: [
            'developer-guide/plugins/recipes',
            'developer-guide/plugins/build-your-first',
            {
              type: 'category',
              label: 'The plugin SDK',
              link: {type: 'doc', id: 'developer-guide/plugins/sdk/index'},
              items: [
                'developer-guide/plugins/sdk/subscribing',
                'developer-guide/plugins/sdk/drawing',
                'developer-guide/plugins/sdk/publishing',
                'developer-guide/plugins/sdk/settings',
                'developer-guide/plugins/sdk/connections',
                'developer-guide/plugins/sdk/events',
                'developer-guide/plugins/sdk/raw',
                'developer-guide/plugins/sdk/alerts',
                'developer-guide/plugins/sdk/glossary',
              ],
            },
            'developer-guide/plugins/wire',
            'developer-guide/plugins/rules',
            'developer-guide/plugins/dev-harness',
          ],
        },
      ],
    },
    'roadmap',
  ],
};

export default sidebars;
