---
name: learn-about
description: |
  Research a repository and write a comprehensive learning note. Use this skill when the user wants to learn about a specific repository, mentions "learn about", "研究", "分析", "write a note about", or asks to understand how a framework implements something. This skill researches the source code, follows the learning note template, and saves to the specified category.
---

# Learn About

Research a repository and create a comprehensive learning note.

## Input Required

Ask the user for:

1. **Repository** (required): Name of the repo to research (must be in sources.json)
2. **Topic** (required): What aspect/pattern to study
3. **Category** (required): Which docs/learns/ subdirectory to save to
4. **Related repos** (optional): Other repos to compare with
5. **Priority** (optional): P0, P1, or P2 (default P2)

## Steps

### 1. Locate Repository

Find the repo in `sources/<category>/<name>/` or run sync if not cloned:

```bash
./scripts/sync-sources.sh <name>
```

### 2. Research Phase

Explore the repository to understand:

1. **Directory structure** - How is the code organized?
2. **Core abstractions** - What are the main types/classes?
3. **Key patterns** - How is the topic implemented?
4. **Code examples** - Find representative code snippets
5. **Design decisions** - Why was it done this way?

Focus areas based on topic:
- **Streaming**: Look for async/await, generators, event emitters
- **Error handling**: Look for error classes, retry logic, fallbacks
- **Context management**: Look for history, memory, context classes
- **Type safety**: Look for type definitions, unions, validators
- **Architecture**: Look for layer separation, module boundaries

### 3. Read Template

Read `docs/templates/learning-note-template.md` for structure.

### 4. Write Learning Note

Create file at `docs/learns/<category>/<topic>-<repo>.md`:

```markdown
# [Topic] in [Repo Name]

> **Scope**: [What this document covers]
>
> **Synthesized from**: [repo name]
>
> **Priority**: [P0/P1/P2]

---

## Overview

[2-3 paragraphs about the pattern/concept]

## Implementation in [Repo Name]

### Core Abstractions

[Key types/classes with code examples]

### Design Decisions

[Why was it done this way?]

### Code Examples

[Representative code snippets]

---

## Comparison with Other Frameworks

[If related repos were specified, compare approaches]

---

## Key Takeaways

1. [Takeaway 1]
2. [Takeaway 2]
3. [Takeaway 3]

---

## Related Documents

- [Link to related notes]

---

*Created: [Today's date]*
*Updated: [Today's date]*
```

### 5. Update Indexes

Run the update-index skill or manually update:

1. Add entry to `docs/README.md`
2. Update counts in `README.md`

### 6. Update sources.json

Add the new note to the repo's `notes` array in `sources.json`.

## Example

User: "Learn about how pydantic-ai handles streaming"

Actions:
1. Locate `sources/agent-harness/pydantic-ai/`
2. Research streaming implementation
3. Read `docs/templates/learning-note-template.md`
4. Write `docs/learns/streaming/pydantic-ai-streaming.md`
5. Update `docs/README.md`
6. Update `sources.json` notes array

## Quality Criteria

The learning note should:
- Explain the "why" not just the "what"
- Include actual code examples from the source
- Compare with at least one other framework if possible
- Provide actionable takeaways
- Follow the template structure

## Files Modified

- `docs/learns/<category>/<filename>.md` - New learning note
- `docs/README.md` - Add to index
- `README.md` - Update counts
- `sources.json` - Add to notes array

## Verification

1. Note follows template structure
2. Code examples are from actual source
3. Indexes are updated
4. `sources.json` includes the note reference
