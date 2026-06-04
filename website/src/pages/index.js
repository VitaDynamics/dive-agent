import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import styles from './index.module.css';

const features = [
  {
    title: '学习笔记',
    description: '跨框架的 Agent 模式深度分析，涵盖流式处理、错误处理、上下文管理等 11 个主题。',
    link: '/learns/',
    stats: '20+ 篇笔记',
  },
  {
    title: '最佳实践',
    description: '从多个框架中提炼的设计建议，包含决策矩阵和具体代码示例。',
    link: '/best-choices/',
    stats: '3 篇指南',
  },
  {
    title: '仓库索引',
    description: '13 个精选 Agent 相关仓库，按类别组织，包含关联笔记链接。',
    link: '/repos',
    stats: '4 个分类',
  },
];

function HeroSection() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <header className={clsx('hero', styles.heroBanner)}>
      <div className="container">
        <h1 className={styles.heroTitle}>{siteConfig.title}</h1>
        <p className={styles.heroSubtitle}>{siteConfig.tagline}</p>
        <div className={styles.heroButtons}>
          <Link className="button button--primary button--lg" to="/learns/">
            开始阅读
          </Link>
          <Link
            className="button button--outline button--lg"
            to="https://github.com/VitaDynamics/dive-agent"
          >
            GitHub
          </Link>
        </div>
      </div>
    </header>
  );
}

function FeatureCard({ title, description, link, stats }) {
  return (
    <div className={clsx('col col--4', styles.featureCol)}>
      <Link to={link} className={styles.featureCard}>
        <div className={styles.featureContent}>
          <h3>{title}</h3>
          <p>{description}</p>
          <span className={styles.featureStats}>{stats}</span>
        </div>
      </Link>
    </div>
  );
}

function FeaturesSection() {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {features.map((props, idx) => (
            <FeatureCard key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}

export default function Home() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <Layout title={siteConfig.title} description={siteConfig.tagline}>
      <HeroSection />
      <main>
        <FeaturesSection />
      </main>
    </Layout>
  );
}
