---
name: add-repo-category
description: |
  Add a new repository category to repos/. Use this skill when the user wants to create a new classification for repositories, mentions "add repo category", "新增仓库分类", "创建仓库类别", or wants to organize repos under a new category.
---

# Add Repo Category

Add a new category for classifying repositories.

## Input Required

Ask the user for:

1. **Category name** (required): kebab-case name, e.g., `agent-infra`
2. **Display name** (optional): Human-readable name, e.g., "Agent Infrastructure"
3. **Description** (optional): What kind of repos belong here
4. **Examples** (optional): Example repositories that would fit

## Steps

### 1. Create Directory and README

```bash
mkdir -p repos/<category-name>
```

Create `repos/<category-name>/README.md`:

```markdown
# <Display Name>

<Description>

## Definition

<Category definition and criteria>

## Indexed Repositories

| Repository | Description | Language | Status |
|------------|-------------|----------|--------|
| *None yet* | - | - | - |

## Suggested Additions

If you know of a repository that should be included here, please:
1. Open an issue using the [Add Repository template](../../issues/new?template=add-repository.yml)
2. Select "<Display Name>" as the category

---

*Last updated: <today's date>*
```

### 2. Update sources.json

Add empty array for new category:

```json
"sources": {
  ...
  "<category-name>": []
}
```

### 3. Update repos/README.md

Add new category section:

```markdown
### [<Display Name>](./<category-name>/) (0 repositories)

<Description>

| Repository | Description | Language | Status |
|------------|-------------|----------|--------|
| *None yet* | - | - | - |

**[View Details →](./<category-name>/README.md)**
```

Also update the Category Definitions table.

### 4. Update Root README.md

Add to Repository Categories table.

### 5. Update Issue Template

Add new option to `.github/ISSUE_TEMPLATE/add-repository.yml` dropdown.

### 6. Create sources Directory

```bash
mkdir -p sources/<category-name>
```

## Example

User: "Add a category for agent infrastructure tools"

Actions:
1. Create `repos/agent-infra/README.md`
2. Update `sources.json`
3. Update `repos/README.md`
4. Update `README.md`
5. Update Issue template dropdown
6. Create `sources/agent-infra/`

## Files Modified

- `repos/<category>/README.md` - New file
- `repos/README.md` - Add category
- `README.md` - Update table
- `sources.json` - Add empty category
- `.github/ISSUE_TEMPLATE/add-repository.yml` - Add dropdown option
- `sources/<category>/` - New directory

## Verification

1. All README files contain the new category
2. Issue template includes new option
3. `sources.json` has the new category
