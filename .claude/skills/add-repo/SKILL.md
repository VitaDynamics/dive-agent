---
name: add-repo
description: |
  Add a new repository to the knowledge base. Use this skill when the user wants to add a new repository for learning, mentions "add repo", "新增仓库", "引入仓库", or provides a GitHub URL to add. This skill updates sources.json, repos/ indexes, and optionally clones the repository.
---

# Add Repository

Add a new repository to the Agent Group knowledge base.

## Input Required

Ask the user for the following information if not provided:

1. **Repository URL** (required): GitHub URL, e.g., `https://github.com/org/repo.git`
2. **Category** (required): One of `agent`, `agent-harness`, `agent-evaluation`, `agent-training`
3. **Name** (optional): Directory name, defaults to repo name from URL
4. **Description** (optional): Brief description
5. **Branch** (optional): Default is `main`
6. **Clone now** (optional): Whether to clone immediately, default is `yes`

## Steps

### 1. Validate Category

Valid categories:
- `agent` - Standalone AI agent applications
- `agent-harness` - Agent frameworks and orchestration tools
- `agent-evaluation` - Agent testing and evaluation frameworks
- `agent-training` - Agent training and fine-tuning resources

### 2. Update sources.json

Add entry to `sources.json`:

```json
{
  "name": "<name>",
  "url": "<url>",
  "branch": "<branch>",
  "depth": 1,
  "description": "<description>",
  "addedAt": "<today's date YYYY-MM-DD>",
  "notes": []
}
```

### 3. Update repos/README.md

Add entry to the appropriate category table in `repos/README.md`:

```markdown
| [<name>](https://github.com/org/repo) | <description> | <language> | - |
```

### 4. Update repos/<category>/README.md

Add detailed entry to the category-specific README.

### 5. Update Root README.md

Update the category count in `README.md`.

### 6. Clone Repository (if requested)

Run the sync script:
```bash
./scripts/sync-sources.sh <name>
```

## Example

User: "Add https://github.com/openai/swarm to agent-harness"

Actions:
1. Add to sources.json under "agent-harness"
2. Update repos/README.md
3. Update repos/agent-harness/README.md
4. Update README.md count
5. Clone with `./scripts/sync-sources.sh swarm`

## Files Modified

- `sources.json` - Add repository entry
- `repos/README.md` - Add to category table
- `repos/<category>/README.md` - Add detailed entry
- `README.md` - Update count

## Verification

After completion, verify:
1. `./scripts/sync-sources.sh --status` shows the new repo
2. All README files contain the new entry
3. If cloned, `sources/<category>/<name>/` exists
