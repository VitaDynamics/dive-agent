// @ts-check
import { themes as prismThemes } from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Agent Group 知识库',
  tagline: 'Agent 框架学习与最佳实践',
  favicon: 'img/favicon.ico',

  url: 'https://VitaDynamics.github.io',
  baseUrl: '/dive-agent/',
  organizationName: 'VitaDynamics',
  projectName: 'dive-agent',
  trailingSlash: false,

  onBrokenLinks: 'log',

  i18n: {
    defaultLocale: 'zh-Hans',
    locales: ['zh-Hans'],
    localeConfigs: {
      'zh-Hans': {
        label: '简体中文',
        htmlLang: 'zh-CN',
        direction: 'ltr',
      },
    },
  },

  markdown: {
    mermaid: true,
    format: 'detect',
    mdx1Compat: {
      comments: true,
      admonitions: true,
      headingIds: true,
    },
    preprocessor: ({ fileContent }) => {
      // 转义 MDX 无法处理的裸角括号（如 <15s、>15s）
      return fileContent.replace(/<(\d)/g, '\\<$1');
    },
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          path: 'docs/learns',
          routeBasePath: 'learns',
          sidebarPath: './sidebars.js',
          showLastUpdateTime: true,
          breadcrumbs: true,
          tags: 'tags.yml',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  plugins: [
    [
      '@docusaurus/plugin-content-docs',
      {
        id: 'best-choices',
        path: 'docs/best-choices',
        routeBasePath: 'best-choices',
        sidebarPath: './sidebars-best-choices.js',
        showLastUpdateTime: true,
        breadcrumbs: true,
        tags: 'tags.yml',
      },
    ],
  ],

  themes: [
    '@docusaurus/theme-mermaid',
    [
      require.resolve('@easyops-cn/docusaurus-search-local'),
      /** @type {import("@easyops-cn/docusaurus-search-local").PluginOptions} */
      ({
        hashed: true,
        language: ['en', 'zh'],
        docsRouteBasePath: ['learns', 'best-choices'],
        docsDir: ['docs/learns', 'docs/best-choices'],
        indexBlog: false,
        searchResultLimits: 10,
        searchResultContextMaxLength: 60,
        highlightSearchTermsOnTargetPage: true,
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      colorMode: {
        defaultMode: 'light',
        disableSwitch: false,
        respectPrefersColorScheme: true,
      },

      navbar: {
        title: 'Agent Group',
        logo: {
          alt: 'Agent Group Logo',
          src: 'img/logo.svg',
        },
        items: [
          {
            type: 'docSidebar',
            sidebarId: 'learnsSidebar',
            position: 'left',
            label: '学习笔记',
          },
          {
            to: '/best-choices/',
            label: '最佳实践',
            position: 'left',
            activeBaseRegex: '/best-choices/',
          },
          {
            to: '/repos',
            label: '仓库索引',
            position: 'left',
          },
          {
            href: 'https://github.com/VitaDynamics/dive-agent',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },

      footer: {
        style: 'dark',
        links: [
          {
            title: '文档',
            items: [
              { label: '学习笔记', to: '/learns/' },
              { label: '最佳实践', to: '/best-choices/' },
            ],
          },
          {
            title: '资源',
            items: [
              { label: '仓库索引', to: '/repos' },
              {
                label: 'GitHub',
                href: 'https://github.com/VitaDynamics/dive-agent',
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Agent Group`,
      },

      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['bash', 'python', 'json', 'yaml', 'toml', 'rust'],
      },

      docs: {
        sidebar: {
          hideable: true,
          autoCollapseCategories: true,
        },
      },
    }),
};

export default config;
