# Agent Group 知识库

## 语言要求

**重要：所有文档、提交信息、注释和对话都必须使用中文。**

- README 文件使用中文
- 学习笔记使用中文
- 最佳实践文档使用中文
- 提交信息使用中文
- Issue 和 PR 描述使用中文

## 仓库结构

```
agent-group/
├── docs/                    # 文档目录
│   ├── learns/              # 学习笔记（按主题分类）
│   ├── best-choices/        # 最佳实践文档
│   └── templates/           # 文档模板
├── repos/                   # 仓库索引
│   ├── agent/               # Agent 应用
│   ├── agent-harness/       # Agent 框架
│   ├── agent-evaluation/    # Agent 评估
│   └── agent-training/      # Agent 训练
├── sources/                 # 仓库源码（.gitignore 忽略）
├── scripts/                 # 工具脚本
├── sources.json             # 仓库清单
└── .claude/skills/          # Claude Skills
```

## 常用命令

```bash
# 同步所有仓库
./scripts/sync-sources.sh

# 同步单个仓库
./scripts/sync-sources.sh pydantic-ai

# 查看同步状态
./scripts/sync-sources.sh --status
```

## 可用 Skills

| Skill | 用途 |
|-------|------|
| add-repo | 添加新仓库到知识库 |
| add-learn-category | 添加学习笔记类别 |
| add-repo-category | 添加仓库分类 |
| update-index | 更新所有索引 |
| learn-about | 研究仓库并写学习笔记 |
| learn-best | 输出最佳实践文档 |

## 文档规范

### 学习笔记

位置：`docs/learns/<主题>/<名称>.md`

使用模板：`docs/templates/learning-note-template.md`

### 最佳实践

位置：`docs/best-choices/<名称>.md`

要求：
- 分析至少 2 个框架
- 包含决策矩阵
- 提供具体代码示例
