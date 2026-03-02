---
name: add-learn-category
description: |
  Add a new learning note category to docs/learns/. Use this skill when the user wants to create a new topic category for learning notes, mentions "add learn category", "新增学习类别", "创建文档分类", or wants to organize notes under a new topic.
---

# Add Learn Category

Add a new topic category for organizing learning notes.

## Input Required

Ask the user for:

1. **Category name** (required): kebab-case name, e.g., `memory-management`
2. **Display name** (optional): Human-readable name, e.g., "Memory Management"
3. **Description** (optional): What this category covers

## Steps

### 1. Create Directory

```bash
mkdir -p docs/learns/<category-name>
```

### 2. Validate Name

- Must be kebab-case (lowercase, hyphens)
- Must not already exist in `docs/learns/`

### 3. Update docs/README.md

Add new section under "By Topic":

```markdown
#### [<Display Name>](./learns/<category-name>/)
<Description>

| Document | Description | Priority |
|----------|-------------|----------|
| *None yet* | - | - |
```

### 4. Update docs/best-choices/README.md

If relevant, add reference to the new category.

### 5. Update Root README.md

Update the Documentation section table with new category.

## Example

User: "Add a category for memory management patterns"

Actions:
1. Create `docs/learns/memory-management/`
2. Add entry to `docs/README.md` under "By Topic"
3. Update `README.md` documentation table

## Files Modified

- `docs/learns/<category>/` - New directory
- `docs/README.md` - Add category section
- `README.md` - Update documentation table

## Verification

1. Directory exists: `ls docs/learns/<category>/`
2. `docs/README.md` contains the new category
3. `README.md` table includes new entry
