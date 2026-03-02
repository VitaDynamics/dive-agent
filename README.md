# Agent Group Knowledge Base

> A curated collection of Agent frameworks, evaluation tools, training methodologies, and learning resources.

## Overview

This repository serves as a centralized knowledge base for:
- **Repository Index**: Curated list of Agent-related projects organized by category
- **Learning Notes**: In-depth analysis and comparison of Agent framework patterns
- **Design Documents**: Best practices and architectural decisions

## Repository Categories

| Category | Description | Count |
|----------|-------------|-------|
| [Agent](./repos/agent/) | Standalone AI agent applications and implementations | 0 |
| [Agent-harness](./repos/agent-harness/) | Agent frameworks and orchestration tools | 6 |
| [Agent Evaluation](./repos/agent-evaluation/) | Agent testing and evaluation frameworks | 0 |
| [Agent Training](./repos/agent-training/) | Agent training and fine-tuning resources | 0 |

**[View All Repositories →](./repos/README.md)**

## Documentation

### Learning Notes by Topic

| Topic | Description | Documents |
|-------|-------------|-----------|
| [Streaming](./docs/learns/streaming/) | Async streaming, WebSocket patterns | 4 |
| [Error Handling](./docs/learns/error-handling/) | Structured errors, retry strategies | 1 |
| [Context Management](./docs/learns/context-management/) | Session history, context transformation | 3 |
| [Type Safety](./docs/learns/type-safety/) | Type-safe message hierarchies | 1 |
| [Middleware](./docs/learns/middleware/) | Callback and extensibility systems | 1 |
| [Concurrency](./docs/learns/concurrency/) | State snapshot and concurrency patterns | 1 |
| [Architecture](./docs/learns/architecture/) | Framework architecture analysis | 2 |
| [Abstractions](./docs/learns/abstractions/) | LLM abstraction layer comparisons | 3 |
| [WebSocket](./docs/learns/websocket/) | OpenAI WebSocket comparisons | 1 |

### Best Choices

Design documents synthesizing best practices from multiple frameworks.

| Document | Description |
|----------|-------------|
| [LLM Error Handling Design](./docs/best-choices/llm-error-handling-design.md) | Structured error classification, retry strategies |
| [Streaming Pull Debounced Push Design](./docs/best-choices/streaming-pull-debounced-push-design.md) | Streaming architecture patterns |

**[View All Documentation →](./docs/README.md)**

## Quick Links

- [Contributing Guide](./CONTRIBUTING.md)
- [Add a Repository](../../issues/new?template=add-repository.yml)
- [Contribute Documentation](../../issues/new?template=document-contribution.yml)
- [GitHub Wiki](../../wiki) (auto-synced from `docs/learns/`)
- [Discussions](../../discussions)

## Sync Source Code

To clone external repositories for local learning:

```bash
# Sync all repositories (shallow clone)
./scripts/sync-sources.sh

# Sync specific repository
./scripts/sync-sources.sh pydantic-ai

# Check sync status
./scripts/sync-sources.sh --status
```

Cloned code is stored in `sources/<category>/<name>/` (not committed to git).

## Statistics

```
Repositories: 6 (Agent-harness: 6, Evaluation: 0, Training: 0)
Documents: 17 learning notes + 2 design documents
Topics: 9
Last Updated: 2026-03-02
```

---

*Maintained by the Agent Group team*
