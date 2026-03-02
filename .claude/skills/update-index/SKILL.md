---
name: update-index
description: |
  根据 docs/ 的最新更改更新 README 索引。当文件在 docs/learns/ 或 docs/best-choices/ 中被添加/删除/重命名、用户提到"update index"、"更新索引"、"sync readme"或创建新学习笔记后使用此技能。确保所有文档索引一致完整。
---

# 更新索引

将所有 README 索引与实际文档文件同步。

## 何时使用

- 添加新学习笔记后
- 删除或重命名文档后
- 重新组织类别后
- 用户要求"更新索引"或"同步 readme"
- 定期确保一致性

## 步骤

### 1. 扫描所有文档

扫描 `docs/learns/` 和 `docs/best-choices/` 获取实际文件列表：

```bash
find docs/learns -name "*.md" -type f | sort
find docs/best-choices -name "*.md" -type f | sort
```

### 2. 更新 docs/README.md

对于 `docs/learns/` 中的每个类别：

1. 列出该类别中的所有 `.md` 文件
2. 确保 docs/README.md 的表格包含所有文件
3. 删除不再存在的文件条目
4. 为新文件添加条目

每个主题部分的格式：

```markdown
#### [主题名称](./learns/<主题>/)

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [文档标题](./learns/<主题>/<文件名>.md) | <第一行或描述> | P0/P1/P2 |
```

### 3. 更新根 README.md

更新文档部分：

1. 统计每个类别的文档数
2. 用准确的计数更新表格
3. 更新总计统计

### 4. 更新 docs/best-choices/README.md

确保 `docs/best-choices/` 中的所有文件都已列出。

### 5. 验证交叉引用

检查所有相对链接是否有效：
- 从 README 到文档的链接
- 从文档到相关文档的链接
- "相关文档"部分的链接

### 6. 更新最后更新日期

更新每个 README 底部的"最后更新"日期。

## 示例

用户："更新索引，我添加了一些新笔记"

操作：
1. 扫描 `docs/learns/**/*.md`
2. 与 `docs/README.md` 表格比较
3. 添加缺失条目，删除过期条目
4. 更新 `README.md` 中的计数
5. 验证所有链接

## 输出格式

报告所做的更改：

```
索引更新摘要：
- 添加 3 个新条目到 docs/README.md
- 删除 1 个过期条目
- 更新 README.md 中的计数
- 修复 2 个损坏链接
- 最后更新：2026-03-02
```

## 修改的文件

- `docs/README.md` - 主文档索引
- `README.md` - 根 README 统计
- `docs/best-choices/README.md` - 最佳实践索引

## 验证

1. `docs/learns/` 中的所有文件出现在 `docs/README.md`
2. `README.md` 中的计数与实际文件数匹配
3. 没有损坏的相对链接
