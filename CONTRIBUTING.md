# Contributing to Agent Group

Thank you for your interest in contributing! This guide covers how to add repositories, contribute documentation, and maintain the knowledge base.

## Ways to Contribute

### 1. Add a Repository

To suggest a repository for inclusion:

1. Open an issue using the [Add Repository template](../../issues/new?template=add-repository.yml)
2. Provide:
   - Repository URL
   - Suggested category (Agent / Agent-harness / Agent Evaluation / Agent Training)
   - Brief description (1-2 sentences)
   - Why it should be included

#### Adding Repository Source Code

To add a repository's source code for local learning:

1. Edit `sources.json` to add the repository entry:

```json
{
  "name": "example-repo",
  "url": "https://github.com/org/example-repo.git",
  "branch": "main",
  "depth": 1,
  "description": "Brief description",
  "addedAt": "2026-03-02",
  "notes": ["docs/learns/topic/related-note.md"]
}
```

2. Run the sync script:

```bash
# Sync all repositories
./scripts/sync-sources.sh

# Sync specific repository
./scripts/sync-sources.sh example-repo

# Check status
./scripts/sync-sources.sh --status
```

3. Cloned code will be available in `sources/<category>/<name>/`

#### Category Definitions

| Category | Definition | Examples |
|----------|------------|----------|
| **Agent-harness** | Frameworks that provide core agent abstractions (state management, tool calling, streaming) | pydantic-ai, langchain, republic |
| **Agent Evaluation** | Tools for benchmarking, testing, and evaluating agent behavior | agent-eval, agent-bench |
| **Agent Training** | Resources for training, fine-tuning, and optimizing agent models | agent-trainer, rl-agent |

### 2. Contribute Documentation

#### Learning Notes

Learning notes analyze patterns across frameworks. To contribute:

1. **Choose a topic** that compares patterns across multiple frameworks
2. **Use the template**: [Learning Note Template](./docs/templates/learning-note-template.md)
3. **Place in correct subdirectory**: `docs/learns/<topic>/your-document.md`
4. **Update the index**: Add entry to `docs/README.md`
5. **Submit a PR**

Available topics:
- `streaming/` - Async streaming, WebSocket patterns
- `error-handling/` - Structured errors, retry strategies
- `context-management/` - Session history, context transformation
- `type-safety/` - Type-safe message hierarchies
- `middleware/` - Callback and extensibility systems
- `concurrency/` - State snapshot and concurrency patterns
- `architecture/` - Framework architecture analysis
- `abstractions/` - LLM abstraction layer comparisons
- `websocket/` - WebSocket protocol comparisons

#### Best Choices

Best Choice documents synthesize recommendations from analysis. Requirements:

- Must analyze at least 2 frameworks
- Must provide concrete code examples
- Must include decision rationale

### 3. Fix or Improve Existing Content

- **Typos/Minor fixes**: Submit a PR directly
- **Major changes**: Open an issue first to discuss

## PR Process

### Before Submitting

- [ ] Read this contributing guide
- [ ] For documentation: use the appropriate template
- [ ] Update all relevant README indexes
- [ ] Ensure markdown formatting is consistent

### PR Checklist

- [ ] PR title follows convention: `docs: add streaming-patterns` or `repos: add smolagents`
- [ ] README indexes are updated
- [ ] File placement follows directory structure

### After Merge

- Documentation in `docs/learns/*.md` is automatically synced to GitHub Wiki
- README indexes are the source of truth for navigation

## Directory Structure

```
agent-group/
├── repos/                    # Repository indexes by category
│   ├── agent-harness/
│   ├── agent-evaluation/
│   └── agent-training/
├── docs/
│   ├── learns/               # Learning notes by topic
│   │   ├── streaming/
│   │   ├── error-handling/
│   │   └── ...
│   ├── best-choices/         # Design documents
│   └── templates/            # Document templates
└── .github/                  # Issue/PR templates
```

## Style Guide

### Document Formatting

- Use ATX headings (# for H1, ## for H2, etc.)
- Include front matter with creation date and related topics
- Code blocks must specify language
- Tables for comparisons are encouraged

### File Naming

- Use kebab-case: `streaming-tool-assembly.md`
- Be descriptive but concise
- Match existing naming patterns

### Commit Messages

Follow conventional commits:
- `docs: add streaming-patterns` - Adding documentation
- `repos: add smolagents` - Adding repository to index
- `fix: correct typo in readme` - Fixing typos
- `chore: update contributing guide` - Maintenance tasks

## Questions?

- Open a [Discussion](../../discussions) for general questions
- Open an [Issue](../../issues) for specific problems

---

Thank you for contributing to the Agent Group knowledge base!
