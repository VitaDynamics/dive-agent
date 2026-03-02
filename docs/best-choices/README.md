# Best Choices

Design documents synthesizing best practices from multiple frameworks.

## What are Best Choices?

Best Choice documents are synthesized recommendations that:
- Analyze patterns across multiple frameworks
- Provide concrete code examples
- Include decision rationale and trade-offs
- Offer actionable guidance for implementation

## Documents

| Document | Description | Frameworks Analyzed | Updated |
|----------|-------------|---------------------|---------|
| [LLM Error Handling Design](./llm-error-handling-design.md) | Structured error classification, retry strategies, fallback patterns | pydantic-ai, langchain, republic | 2026-02-26 |
| [Streaming Pull Debounced Push Design](./streaming-pull-debounced-push-design.md) | Streaming architecture patterns for pull-based and debounced push | pydantic-ai, kimi-cli, republic | 2026-02-26 |

## Contributing a Best Choice

To contribute a Best Choice document:

1. **Analyze at least 2 frameworks** - Document must compare patterns across multiple implementations
2. **Provide concrete examples** - Include code snippets from each framework
3. **Explain trade-offs** - Document when to use each approach
4. **Make recommendations** - Provide actionable guidance

### Template

```markdown
# [Pattern Name]

> **Synthesized from**: framework1, framework2, framework3

## Problem Statement

[What problem does this pattern solve?]

## Approaches

### Framework A: [Approach Name]

[Description and code example]

### Framework B: [Approach Name]

[Description and code example]

## Trade-offs

| Approach | Pros | Cons |
|----------|------|------|
| A | ... | ... |
| B | ... | ... |

## Recommendation

[When to use each approach]

## References

- [Link to framework A documentation]
- [Link to framework B documentation]
```

---

*Last updated: 2026-03-02*
