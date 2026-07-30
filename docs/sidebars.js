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
        'developer-guide/macos',
        'developer-guide/linux',
        'developer-guide/windows',
        'developer-guide/android',
        'developer-guide/screenshots',
      ],
    },
    'roadmap',
  ],
};

export default sidebars;
