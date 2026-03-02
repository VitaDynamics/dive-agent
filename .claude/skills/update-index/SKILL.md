---
name: update-index
description: |
  Update README indexes based on recent changes to docs/. Use this skill when files have been added/removed/renamed in docs/learns/ or docs/best-choices/, when the user mentions "update index", "更新索引", "sync readme", or after creating new learning notes. This ensures all documentation indexes are consistent and complete.
---

# Update Index

Synchronize all README indexes with the actual documentation files.

## When to Use

- After adding new learning notes
- After removing or renaming documents
- After reorganizing categories
- When user asks to "update indexes" or "sync readme"
- Periodically to ensure consistency

## Steps

### 1. Scan All Documentation

Scan `docs/learns/` and `docs/best-choices/` to get actual file list:

```bash
find docs/learns -name "*.md" -type f | sort
find docs/best-choices -name "*.md" -type f | sort
```

### 2. Update docs/README.md

For each category in `docs/learns/`:

1. List all `.md` files in that category
2. Ensure the table in docs/README.md includes all files
3. Remove entries for files that no longer exist
4. Add entries for new files

Format for each topic section:

```markdown
#### [Topic Name](./learns/<topic>/)

| Document | Description | Priority |
|----------|-------------|----------|
| [Document Title](./learns/<topic>/<filename>.md) | <first line or description> | P0/P1/P2 |
```

### 3. Update Root README.md

Update the Documentation section:

1. Count documents per category
2. Update the table with accurate counts
3. Update total statistics

### 4. Update docs/best-choices/README.md

Ensure all files in `docs/best-choices/` are listed.

### 5. Verify Cross-References

Check that all relative links work:
- Links from README to documents
- Links from documents to related documents
- Links in "Related Documents" sections

### 6. Update Last Updated Date

Update the "Last updated" date at the bottom of each README.

## Example

User: "Update the indexes after I added some new notes"

Actions:
1. Scan `docs/learns/**/*.md`
2. Compare with `docs/README.md` tables
3. Add missing entries, remove stale ones
4. Update counts in root `README.md`
5. Verify all links

## Output Format

Report changes made:

```
Index Update Summary:
- Added 3 new entries to docs/README.md
- Removed 1 stale entry
- Updated counts in README.md
- Fixed 2 broken links
- Last updated: 2026-03-02
```

## Files Modified

- `docs/README.md` - Main documentation index
- `README.md` - Root README statistics
- `docs/best-choices/README.md` - Best choices index

## Verification

1. All files in `docs/learns/` appear in `docs/README.md`
2. Counts in `README.md` match actual file counts
3. No broken relative links
