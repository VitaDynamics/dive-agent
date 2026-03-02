---
name: add-repo-category
description: |
  添加新的仓库类别到 repos/。当用户想要创建新的仓库分类、提到"add repo category"、"新增仓库分类"、"创建仓库类别"或在 新类别下组织仓库时使用此技能。
---

# 添加仓库类别

添加新的类别用于分类仓库。

## 必需输入

请询问用户：

1. **类别名称**（必需）：kebab-case 名称，例如 `agent-infra`
2. **显示名称**（可选）：人类可读名称，例如"Agent 基础设施"
3. **描述**（可选）：什么样的仓库属于这里
4. **示例**（可选）：适合的示例仓库

## 步骤

### 1. 创建目录和 README

```bash
mkdir -p repos/<类别名称>
```

创建 `repos/<类别名称>/README.md`：

```markdown
# <显示名称>

<描述>

## 定义

<类别定义和标准>

## 已索引仓库

| 仓库 | 描述 | 语言 | 状态 |
|------|------|------|------|
| *暂无* | - | - | - |

## 建议添加

如果你知道应该包含在此的仓库：
1. 使用 [添加仓库模板](../../issues/new?template=add-repository.yml) 创建 Issue
2. 选择"<显示名称>"作为类别

---

*最后更新：<今天日期>*
```

### 2. 更新 sources.json

为新类别添加空数组：

```json
"sources": {
  ...
  "<类别名称>": []
}
```

### 3. 更新 repos/README.md

添加新类别部分：

```markdown
### [<显示名称>](./<类别名称>/)（0 个仓库）

<描述>

| 仓库 | 描述 | 语言 | 状态 |
|------|------|------|------|
| *暂无* | - | - | - |

**[查看详情 →](./<类别名称>/README.md)**
```

同时更新类别定义表。

### 4. 更新根 README.md

添加到仓库分类表格。

### 5. 更新 Issue 模板

向 `.github/ISSUE_TEMPLATE/add-repository.yml` 下拉菜单添加新选项。

### 6. 创建 sources 目录

```bash
mkdir -p sources/<类别名称>
```

## 示例

用户："Add a category for agent infrastructure tools"

操作：
1. 创建 `repos/agent-infra/README.md`
2. 更新 `sources.json`
3. 更新 `repos/README.md`
4. 更新 `README.md`
5. 更新 Issue 模板下拉菜单
6. 创建 `sources/agent-infra/`

## 修改的文件

- `repos/<类别>/README.md` - 新文件
- `repos/README.md` - 添加类别
- `README.md` - 更新表格
- `sources.json` - 添加空类别
- `.github/ISSUE_TEMPLATE/add-repository.yml` - 添加下拉选项
- `sources/<类别>/` - 新目录

## 验证

1. 所有 README 文件包含新类别
2. Issue 模板包含新选项
3. `sources.json` 有新类别
