---
tags: context-management, error-recovery, architecture, best-practice, republic, kimi-cli, pydantic-ai
---

# History-Item-as-Checkpointer: Context-Lossless Design

> **Scope**: Designing a robust state management system where the dialogue history itself serves as a fine-grained checkpointing mechanism for error recovery and state restoration.
>
> **Synthesized from**: republic (Tape mechanism), kimi-cli (Checkpoint/Revert), pydantic-ai (Graph State), Codex (Stream Interruption)

---

## 1. The Core Problem: Context Fragmentation

Traditional LLM frameworks often treat history as a simple list of messages. When an error occurs (e.g., a network timeout during a long tool call or a stream interruption), the system often faces a binary choice:
1. **Retry from scratch**: Wasteful of tokens and time; loses progress of the current turn.
2. **Fail completely**: Frustrating for users; requires manual recovery.

**The "Naive Checkpointer" Goal**: Every single item added to the history should automatically provide enough information to resume or rollback the system state to that exact point in time.

---

## 2. Design Pattern: The Immutable Tape

The most effective way to implement "each item as a checkpointer" is the **Immutable Tape Pattern** (inspired by `republic`).

### 2.1 The Tape Entry Structure

Instead of just `role` and `content`, each history entry should be a "Tape Entry" that captures the system's pulse.

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TapeEntry {
    /// Monotonically increasing ID (The Checkpoint Index)
    pub id: u64,
    /// Type of entry
    pub kind: EntryKind,
    /// The actual data (Message, ToolCall, etc.)
    pub payload: serde_json::Value,
    /// System state at this moment (e.g., active tool, working directory)
    pub state_snapshot: Option<StateDelta>,
    /// Metadata (tokens, latency, request_id)
    pub meta: HashMap<String, String>,
}

pub enum EntryKind {
    System,      // System prompt change
    User,        // User input
    Assistant,   // Finished assistant message
    Streaming,   // PARTIAL assistant message (The "Resume Point")
    ToolCall,    // Request to execute a tool
    ToolResult,  // Output of a tool
    Anchor,      // Explicit checkpoint marker
    Error,       // Captured failure
}
```

### 2.2 Implicit vs. Explicit Checkpoints

- **Implicit**: Every `Assistant` or `ToolResult` entry is a natural checkpoint. If the next step fails, we can always revert to `id - 1`.
- **Explicit (Anchors)**: Developers can insert `Anchor` entries (e.g., after a successful multi-step task) to mark "milestones" that are safe to return to after major failures.

---

## 3. Recovery Mechanisms

### 3.1 Stream Interruption Recovery (Codex Pattern)

When a stream disconnects halfway:
1. **Capture Partial Content**: Save the received chunks into a `Streaming` entry.
2. **Resume Strategy**:
    - **Naive**: Delete the `Streaming` entry and retry the entire turn.
    - **Advanced**: Use the `Streaming` entry as a prefix (if the model supports "Prefilling" or "Suffix" completion) to continue where it left off.

### 3.2 Tool Call Resumption

If a tool execution fails or the system crashes *during* execution:
1. The history contains the `ToolCall` entry but no `ToolResult`.
2. On recovery, the system scans the tape:
    - Found `ToolCall` without matching `ToolResult`? → Re-execute or ask user.
    - This turns history into a "Write-Ahead Log" (WAL) for Agent actions.

---

## 4. Context Filtering (The "View" Pattern)

If history is append-only and grows with every retry/error, how do we prevent prompt pollution?

**Recommendation**: Separate the **Physical Tape** from the **Logical Context Window**.

```rust
pub struct ContextBuilder {
    pub tape: Vec<TapeEntry>,
}

impl ContextBuilder {
    /// Select which entries to actually send to the LLM
    pub fn build_prompt(&self, policy: SelectionPolicy) -> Vec<Message> {
        match policy {
            SelectionPolicy::LastTurnOnly => {
                // Find last Anchor or User message and take everything after
            }
            SelectionPolicy::ExcludeErrors => {
                // Filter out 'Error' kinds to keep the prompt clean
            }
            SelectionPolicy::DeDuplicateTools => {
                // If a file was read 5 times, only include the last result
            }
        }
    }
}
```

---

## 5. Decision Matrix: Checkpointing Strategies

| Strategy | Granularity | Complexity | Best For |
|----------|-------------|------------|----------|
| **Snapshot Every Turn** | Coarse | Low | Simple Chatbots |
| **Tape (Append-only)** | **Fine** | **Medium** | **Complex Agents / IDE Tools** |
| **External DB (WAL)** | Fine | High | Production Distributed Agents |
| **Naive Checkpointer** | **Extreme** | **Medium** | **Long-running reasoning tasks** |

---

## 6. Implementation Best Practices

1. **Deterministic IDs**: Use UUIDs or strictly increasing integers to ensure history items can be referenced unambiguously.
2. **State Deltas**: Instead of saving the full system state in every item, save only what *changed* (e.g., "Variable X updated").
3. **Atomic Appends**: Ensure that an item is only added to the history *after* it has been successfully persisted to the backend (File/DB).
4. **Cleanup Policy**: While "Immutable" is the goal, provide a `compact()` method to archive old items or merge identical entries to save memory.

---

## 7. Anti-Patterns to Avoid

1. **In-place History Mutation**: Never "edit" a previous message to fix an error. Append a new entry instead. Mutation destroys the audit trail and makes recovery non-deterministic.
2. **Heavy State in Every Item**: Storing 1MB of state in every history item will crash your memory. Use pointers or deltas.
3. **Ignoring Partial Results**: Throwing away 90% of a long streaming response just because the last 10% failed is a waste of resources.

---

## References

- [LLM 错误恢复与上下文无损](../learns/harness/error-handling/error-recovery-without-context-loss.md)
- [Republic Anchor 与上下文隔离](../learns/harness/architecture/republic-anchor-mechanism.md)
- [状态快照模式与双模并发](../learns/harness/concurrency/state-snapshot-concurrency.md)
- [Codex 错误处理与流中断](../learns/harness/error-handling/codex-error-handling-stream-interruption.md)

---

*Created: 2026-03-04*
*Updated: 2026-03-04*
