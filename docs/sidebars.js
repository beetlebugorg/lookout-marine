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
      ],
    },
    {
      type: 'category',
      label: 'Developer guide',
      collapsed: false,
      items: [
        'developer-guide/architecture',
        'developer-guide/building',
        'developer-guide/hosts-linux',
        'developer-guide/screenshots',
      ],
    },
    'roadmap',
  ],
};

export default sidebars;
