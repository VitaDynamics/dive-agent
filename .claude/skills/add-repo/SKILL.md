---
name: add-repo
description: |
  添加新仓库到知识库。当用户想要添加新仓库用于学习、提到"add repo"、"新增仓库"、"引入仓库"或提供 GitHub URL 时使用此技能。此技能会更新 sources.json、repos/ 索引，并可选择克隆仓库。
---

# 添加仓库

添加新仓库到 Agent Group 知识库。

## 必需输入

如果用户未提供，请询问以下信息：

1. **仓库 URL**（必需）：GitHub URL，例如 `https://github.com/org/repo.git`
2. **类别**（必需）：`agent`、`agent-harness`、`agent-evaluation`、`agent-training` 之一
3. **名称**（可选）：目录名，默认为 URL 中的仓库名
4. **描述**（可选）：简要描述
5. **分支**（可选）：默认为 `main`
6. **立即克隆**（可选）：是否立即克隆，默认为 `yes`

## 步骤

### 1. 验证类别

有效类别：
- `agent` - 独立的 AI Agent 应用
- `agent-harness` - Agent 框架和编排工具
- `agent-evaluation` - Agent 测试和评估框架
- `agent-training` - Agent 训练和微调资源

### 2. 更新 sources.json

添加条目到 `sources.json`：

```json
{
  "name": "<名称>",
  "url": "<url>",
  "branch": "<分支>",
  "depth": 1,
  "description": "<描述>",
  "addedAt": "<今天日期 YYYY-MM-DD>",
  "notes": []
}
```

### 3. 更新 repos/README.md

在 `repos/README.md` 的相应类别表格中添加条目：

```markdown
| [<名称>](https://github.com/org/repo) | <描述> | <语言> | - |
```

### 4. 更新 repos/<类别>/README.md

在类别特定的 README 中添加详细条目。

### 5. 更新根 README.md

更新 `README.md` 中的类别计数。

### 6. 克隆仓库（如果需要）

运行同步脚本：
```bash
./scripts/sync-sources.sh <名称>
```

## 示例

用户："Add https://github.com/openai/swarm to agent-harness"

操作：
1. 添加到 sources.json 的 "agent-harness" 下
2. 更新 repos/README.md
3. 更新 repos/agent-harness/README.md
4. 更新 README.md 计数
5. 用 `./scripts/sync-sources.sh swarm` 克隆

## 修改的文件

- `sources.json` - 添加仓库条目
- `repos/README.md` - 添加到类别表格
- `repos/<类别>/README.md` - 添加详细条目
- `README.md` - 更新计数

## 验证

完成后验证：
1. `./scripts/sync-sources.sh --status` 显示新仓库
2. 所有 README 文件包含新条目
3. 如果已克隆，`sources/<类别>/<名称>/` 存在
