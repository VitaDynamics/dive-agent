# Republic Anchor 与上下文隔离机制

> **Related topics**: [[republic-architecture]], [[session-history-management]]

## Overview
Republic 采用了一种独特的“两阶段”上下文管理机制。它将**物理存储（Tape）**与**逻辑视图（Context Window）**解耦，通过 Anchor 实现空间维度的切片，通过 Select Hook 实现内容维度的转换。

这种设计的核心哲学是：**历史是神圣不可侵犯的证据，而上下文是按需定制的滤镜。**

---

## 核心机制：两阶段隔离

上下文的构建过程遵循以下公式：
`Raw Tape Entries` → **`Slicing (Spatial)`** → **`Transformation (Content)`** → `Final Prompt`

### 1. 空间隔离 (Spatial Isolation) - `Handoff / Anchor`
*   **作用**: 决定磁带的**哪一段**进入 LLM 的视野。
*   **API**: `tape.handoff(name)`
*   **本质**: 设置坐标。它就像视频编辑中的“剪辑点”，默认只保留最近一个锚点之后的内容。
*   **解决的问题**: 彻底杜绝长对话导致的上下文干扰和 Token 浪费。

### 2. 内容隔离/转换 (Content Isolation) - `Select Hook`
*   **作用**: 决定视野内的内容以**何种方式**呈现给 LLM。
*   **API**: `TapeContext(select=my_hook)`
*   **本质**: 动态滤镜。它可以在不修改磁带的前提下，实时执行以下操作：
    *   **擦除**: 移除冗长的 `tool_result`，仅保留 `tool_call`。
    *   **去重**: 发现多次读取同一个文件时，只保留最新的内容。
    *   **脱敏**: 自动模糊敏感信息。
*   **解决的问题**: 解决 Handoff 无法处理的“视野内干扰”问题。

---

## Code Examples

### 综合应用：去重与精简
展示如何在保持审计日志完整的前提下，发送一个“去重且精简”的上下文给模型。

```python
from republic import TapeContext, LAST_ANCHOR

def smart_filter(entries: Sequence[TapeEntry], context: TapeContext):
    messages = []
    seen_files = set()
    
    # 反向遍历以实现“只保留最新”
    for entry in reversed(entries):
        # 场景 A: 擦除冗长的工具返回，仅保留调用痕迹
        if entry.kind == "tool_result":
            continue 
            
        # 场景 B: 对重复读取文件的行为进行去重
        if entry.kind == "event" and entry.payload.get("name") == "read_file":
            file_path = entry.payload.get("path")
            if file_path in seen_files:
                continue
            seen_files.add(file_path)
            
        messages.append(entry.payload)
        
    return list(reversed(messages))

# 应用这一套“组合拳”
ctx = TapeContext(anchor=LAST_ANCHOR, select=smart_filter)
tape.chat("Summarize the final version of the code", context=ctx)
```

---

## 工程哲学：不可变证据链 (Immutable Evidence)

Republic 为什么不直接提供“删除消息”的 API？

1.  **审计真实性**: 
    在生产环境下，如果 Agent 产生了幻觉或错误行为，我们需要回溯**所有**曾经发生过的动作。如果 `handoff` 具备擦除功能，那么磁带就会变得残缺不全，无法还原真实的执行轨迹。
2.  **多视图支持**:
    同一个 Tape，可以为不同的 LLM 或不同的子 Agent 提供不同的视图。例如：给“总结 Agent”看完整历史，给“执行 Agent”看精简视图。如果修改了 Tape 本身，这种灵活性就消失了。

| 概念 | 传统框架 (如 LangChain) | **Republic 实践** |
| :--- | :--- | :--- |
| **历史管理** | 修改/弹出 List (`list.pop()`) | **追加磁带 (Append-only)** |
| **隔离手段** | 内存数组切片 | **物理锚点 (Anchor)** |
| **擦除/去重** | 永久删除数据 | **动态视图 (Select Hook)** |
| **审计能力** | 依赖外部 Tracing 工具 | **原生集成在 Tape 存储中** |

---

## 相关文件
- `src/republic/tape/context.py` - 转换逻辑与切片算法
- `src/republic/tape/manager.py` - 锚点生命周期管理
- `src/republic/tape/entries.py` - 定义了不可变的 Entry 结构

---
*Last updated: 2026-02-25*
