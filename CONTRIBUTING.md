# 贡献指南

感谢你有兴趣贡献！本指南涵盖如何添加仓库、贡献文档和维护知识库。

## 贡献方式

### 1. 添加仓库

建议添加仓库：

1. 使用 [添加仓库模板](../../issues/new?template=add-repository.yml) 创建 Issue
2. 提供：
   - 仓库 URL
   - 建议类别（Agent / Agent-harness / Agent Evaluation / Agent Training）
   - 简要描述（1-2 句）
   - 为什么应该收录

#### 类别定义

| 类别 | 定义 | 示例 |
|------|------|------|
| **Agent** | 可直接使用的独立 AI Agent 应用 | CLI 助手、聊天机器人、自动化 Agent |
| **Agent-harness** | 提供 Agent 核心抽象的框架（状态管理、工具调用、流式处理） | pydantic-ai, langchain, republic |
| **Agent Evaluation** | Agent 行为基准测试、测试和评估工具 | agent-eval, agent-bench |
| **Agent Training** | Agent 模型训练、微调和优化资源 | agent-trainer, rl-agent |

#### 添加仓库源码

添加仓库源码用于本地学习：

1. 编辑 `sources.json` 添加仓库条目：

```json
{
  "name": "example-repo",
  "url": "https://github.com/org/example-repo.git",
  "branch": "main",
  "depth": 1,
  "description": "简要描述",
  "addedAt": "2026-03-02",
  "notes": ["docs/learns/topic/related-note.md"]
}
```

2. 运行同步脚本：

```bash
# 同步所有仓库
./scripts/sync-sources.sh

# 同步单个仓库
./scripts/sync-sources.sh example-repo

# 查看状态
./scripts/sync-sources.sh --status
```

3. 克隆的代码将位于 `sources/<类别>/<名称>/`

### 2. 贡献文档

#### 学习笔记

学习笔记分析跨框架的模式。贡献步骤：

1. **选择主题** - 比较多个框架中的模式
2. **使用模板**：[学习笔记模板](./docs/templates/learning-note-template.md)
3. **放在正确目录**：`docs/learns/<主题>/your-document.md`
4. **更新索引**：添加条目到 `docs/README.md`
5. **提交 PR**

可用主题：
- `streaming/` - 异步流式、WebSocket 模式
- `error-handling/` - 结构化错误、重试策略
- `context-management/` - 会话历史、上下文转换
- `type-safety/` - 类型安全的消息层次结构
- `middleware/` - 回调和可扩展性系统
- `concurrency/` - 状态快照和并发模式
- `architecture/` - 框架架构分析
- `abstractions/` - LLM 抽象层比较
- `websocket/` - WebSocket 协议比较

#### 最佳实践

最佳实践文档综合分析得出的建议。要求：

- 必须分析至少 2 个框架
- 必须提供具体代码示例
- 必须包含决策理由

### 3. 修复或改进现有内容

- **拼写错误/小修复**：直接提交 PR
- **重大更改**：先创建 Issue 讨论

## PR 流程

### 提交前

- [ ] 阅读本贡献指南
- [ ] 文档类：使用适当模板
- [ ] 更新所有相关 README 索引
- [ ] 确保 markdown 格式一致

### PR 检查清单

- [ ] PR 标题遵循规范：`docs: add streaming-patterns` 或 `repos: add smolagents`
- [ ] README 索引已更新
- [ ] 文件位置遵循目录结构

### 合并后

- `docs/learns/*.md` 中的文档会自动同步到 GitHub Wiki
- README 索引是导航的真实来源

## 目录结构

```
agent-group/
├── repos/                    # 按类别组织的仓库索引
│   ├── agent-harness/
│   ├── agent-evaluation/
│   └── agent-training/
├── docs/
│   ├── learns/               # 按主题组织的学习笔记
│   │   ├── streaming/
│   │   ├── error-handling/
│   │   └── ...
│   ├── best-choices/         # 设计文档
│   └── templates/            # 文档模板
└── .github/                  # Issue/PR 模板
```

## 风格指南

### 文档格式

- 使用 ATX 标题（# 为 H1，## 为 H2 等）
- 包含创建日期和相关主题的元信息
- 代码块必须指定语言
- 鼓励使用表格进行比较

### 文件命名

- 使用 kebab-case：`streaming-tool-assembly.md`
- 描述性强但简洁
- 匹配现有命名模式

### 提交信息

遵循约定式提交：
- `docs: add streaming-patterns` - 添加文档
- `repos: add smolagents` - 添加仓库到索引
- `fix: correct typo in readme` - 修复拼写错误
- `chore: update contributing guide` - 维护任务

## 问题？

- 一般问题：开启 [讨论区](../../discussions)
- 具体问题：开启 [Issue](../../issues)

---

感谢你为 Agent Group 知识库做出贡献！
