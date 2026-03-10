---
tags: architecture, observability, tracing, openclaw, opik
---

# OpenClaw Opik 可观测性插件架构

> **范围**：分析 `comet-ml/opik-openclaw` 如何在不侵入 OpenClaw 核心执行链路的前提下，把 Agent 运行事件投影为 Opik trace/span，重点关注数据流转链路与收尾机制
>
> **综合自**：comet-ml/opik-openclaw, OpenClaw plugin hooks
>
> **优先级**：P1

---

## 概述

`opik-openclaw` 不是一个“替代执行器”，而是一个**运行在 OpenClaw Gateway 进程内的观测投影层**。它不接管 Agent 执行，也不修改核心调度逻辑，只订阅 OpenClaw 暴露出的 hook 和诊断事件，然后把这些事件持续折叠为 Opik 中的一条 trace 与多条 span。

它的核心价值不在“记录日志”，而在于把原本离散的 `llm_input`、`tool_call`、`subagent`、`agent_end`、`model.usage` 事件拼成一条可查询、可聚合、可回放的运行轨迹。这个设计对 Agent 框架很重要，因为观测层终于不必侵入主流程，只需要维护一套**会话级状态机**。

---

## 核心设计

### 1. 插件本体是一个状态投影器

入口是 `createOpikService()`，返回一个符合 `OpenClawPluginService` 的服务对象。`start()` 时完成四件事：

1. 解析运行配置，构造 Opik client
2. 注册 LLM / Tool / Subagent hooks
3. 订阅 `model.usage` 诊断事件
4. 启动 stale trace 清理与 flush 重试机制

因此它的角色非常清晰：

- **OpenClaw** 负责产生真实运行事件
- **插件** 负责维护会话态、映射数据模型、异步 flush
- **Opik** 负责承载最终 trace/span 与附件

### 2. 活跃态以 `sessionKey` 为主索引

插件内部最关键的数据结构是：

```ts
const activeTraces = new Map<string, ActiveTrace>();
```

`ActiveTrace` 保存一条会话级 trace 的所有中间态：

- `trace`：Opik trace 引用
- `llmSpan`：当前打开的 LLM span
- `toolSpans`：工具调用 span 集合
- `subagentSpans`：子 Agent span 集合
- `costMeta` / `usage`：成本与 token 使用量累积区
- `output` / `agentEnd`：收尾阶段需要合并的输出与结果

这意味着它不是“来一个事件发一个请求”的无状态 exporter，而是一个**先聚合、后收尾**的状态型 exporter。

### 3. 相关性修复是第一等公民

真实系统里，事件上下文经常不完整。这个插件专门维护了两层相关性修复：

- `sessionByAgentId`：`agentId -> sessionKey`
- `lastActiveSessionKey`：最近活跃会话

当 `after_tool_call` 缺失 `sessionKey` 时，它会按下面顺序兜底：

1. 用 `agentId` 反查
2. 只有一条活跃 trace 时直接命中
3. 回退到最近活跃会话

这个设计很实用，因为观测系统最怕的不是“少一条日志”，而是**span 挂错父节点**。

---

## 数据流转链路

### 主链路

```text
OpenClaw runtime
  -> llm_input
  -> llm_output
  -> before_tool_call / after_tool_call
  -> subagent_* events
  -> agent_end
  -> model.usage diagnostics

Plugin state projector
  -> activeTraces[sessionKey]
  -> trace/span create or update
  -> aggregate output / usage / error / metadata
  -> finalize trace
  -> flush to Opik

Opik
  -> trace timeline
  -> nested spans
  -> usage/cost metadata
  -> optional media attachments
```

### 1. `llm_input`：创建 trace，并打开主 LLM span

`llm_input` 是整条链路的起点。

插件会在这个时刻：

1. 读取 `sessionKey`
2. 如果该会话已有残留 trace，先关闭旧 trace
3. 创建 Opik trace
4. 立刻创建一个 `type=llm` 的 span
5. 把 prompt、system prompt、model、provider、channel、trigger 等信息写入初始元数据
6. 把会话放进 `activeTraces`

这里的关键不是“尽快 flush”，而是**尽早占住 trace identity**。后续所有 tool/subagent 都会挂到这条 trace 或其子 span 下。

### 2. `llm_output`：补输出与 usage，并关闭 LLM span

当模型产出返回时，插件并不结束 trace，只做两件事：

1. 更新当前 `llmSpan` 的输出、usage、model/provider
2. 把 assistant 输出缓存到 `active.output`

然后只结束 `llmSpan`，不结束 trace。

原因很直接：一个 Agent run 在 LLM 之后还可能继续跑工具、拉起 subagent，trace 生命周期必须长于单个 LLM 调用。

### 3. `before_tool_call` / `after_tool_call`：围绕工具调用生成短生命周期 span

工具链路是典型的“两段式 span”：

- `before_tool_call`：创建 tool span，记录入参
- `after_tool_call`：更新结果或错误，随后结束 span

它还有两个关键细节：

1. 优先用 `toolCallId` 做强关联，避免同名工具串线
2. 如果当前会话其实运行在某个 subagent span 下面，会把 tool span 挂到那个 subagent span，而不是直接挂到 trace 根上

因此工具调用在 Opik 里看到的不是一串平铺事件，而是一棵接近真实执行结构的调用树。

### 4. `subagent_*`：把“跨 Agent 调用”折叠成父子 span 关系

插件处理了 `subagent_spawning`、`subagent_spawned`、`subagent_delivery_target`、`subagent_ended` 等事件。核心做法是：

1. 用 `childSessionKey` 识别子 Agent
2. 为子 Agent 在请求方 trace 上创建一个 subagent span
3. 用 `subagentSpanHosts` 维护 `childSessionKey -> host span` 的映射
4. 当子 Agent 内部再发生 tool/llm 事件时，继续把子调用挂在这个 host span 下

这一步很关键，因为它把“多会话、多 agent 的分叉执行”收束回一条可以阅读的父子树，而不是把每个子 Agent 打散成孤立 trace。

### 5. `model.usage`：晚到的成本信息走旁路累积

成本、上下文占用、token 统计不是在主 hook 内直接更新 trace，而是通过诊断事件 `model.usage` 写入 `active.costMeta`。

这样做有两个好处：

- 不要求 usage 与 `llm_output` 同步到达
- 避免在每个小事件上重复写 trace 元数据

最终这些数据会在 trace finalize 时统一合并。

### 6. `agent_end`：先冻结结果，再延迟 finalize

`agent_end` 不是简单的“收到就结束”。插件在这里做的是：

1. 结束所有遗留 tool/subagent span
2. 把 `success`、`error`、`durationMs`、`messages` 存入 `active.agentEnd`
3. 通过 `queueMicrotask()` 延迟真正的 `finalizeTrace()`

这个微任务延迟非常关键。原因是 `agent_end` 和 `llm_output` 可能处于同一个同步调用栈里，如果立即 finalize，最后一条 assistant 输出和 usage 可能还没来得及写入 `active.output`。

所以它采用的是：

```text
agent_end arrives
  -> store final fields
  -> queueMicrotask(finalizeTrace)
  -> give llm_output a last chance to land
  -> merge everything once
```

这是整套设计里最值得借鉴的细节之一。

### 7. `finalizeTrace()`：统一收口，再 flush

真正收尾时，插件会把以下数据合并进 trace：

- 输出文本 / 最后一条 assistant message
- `success`、`durationMs`、`error`
- model / provider / channel / trigger
- 累积 usage
- 诊断事件里的 cost/context 信息

然后：

1. `trace.update(...)`
2. `trace.end()`
3. 从 `activeTraces` 删除状态
4. 调度带重试的 `client.flush()`

因此可以把这套机制理解为：**事件流先进入内存态，最终以一次收口写入的方式落到 Opik。**

---

## 附件分支链路

主 trace/span 之外，它还有一条独立的媒体附件通道：

```text
hook payload
  -> scan local media refs
  -> resolve trace/span entityId
  -> queue upload task
  -> start multipart upload
  -> PUT file parts
  -> complete upload in Opik attachments API
```

这条链路有三个值得注意的点：

1. **完全异步**：附件上传不阻塞主 hook
2. **去重**：同一个 `entityId + filePath` 不重复上传
3. **保守提取**：只接受显式 `media:`、`file://`、Markdown 本地媒体引用，不扫描任意绝对路径文本

这说明作者把“观测主体”与“富媒体补充”明确拆开了，避免附件处理拖垮主 trace 时序。

---

## 可靠性设计

### 1. 所有 `trace.update/end`、`span.update/end` 都走安全包装

插件没有假设 Opik SDK 永远成功，而是用 `safeTraceUpdate`、`safeSpanEnd` 之类的包装函数吞掉异常并计数。这保证了 exporter 出错时，不会反向打爆主业务线程。

### 2. flush 带指数退避

`flushWithRetry()` 会按 `baseDelay * 2^attempt` 退避，最多重试若干次。这样既避免频繁重试，也避免 exporter 因瞬时网络抖动持续丢数。

### 3. inactive trace 会被强制回收

如果某条 trace 长时间无活动，清理线程会：

1. 结束遗留 span
2. 给 trace 打上 `staleCleanup=true`
3. 写入 `StaleTrace` 错误信息
4. 强制 `trace.end()`

这解决了 Agent 异常退出、hook 丢失、半开 trace 永远不结束的问题。

### 4. payload 先 sanitize，再出网

不管是 trace/span 输入输出，还是 `tool_result_persist`，都会先走 sanitizer。目标不是做完整脱敏系统，而是先把不适合直接进入 Opik 的本地引用和结构化 payload 变成更安全、可接受的形式。

---

## 架构启发

对 `dive-agent` 这类 Agent 基础设施，`opik-openclaw` 至少提供了四个值得复用的模式：

1. **观测层应做投影，不应侵入执行器**：只消费 hook/event，把运行态投影为 trace，而不是把 tracing 写进每个业务分支。
2. **收尾要延迟、不要抢跑**：`agent_end` 先冻结结果，真正 finalize 放到微任务，能显著降低“最后一条输出丢失”的概率。
3. **相关性修复要内建**：生产环境里上下文不完整是常态，`sessionKey`、`agentId`、最近活跃会话的多级兜底非常必要。
4. **慢链路独立排队**：flush、附件上传都不应该阻塞主 hook，否则观测会反过来污染时延。

---

## 局限与权衡

- 子 Agent 被折叠到请求方 trace 下，可读性很好，但牺牲了“每个子会话独立 trace”的天然边界。
- exporter 维护了较多内存态映射，换来的是高质量关联；代价是实现复杂度上升。
- `after_tool_call` 的兜底关联能保活，但如果上游上下文持续缺失，仍然存在挂错 span 的风险。
- payload sanitize 偏保守，保证安全，但也可能损失部分原始上下文细节。

---

## 相关文档

- [Opik 与 Bloom 的有机融合方案](../../evaluation/opik-bloom-integration.md) - 从评估与安全视角看 Opik 的上层价值
- [中间件/回调系统](../middleware/middleware-callback-system.md) - 对比其他框架如何暴露可观测性插桩点
- [结构化错误与重试](../error-handling/structured-errors-retry.md) - 对比 exporter 的失败隔离与重试策略

---

## 参考

- [opik-openclaw README](https://github.com/comet-ml/opik-openclaw/blob/main/README.md)
- [opik-openclaw `src/service.ts`](https://github.com/comet-ml/opik-openclaw/blob/main/src/service.ts)
- [opik-openclaw `src/service/hooks/llm.ts`](https://github.com/comet-ml/opik-openclaw/blob/main/src/service/hooks/llm.ts)
- [opik-openclaw `src/service/hooks/tool.ts`](https://github.com/comet-ml/opik-openclaw/blob/main/src/service/hooks/tool.ts)
- [opik-openclaw `src/service/hooks/subagent.ts`](https://github.com/comet-ml/opik-openclaw/blob/main/src/service/hooks/subagent.ts)
- [opik-openclaw `src/service/attachment-uploader.ts`](https://github.com/comet-ml/opik-openclaw/blob/main/src/service/attachment-uploader.ts)

---

*创建时间：2026-03-10*
*更新时间：2026-03-10*
