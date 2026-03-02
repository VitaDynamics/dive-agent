# Pull + Debounced Push 混合流式设计

> **设计来源**: Kimi (kosong) + Pydantic-AI 融合
> **推荐等级**: ⭐⭐⭐⭐⭐ (P0 - 核心设计)

## 核心理念

结合 Kosong 的 **灵活双模式 (Pull/Push)** 与 Pydantic-AI 的 **智能频率控制 (Debounce)**，构建一个既强大又易用的流式抽象层。

```
┌─────────────────────────────────────────────────────────────┐
│                    理想的设计架构                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Provider Stream (Raw Parts)                               │
│        │                                                    │
│        ▼                                                    │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐  │
│   │   Core      │────▶│   Debounce  │────▶│  Callback   │  │
│   │  (Pull)     │     │  (Buffer)   │     │   (Push)    │  │
│   └─────────────┘     └─────────────┘     └─────────────┘  │
│        │                                         │          │
│        │         ┌───────────────────┐           │          │
│        └────────▶│  on_message_part  │◀──────────┘          │
│                  │   (debounced)     │                      │
│                  └───────────────────┘                      │
│                             │                               │
│                             ▼                               │
│                       UI / Consumer                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## 为什么这种混合模式最佳？

### 1. 融合双方优势

| 框架 | 优势 | 这种设计保留 |
|------|------|-------------|
| **Kosong** | 灵活的双模式 (Pull/Push) | ✅ 消费者可选择 |
| **Pydantic-AI** | 智能 debounce 控制频率 | ✅ 避免高频触发 |
| **Pi-Mono** | UI 层批量更新 | ✅ 内置支持 |

### 2. 解决实际问题

**Before (纯 Kosong)**：逐 part 触发 → UI 每 16ms 重渲染 → 卡顿
```rust
agent.generate_with_callback("Write a story", |part| {
    ui.append_text(&part.text);  // 重渲染 100 次/秒
}).await;
```

**After (混合设计)**：debounce 后触发 → 每 100ms 重渲染 → 流畅
```rust
agent.generate_with_callback(
    "Write a story",
    |part| ui.append_text(&part.text),
    StreamConfig {
        debounce_by: Some(Duration::from_millis(100)),
        ..Default::default()
    }
).await;
```

## Rust API 设计

### 核心 Trait

```rust
pub trait StreamingAgent {
    /// 纯 Pull 模式：完全控制消费节奏
    async fn generate(&self, prompt: &str) -> impl Stream<Item = MessagePart>;

    /// 混合模式：Pull 基础 + Debounced Push
    async fn generate_with_callback<F>(
        &self,
        prompt: &str,
        on_message_part: F,
        config: StreamConfig,
    ) -> Result<RunResult>
    where
        F: Fn(&MessagePart) + Send + Sync + 'static;

    /// 结构化输出：带验证 debounce
    async fn generate_structured<T: Deserialize>(
        &self,
        prompt: &str,
        config: StreamConfig,
    ) -> impl Stream<Item = Result<T, ValidationError>>;
}
```

### 配置结构

```rust
pub struct StreamConfig {
    /// 防抖间隔：None = 无防抖（逐 part），Some(100ms) = 聚合输出
    pub debounce_by: Option<Duration>,

    /// Debounce 策略
    pub debounce_policy: DebouncePolicy,

    /// 模式选择
    pub mode: StreamMode,
}

pub enum StreamMode {
    /// 纯 Pull：返回 AsyncIterator
    Pull,
    /// Pull + Debounced Push：同时支持 callback
    Hybrid {
        on_message_part: Box<dyn Fn(&MessagePart) + Send + Sync>,
    },
}

pub struct DebouncePolicy {
    /// 最大等待时间
    pub max_delay: Duration,
    /// 触发字符（标点符号等）
    pub boundary_chars: Vec<char>,
    /// 累积字符数阈值
    pub max_chars: usize,
}

impl Default for DebouncePolicy {
    fn default() -> Self {
        Self {
            max_delay: Duration::from_millis(100),
            boundary_chars: vec!['.', '。', '!', '?', '\n', ' '],
            max_chars: 50,
        }
    }
}
```

## 三种 Debounce 策略

| 策略 | 实现 | 适用场景 |
|------|------|---------|
| **Time-based** | 固定间隔（100ms）触发 | UI 渲染、实时显示 |
| **Content-based** | 遇到标点/空格触发 | 语义完整性、段落感 |
| **Hybrid** | 时间或语义，先到先触发 | 通用场景（推荐） |

### Hybrid 策略示例

```rust
// 场景：输出 "Hello world. This is..."
// 策略：100ms 或遇到句号触发，先到先触发
//
// 时间线：
// T+0ms   : "Hel"      → 累积
// T+30ms  : "lo"       → 累积
// T+60ms  : " wo"      → 累积
// T+90ms  : "rld"      → 累积 (未达100ms)
// T+100ms : "!"        → 触发 "Hello world!" (时间先到)
// T+120ms : " Th"      → 累积
// T+150ms : "is"       → 累积
// T+180ms : "."        → 触发 " This." (语义先到)
```

## 使用示例

### 1. 纯 Pull 模式（精细控制）

```rust
async fn pull_mode(agent: &Agent) {
    let mut stream = agent.generate("Hello").await;
    while let Some(part) = stream.next().await {
        // 完全控制消费节奏
        if should_stop(&part) { break; }
        process(&part).await;
    }
}
```

### 2. 混合模式（推荐）

```rust
async fn hybrid_mode(agent: &Agent) {
    let result = agent.generate_with_callback(
        "Write a story",
        |part| {
            // 这个 callback 被 debounce 后调用
            ui.append_text(&part.text);
        },
        StreamConfig {
            debounce_by: Some(Duration::from_millis(100)),
            debounce_policy: DebouncePolicy::default(),
            ..Default::default()
        }
    ).await;

    println!("Done: {:?}", result.usage);
}
```

### 3. 结构化输出（验证防抖）

```rust
async fn structured_mode(agent: &Agent) {
    let mut stream = agent.generate_structured::<UserProfile>(
        "Extract user info",
        StreamConfig {
            debounce_by: Some(Duration::from_millis(200)),
            ..Default::default()
        }
    ).await;

    while let Some(result) = stream.next().await {
        match result {
            Ok(profile) => println!("Valid: {:?}", profile),
            Err(e) => println!("Partial: {:?}", e.partial_result),
        }
    }
}
```

## 状态管理图示

```
时间线 →
│
├─ Part1("Hel") ── Part2("lo") ── Part3(" ") ── Part4("wo") ── Part5("rld!")
│       │              │              │              │              │
│       └──────────────┴──────────────┘              │              │
│              [Debounce Buffer 100ms]               │              │
│                       │                            │              │
│                       ▼                            ▼              ▼
│              on_message_part("Hello ")     on_message_part("world!")
│
└─ 触发次数：2 次（而不是 5 次）
```

## 内部实现要点

### Debounce Buffer 结构

```rust
pub struct DebounceBuffer {
    buffer: Vec<MessagePart>,
    policy: DebouncePolicy,
    timer: Option<JoinHandle<()>>,
    callback: Box<dyn Fn(&MessagePart) + Send + Sync>,
}

impl DebounceBuffer {
    pub fn push(&mut self, part: MessagePart) {
        // 检查是否需要立即触发（语义边界）
        if self.should_flush_semantic(&part) {
            self.flush();
        }

        self.buffer.push(part);

        // 重置定时器
        if let Some(timer) = self.timer.take() {
            timer.abort();
        }

        let delay = self.policy.max_delay;
        let callback = self.callback.clone();
        self.timer = Some(tokio::spawn(async move {
            sleep(delay).await;
            callback(&part);
        }));
    }

    fn flush(&mut self) {
        if self.buffer.is_empty() { return; }

        let merged = self.buffer.iter().fold(
            MessagePart::default(),
            |acc, part| acc.merge(part)
        );

        (self.callback)(&merged);
        self.buffer.clear();
    }
}
```

## 设计权衡

| 选择 | 优点 | 缺点 | 推荐场景 |
|------|------|------|---------|
| **纯 Pull** | 完全控制，无隐藏逻辑 | 代码冗长 | 复杂业务逻辑 |
| **纯 Push** | 简单直接 | 无法控制频率 | 简单脚本 |
| **Hybrid** | 两者兼得 | 复杂度中等 | **大部分场景** |

## 与其他设计的对比

| 设计 | 频率控制 | 消费者控制 | 适用性 |
|------|---------|-----------|--------|
| Kosong 原生 | ❌ 无 | ✅ Pull/Push | 通用 |
| Pydantic-AI | ✅ Debounce | ❌ 有限 | 结构化输出 |
| Pi-Mono | ✅ UI层 | ✅ 灵活 | TypeScript |
| **这种设计** | ✅ 内置 | ✅ 可选 | **通用 + 性能** |

## 结论

这种 **Pull + Debounced Push 混合设计** 是 LLM 流式抽象层的最佳实践：

1. **默认智能**：开箱即用的 debounce 避免 UI 卡顿
2. **灵活可选**：消费者可选择 Pull 或 Push
3. **策略可配**：时间、语义或混合策略
4. **类型安全**：利用 Rust 类型系统保证正确性

---

*最后更新: 2026-02-26*
