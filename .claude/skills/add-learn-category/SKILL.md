---
name: add-learn-category
description: |
  添加新的学习笔记类别到 docs/learns/。当用户想要创建新的学习笔记主题类别、提到"add learn category"、"新增学习类别"、"创建文档分类"或在 新主题下组织笔记时使用此技能。
---

# 添加学习类别

添加新的主题类别用于组织学习笔记。

## 必需输入

请询问用户：

1. **类别名称**（必需）：kebab-case 名称，例如 `memory-management`
2. **显示名称**（可选）：人类可读名称，例如"内存管理"
3. **描述**（可选）：此类别涵盖什么

## 步骤

### 1. 创建目录

```bash
mkdir -p docs/learns/<类别名称>
```

### 2. 验证名称

- 必须是 kebab-case（小写、连字符）
- 不能已存在于 `docs/learns/`

### 3. 更新 docs/README.md

在"按主题分类"下添加新部分：

```markdown
#### [<显示名称>](./learns/<类别名称>/)
<描述>

| 文档 | 描述 | 优先级 |
|------|------|--------|
| *暂无* | - | - |
```

### 4. 更新 docs/best-choices/README.md

如果相关，添加对新类别的引用。

### 5. 更新根 README.md

更新文档部分表格，添加新类别。

## 示例

用户："Add a category for memory management patterns"

操作：
1. 创建 `docs/learns/memory-management/`
2. 在 `docs/README.md` 的"按主题分类"下添加条目
3. 更新 `README.md` 文档表格

## 修改的文件

- `docs/learns/<类别>/` - 新目录
- `docs/README.md` - 添加类别部分
- `README.md` - 更新文档表格

## 验证

1. 目录存在：`ls docs/learns/<类别>/`
2. `docs/README.md` 包含新类别
3. `README.md` 表格包含新条目
