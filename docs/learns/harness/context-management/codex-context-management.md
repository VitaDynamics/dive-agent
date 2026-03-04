---
tags: context-management, history, memory, truncation, codex, harness
---

# Codex 上下文管理架构

> **范围**：深入分析 OpenAI Codex 的上下文管理机制，包括对话历史、Token 管理、上下文压缩和引用追踪
>
> **综合自**：codex (openai/codex)
>
> **优先级**：P1

---

## 概述

Codex 的上下文管理系统采用了多层次的策略来处理 LLM 的有限上下文窗口。核心设计目标是在保持对话连贯性的同时，最大化有效上下文利用率。

上下文管理层次：
1. **ContextManager** - 核心历史管理
2. **消息历史持久化** - 文件系统存储
3. **Token 估算与截断** - 自适应上下文窗口管理
4. **上下文压缩** - 智能摘要减少 Token 使用

---

## ContextManager 核心架构

### 数据结构

```rust
#[derive(Debug, Clone, Default)]
pub(crate) struct ContextManager {
    /// 历史项目， oldest → newest 顺序
    items: Vec<ResponseItem>,
    token_info: Option<TokenUsageInfo>,
    /// 参考上下文快照，用于差异计算
    reference_context_item: Option<TurnContextItem>,
}
```

**设计理由**：
- `Vec<ResponseItem>` 保持顺序，支持高效的前端/后端操作
- `token_info` 缓存上次 API 响应的 Token 使用量
- `reference_context_item` 支持上下文差异检测

### Token 使用跟踪

```rust
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct TotalTokenUsageBreakdown {
    pub last_api_response_total_tokens: i64,
    pub all_history_items_model_visible_bytes: i64,
    pub estimated_tokens_of_items_added_since_last_successful_api_response: i64,
    pub estimated_bytes_of_items_added_since_last_successful_api_response: i64,
}
```

---

## 历史记录管理

### 持久化格式

Codex 使用 **JSON Lines** 格式存储历史：`~/.codex/history.jsonl`

```
{"conversation_id":"<uuid>","ts":<unix_seconds>,"text":"<message>"}
```

**设计优点**：
- 追加写入高效（O_APPEND 原子性保证）
- 行级解析，支持流式读取
- 标准工具（jq, grep）可直接处理

### 文件锁定机制

```rust
pub(crate) async fn append_entry(
    text: &str,
    conversation_id: &ThreadId,
    config: &Config,
) -> Result<()> {
    // 构造完整 JSON 行
    let mut line = serde_json::to_string(&entry)?;
    line.push('\n');

    // 在阻塞任务中执行文件锁定写入
    tokio::task::spawn_blocking(move || -> Result<()> {
        for _ in 0..MAX_RETRIES {
            match history_file.try_lock() {
                Ok(()) => {
                    history_file.seek(SeekFrom::End(0))?;
                    history_file.write_all(line.as_bytes())?;
                    history_file.flush()?;
                    enforce_history_limit(&mut history_file, history_max_bytes)?;
                    return Ok(());
                }
                Err(std::fs::TryLockError::WouldBlock) => {
                    std::thread::sleep(RETRY_SLEEP);
                }
            }
        }
        Err(...)
    }).await??;
}
```

**关键设计**：
- 咨询式文件锁防止并发写入冲突
- 重试机制避免无限阻塞
- 单系统调用写入保证原子性

### 历史大小限制

```rust
const HISTORY_SOFT_CAP_RATIO: f64 = 0.8;

fn trim_target_bytes(max_bytes: u64, newest_entry_len: u64) -> u64 {
    let soft_cap_bytes = ((max_bytes as f64) * HISTORY_SOFT_CAP_RATIO)
        .floor()
        .clamp(1.0, max_bytes as f64) as u64;

    soft_cap_bytes.max(newest_entry_len)  // 确保最新条目保留
}
```

**策略**：
- 硬上限触发时，裁剪到软上限（80%）
- 优先删除最旧条目
- 总是保留最新条目

---

## Token 估算与截断

### 启发式估算

Codex 使用字节启发式而非精确 Tokenizer：

```rust
impl ContextManager {
    pub(crate) fn estimate_token_count(
        &self,
        turn_context: &TurnContext
    ) -> Option<i64> {
        let model_info = &turn_context.model_info;
        let personality = turn_context.personality.or(turn_context.config.personality);

        let base_instructions = BaseInstructions {
            text: model_info.get_model_instructions(personality),
        };

        self.estimate_token_count_with_base_instructions(&base_instructions)
    }

    pub(crate) fn estimate_token_count_with_base_instructions(
        &self,
        base_instructions: &BaseInstructions,
    ) -> Option<i64> {
        let base_tokens =
            i64::try_from(approx_token_count(&base_instructions.text)).unwrap_or(i64::MAX);

        let items_tokens = self
            .items
            .iter()
            .map(estimate_item_token_count)
            .fold(0i64, i64::saturating_add);

        Some(base_tokens.saturating_add(items_tokens))
    }
}
```

### 截断策略

```rust
pub struct TruncationPolicy {
    pub max_total_bytes: i64,
    pub item_count_limit: i64,
}

pub fn truncate_text(text: &str, policy: TruncationPolicy) -> String {
    let bytes = text.as_bytes();
    if bytes.len() as i64 <= policy.max_total_bytes {
        return text.to_string();
    }

    // 保留开头和结尾，中间用省略号
    let head_bytes = (policy.max_total_bytes / 2) as usize;
    let tail_bytes = (policy.max_total_bytes - head_bytes as i64 - 3) as usize;

    let head = &bytes[..head_bytes];
    let tail = &bytes[bytes.len() - tail_bytes..];

    format!(
        "{}...{}",
        String::from_utf8_lossy(head),
        String::from_utf8_lossy(tail)
    )
}
```

**策略选择**：
- 保留开头：上下文信息
- 保留结尾：最近的输出通常更重要
- 字节级截断：避免 Unicode 边界问题

---

## 上下文压缩

### Compact 端点

Codex 实现了专门的压缩端点来减少上下文大小：

```rust
pub async fn compact_conversation_history(
    &self,
    prompt: &Prompt,
    model_info: &ModelInfo,
    otel_manager: &OtelManager,
) -> Result<Vec<ResponseItem>> {
    if prompt.input.is_empty() {
        return Ok(Vec::new());
    }

    let client_setup = self.current_client_setup().await?;
    let transport = ReqwestTransport::new(build_reqwest_client());

    let client = ApiCompactClient::new(transport, client_setup.api_provider, client_setup.api_auth)
        .with_telemetry(Some(request_telemetry));

    let payload = ApiCompactionInput {
        model: &model_info.slug,
        input: &prompt.input,
        instructions: &instructions,
    };

    client.compact_input(&payload, extra_headers).await
}
```

### 压缩策略

压缩端点使用 LLM 将长对话历史转换为等效但更短的表示：
- 移除冗余信息
- 合并重复模式
- 保留关键决策点

---

## 历史规范化

### 规范化流程

```rust
impl ContextManager {
    /// 返回发送到模型的历史，应用规范化并丢弃不适合的项目
    pub(crate) fn for_prompt(
        mut self,
        input_modalities: &[InputModality]
    ) -> Vec<ResponseItem> {
        self.normalize_history(input_modalities);
        self.items.retain(|item| !matches!(item, ResponseItem::GhostSnapshot { .. }));
        self.items
    }
}
```

### 图像剥离

当模型不支持图像输入时，自动剥离图像内容：

```rust
pub(crate) fn replace_last_turn_images(&mut self, placeholder: &str) -> bool {
    let Some(index) = self.items.iter().rposition(|item| {
        matches!(item, ResponseItem::FunctionCallOutput { .. })
            || matches!(item, ResponseItem::Message { role, .. } if role == "user")
    }) else {
        return false;
    };

    match &mut self.items[index] {
        ResponseItem::FunctionCallOutput { output, .. } => {
            let Some(content_items) = output.content_items_mut() else {
                return false;
            };
            for item in content_items.iter_mut() {
                if matches!(item, FunctionCallOutputContentItem::InputImage { .. }) {
                    *item = FunctionCallOutputContentItem::InputText {
                        text: placeholder.clone(),
                    };
                    replaced = true;
                }
            }
            replaced
        }
        _ => false,
    }
}
```

---

## 轮次边界管理

### 用户轮次识别

```rust
pub(crate) fn drop_last_n_user_turns(&mut self, num_turns: u32) {
    if num_turns == 0 {
        return;
    }

    let snapshot = self.items.clone();
    let user_positions = user_message_positions(&snapshot);

    let n_from_end = usize::try_from(num_turns).unwrap_or(usize::MAX);
    let cut_idx = if n_from_end >= user_positions.len() {
        first_user_idx
    } else {
        user_positions[user_positions.len() - n_from_end]
    };

    self.replace(snapshot[..cut_idx].to_vec());
}
```

### 项目成对删除

删除消息时保持调用/输出对的完整性：

```rust
pub(crate) fn remove_first_item(&mut self) {
    if !self.items.is_empty() {
        let removed = self.items.remove(0);
        // 如果删除的项目参与调用/输出对，
        // 同时删除对应的配对项目
        normalize::remove_corresponding_for(&mut self.items, &removed);
    }
}
```

---

## 引用追踪

### 引用剥离

```rust
pub fn strip_citations(text: &str) -> (String, Vec<Citation>) {
    // 解析引用标记如 [^1^]
    // 返回清理后的文本和引用列表
}

async fn record_stage1_output_usage_for_completed_item(
    turn_context: &TurnContext,
    item: &ResponseItem,
) {
    let Some(raw_text) = raw_assistant_output_text_from_item(item) else {
        return;
    };

    let (_, citations) = strip_citations(&raw_text);
    let thread_ids = get_thread_id_from_citations(citations);

    if let Some(db) = state_db::get_state_db(turn_context.config.as_ref(), None).await {
        let _ = db.record_stage1_output_usage(&thread_ids).await;
    }
}
```

---

## 参考上下文快照

### TurnContextItem

```rust
/// 参考上下文快照用于差异计算
pub struct TurnContextItem {
    pub cwd: PathBuf,
    pub approval_policy: AskForApproval,
    pub sandbox_policy: SandboxPolicy,
    pub model: String,
    pub effort: Option<ReasoningEffortConfig>,
    pub summary: ReasoningSummaryConfig,
}
```

### 上下文差异注入

Codex 会检测上下文变化并生成模型可见的设置更新：

```rust
/// 当 reference_context_item 为 None 时，
/// 将下一轮视为无基线，发出完整上下文状态重新注入
```

---

## 最佳实践

### 1. 字节级估算

```rust
// 使用字节启发式而非精确 Tokenizer
// 优点：
// - 不需要加载 Tokenizer 模型
// - 计算速度快
// - 足够准确的近似

pub fn approx_token_count(text: &str) -> usize {
    // 简单启发式：4 字节 ≈ 1 token（英文平均）
    text.len() / 4
}
```

### 2. 历史持久化原子性

```rust
// 好的做法：单系统调用写入保证原子性
let mut line = serde_json::to_string(&entry)?;
line.push('\n');  // 完整行准备就绪
file.write_all(line.as_bytes())?;  // 单次写入
```

### 3. 渐进式截断

```rust
// 软上限策略避免频繁裁剪
const HISTORY_SOFT_CAP_RATIO: f64 = 0.8;

// 当达到 100% 时，裁剪到 80%
// 这样在下次达到 100% 前有更多缓冲
```

---

## 比较矩阵

| 策略 | 优点 | 缺点 | 适用场景 |
|------|------|------|----------|
| 字节估算 | 快速，无依赖 | 不够精确 | 实时估算 |
| 精确 Tokenizer | 准确 | 慢，需要模型 | 最终确认 |
| 上下文压缩 | 智能摘要 | 需要 LLM 调用 | 超长对话 |
| 滑动窗口 | 简单 | 可能丢失关键信息 | 简单场景 |

---

## 关键要点

1. **多层次管理**：从字节估算到 LLM 压缩，多策略组合应对不同场景

2. **文件系统原子性**：使用 O_APPEND 和咨询锁保证并发安全

3. **上下文感知截断**：保留开头和结尾，丢弃中间部分

4. **调用/输出对完整性**：删除时保持工具调用的配对关系

5. **引用追踪**：自动追踪和记录引用使用情况，支持溯源

---

## 相关文档

- [Codex LLM 抽象层](../architecture/codex-llm-abstraction.md) - 客户端架构
- [Codex 流式处理](../streaming/codex-streaming.md) - 流式事件管理
- [上下文管理双模式](../context-management/context-management-dual-mode.md) - pi-mono 的上下文管理对比

---

*创建时间：2026-03-04*
*更新时间：2026-03-04*
