---
tags: actor-model, rust, agent-harness, concurrency, best-practice, kameo, ractor
---

# Rust Actor Runtime 作为 Agent Harness 基座：Kameo vs Ractor

> **综合自**: kameo, ractor
>
> **结论先行**: 如果目标是给 `dive-agent` 选一个更稳的 agent harness 实现基座，我更推荐 **`ractor`**。  
> `kameo` 更适合做 async-first、Tokio-native、带内建 tracing/metrics 的快速原型；`ractor` 更适合做需要明确生命周期、监督、优先级、worker/factory 路由和可控停机语义的长期运行时内核。

---

## 问题定义

Agent harness 不是普通业务服务。它通常同时承担这几类职责：

- **会话隔离**：每个 session / agent run 都需要自己的状态边界
- **请求-响应**：主控 agent 要能同步等待 model/tool/subagent 的结果
- **事件流**：token、tool-progress、trace、UI status 需要持续扇出
- **监督与取消**：子 agent 卡死、tool 超时、run 被用户终止时，需要明确收尾语义
- **并发治理**：tool worker 池、session 粘性路由、背压、限流不能全靠业务层手写

所以这次选型的重点不是“谁的 actor API 更顺手”，而是“谁更像一个能承载 harness 的运行时骨架”。

---

## 方案 A：Kameo

### 它更像什么

`kameo` 是一个 **Tokio-first、async 友好、类型化 request/reply 体验很顺手** 的 actor 框架。  
它有这些很吸引 harness 的点：

- `ask` / `tell` API 直接，且支持 `mailbox_timeout`、`reply_timeout`
- actor 可以 `attach_stream`，把外部 stream 挂进 actor 生命周期
- 内建 `tracing`、`metrics`、`otel` feature
- 自带 supervision 模块，支持 `OneForOne / OneForAll / RestForOne`
- 内建 remote 模式，底层直接走 `libp2p`

### 映射到 agent harness 的数据流

如果用 `kameo` 搭 harness，一个比较自然的链路是：

```text
UserTurn
  -> SessionActor.ask(TurnInput)
  -> PlannerActor.ask(PlanStep)
  -> ToolPool.ask/Tell(ToolCall)
  -> attach_stream(TokenDelta / ToolProgress / TraceEvent)
  -> EventSink.tell(EventEnvelope)
  -> SessionActor.reply(TurnResult)
```

它的优点是：

- **把流式 token / tool progress 接进 actor 很自然**
- **请求超时是现成能力**，不用业务层重复包一层
- **如果以后真想做 P2P agent swarm**，`libp2p` 集成路径比多数 actor 库更直接
- **观测接入成本低**，适合快速把 tracing/metrics 打通

### 它不够适合作为基座的地方

问题不在“不能做”，而在“做成 runtime kernel 之后，很多关键语义不如 `ractor` 明确”：

- **运行时优先级语义不够突出**  
  harness 很在意 `Kill`、`Stop`、普通消息、监督事件谁先处理；`kameo` 有生命周期和 supervision，但对“优先级调度语义”没有 `ractor` 那么明确的运行时文档和建模。
- **worker/factory 级别编排能力偏轻**
  它有 `ActorPool`，但更偏“负载均衡池”；如果你要做 key-based routing、priority queue、discard policy、dead-man's switch、动态 worker 数调整，`ractor` 的现成能力更完整。
- **更偏框架易用性，而不是 runtime 语义完整性**
  对 prototype 是优点；对 harness 内核，这反而意味着很多治理策略要自己补。
- **编译器门槛更高**
  当前 `kameo` 需要 Rust `1.88` 和 `edition = 2024`，这会提高落地门槛。

---

## 方案 B：Ractor

### 它更像什么

`ractor` 明确沿着 **Erlang/OTP 风格运行时语义** 往前走。  
它的核心价值不是“actor 很容易写”，而是“actor 系统在出故障、停机、扩缩容时语义更清楚”。

几个对 harness 很关键的点：

- 明确区分 `Signal(Kill)`、`Stop`、`SupervisionEvent`、普通 `Message` 的优先级
- supervision tree、monitor、registry、process group 都是第一层能力
- `RpcReplyPort` 把 call/reply 语义做成框架原语
- `Factory` 提供 worker 池、路由、队列、限流、discard、动态配置更新
- `OutputPort` 提供事件扇出能力，适合 token/status/trace 广播
- 默认带 `message_span_propogation`

### 映射到 agent harness 的数据流

如果用 `ractor` 搭 harness，一个更像“运行时内核”的链路会是：

```text
UserTurn
  -> SessionSupervisor.call(TurnMessage, timeout)
  -> PlannerActor.call(PlanMessage)
  -> ToolFactory.Dispatch(Job<SessionKey, ToolCall>)
  -> Worker.handle(Job)
  -> OutputPort<TokenEvent / StatusEvent / TraceEvent>
  -> UIActor / TraceCollector / PersistenceActor
  -> SupervisionEvent / Stop / Kill
  -> SessionSupervisor decides restart / stop / cleanup
```

这条链路和 agent harness 的几个核心诉求更贴：

- **session 粘性路由**：同一 session 的任务可以稳定落到同一 worker
- **事件旁路扇出**：token 流不必强耦合在 call 返回值里
- **停机语义更清楚**：正常 stop 和强制 kill 是分开的
- **监督决策更显式**：子 actor 异常退出后由 supervisor 统一收口
- **并发治理更像“平台能力”**：不是每个 tool actor 各自发明限流和队列

### 它的代价

`ractor` 的问题也很明确：

- **开发体验没 `kameo` 那么轻**
  想把一个业务 actor 写出来，模板代码和概念负担更重。
- **cluster 仍需谨慎**
  `ractor_cluster` 已经很完整，但仓库 README 仍明确说不该把它视为 production ready。
- **观测能力更偏“可插拔”而不是“内建套餐”**
  你会拿到 message span propagation、output port、supervision event 这些接点，但要自己把 tracing/metrics 体系拼完整。

---

## 关键维度对比

| 维度 | Kameo | Ractor | 对 harness 的含义 |
|------|------|--------|-------------------|
| actor 易用性 | 更顺手，Tokio-first | 更偏 OTP 风格 | 原型期 `kameo` 占优 |
| request/reply | `ask/tell` 直观，超时现成 | `call/cast` + `RpcReplyPort`，更底层 | 两者都够用 |
| 流式事件接入 | `attach_stream` 很自然 | `OutputPort` 更适合广播扇出 | 单流接入偏 `kameo`，多订阅扇出偏 `ractor` |
| 监督语义 | 有 supervision tree | supervision + monitor + priority channels 更完整 | `ractor` 更适合 runtime 内核 |
| 并发治理 | `ActorPool` 偏基础 | `Factory` 有 routing/queue/discard/rate-limit | `ractor` 明显更强 |
| 运行时可预测性 | 足够，但更偏框架层 | 显式文档化 stop/kill/supervision 优先级 | `ractor` 更稳 |
| 可观测性 | `tracing/metrics/otel` feature 很友好 | 需要自己组装，但接点明确 | 原型接观测偏 `kameo` |
| 分布式方向 | `libp2p` 内建 remote | `ractor_cluster` 仍需谨慎 | 如果要 P2P swarm，`kameo` 更有吸引力 |
| 落地门槛 | Rust `1.88` / edition 2024 | Rust `1.64+`，默认 Tokio | `ractor` 更稳妥 |

### 维护活跃度补充

按 2026-03-10 的 GitHub 官方仓库数据看：

- `kameo`：约 1.2k stars，最近 release 是 `v0.19.2`（2025-11-17）
- `ractor`：约 2.0k stars，最近 release 是 `v0.15.12`（2026-03-09）

两边都还在维护，但 `ractor` 在公开活跃度、发布连续性和生态可见度上更占优，这会降低它作为底层基座的选型风险。

---

## 为什么我给 `dive-agent` 的建议是 Ractor

### 1. Agent harness 更像“运行时内核”，不是“普通 async 应用”

真正难的地方不是把消息发出去，而是：

- run 中途取消时，哪些任务必须立刻停
- 哪些子 actor 异常后要重启，哪些要整棵 session 停掉
- token 流、trace 流、持久化流如何旁路扇出
- tool worker 爆满时，如何限流、排队、丢弃或降级

这些问题上，`ractor` 的语义和现成模块更接近 harness 需要的“操作系统层能力”。

### 2. `Factory + OutputPort + SupervisionEvent` 这组三件套很适合 harness

对 `dive-agent` 这种系统，一个很自然的最小骨架是：

```rust
SessionSupervisor
  -> PlannerActor
  -> ToolFactory
  -> MemoryActor
  -> TraceCollector
  -> UI/Event subscribers
```

其中：

- `Factory` 负责 tool worker 池和路由策略
- `OutputPort` 负责 token/status/trace 广播
- `SupervisionEvent` 负责统一收口子 actor 生命周期

这比“先用轻量 actor 跑起来，再慢慢补平台治理能力”更像一个能长期演进的起点。

### 3. `kameo` 更适合做探索型实现，不是最稳的内核底座

如果目标是：

- 单机 Tokio runtime
- 快速做出一个流式 agent demo
- 很快把 tracing/metrics 接进去
- 未来可能玩 P2P actor swarm

那 `kameo` 非常有吸引力。

但如果目标是把 `dive-agent` 做成一个 **长期可维护的 harness runtime**，我会优先选 `ractor`，然后在上层补更顺手的 API facade。

---

## 落地建议

### 推荐选型

**默认基座：`ractor`**

### 推荐分层

```text
App API Layer
  -> Harness Facade
  -> Ractor Runtime Layer
     - SessionSupervisor
     - ToolFactory
     - OutputPort-based event bus
     - TraceCollector
     - Registry / PG / monitors
  -> Provider / Tool adapters
```

### 什么时候改选 Kameo

满足下面任一条件，可以优先考虑 `kameo`：

- 先做原型，3 周内要出可运行 demo
- 强依赖 Tokio-native stream 接入体验
- 观测体系希望尽量“开 feature 就能用”
- 未来路线偏 libp2p / 去中心化 agent 网络，而不是 OTP 风格 supervision 内核

---

## 最终建议

**如果是给 `dive-agent` 选 agent harness 的实现基座，我建议选 `ractor`。**

一句话概括：

- `kameo` 更像“更顺手的 async actor 框架”
- `ractor` 更像“更适合承载 harness 的 actor 运行时”

前者更适合把东西尽快做出来，后者更适合让这个系统在复杂生命周期、并发治理和故障恢复里站得住。

---

## 参考

- [tqwewe/kameo](https://github.com/tqwewe/kameo)
- [Kameo Book](https://docs.page/tqwewe/kameo)
- [Kameo Distributed Actors](https://github.com/tqwewe/kameo/blob/main/docs/distributed-actors.mdx)
- [Kameo Observability](https://github.com/tqwewe/kameo/blob/main/docs/observability.mdx)
- [slawlor/ractor](https://github.com/slawlor/ractor)
- [Ractor Runtime Semantics](https://github.com/slawlor/ractor/blob/main/docs/runtime-semantics.md)
- [ractor_cluster README](https://github.com/slawlor/ractor/blob/main/ractor_cluster/README.md)
