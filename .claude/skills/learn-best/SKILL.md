---
name: learn-best
description: |
  Synthesize best practices from learning notes into a best-choices document. Use this skill when the user wants to create design recommendations, mentions "best practices", "最佳实践", "design recommendation", "synthesize", or wants to distill learnings into actionable guidelines. This skill analyzes existing notes and outputs to docs/best-choices/.
---

# Learn Best

Synthesize best practices from learning notes into actionable guidelines.

## Input Required

Ask the user for:

1. **Topic** (required): What pattern/practice to synthesize
2. **Source notes** (optional): Specific notes to synthesize, or "all related"
3. **Context** (optional): Any additional context from conversation

## Steps

### 1. Identify Source Material

If source notes not specified, search for relevant notes:

```bash
grep -r "<topic>" docs/learns/
```

Read all relevant learning notes to understand:
- Different approaches across frameworks
- Trade-offs identified
- Best practices mentioned

### 2. Read Existing Best Choices

Check `docs/best-choices/` for related documents to reference or extend.

### 3. Synthesize

Based on the research, identify:

1. **The Problem** - What problem does this pattern solve?
2. **Approaches** - What are the different ways to solve it?
3. **Trade-offs** - When to use each approach?
4. **Recommendation** - What's the recommended approach?

### 4. Write Best Choices Document

Create file at `docs/best-choices/<topic>-best-practices.md`:

```markdown
# [Topic] Best Practices

> **Synthesized from**: [list of notes and repos analyzed]

---

## Problem Statement

[What problem does this address?]

---

## Approaches

### Approach 1: [Name]

**Used by**: [Framework A, Framework B]

**Description**:
[How it works]

**Code Example**:
```python
# Example code
```

**Pros**:
- Pro 1
- Pro 2

**Cons**:
- Con 1
- Con 2

---

### Approach 2: [Name]

[Same structure]

---

## Decision Matrix

| Scenario | Recommended Approach | Rationale |
|----------|---------------------|-----------|
| [Scenario 1] | [Approach] | [Why] |
| [Scenario 2] | [Approach] | [Why] |

---

## Recommended Best Practices

1. **[Practice 1]**: [Description and rationale]
2. **[Practice 2]**: [Description and rationale]
3. **[Practice 3]**: [Description and rationale]

---

## Anti-Patterns to Avoid

1. **[Anti-pattern 1]**: [Why to avoid]
2. **[Anti-pattern 2]**: [Why to avoid]

---

## References

- [Learning Note 1](../learns/topic/note.md)
- [Learning Note 2](../learns/topic/note.md)
- [External Resource](https://...)

---

*Created: [Today's date]*
*Updated: [Today's date]*
```

### 5. Update Indexes

1. Add entry to `docs/best-choices/README.md`
2. Update `docs/README.md` if needed
3. Update root `README.md` counts

## Example

User: "Create best practices for error handling based on what we discussed"

Actions:
1. Read `docs/learns/error-handling/structured-errors-retry.md`
2. Search for other error handling notes
3. Synthesize approaches from pydantic-ai, langchain, etc.
4. Write `docs/best-choices/error-handling-best-practices.md`
5. Update indexes

## Quality Criteria

The best choices document should:
- Analyze at least 2 frameworks/approaches
- Provide concrete code examples
- Include a decision matrix for when to use each approach
- Be actionable and specific
- Reference source learning notes

## Files Modified

- `docs/best-choices/<filename>.md` - New best choices document
- `docs/best-choices/README.md` - Add to index
- `docs/README.md` - Update if needed
- `README.md` - Update counts

## Verification

1. Document analyzes multiple approaches
2. Decision matrix is complete
3. Indexes are updated
4. References to source notes are correct
