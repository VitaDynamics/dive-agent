---
tags: middleware, agent, lifecycle, interceptor, comparison
---

# LangChain Middleware vs Pi 执行管线对比

> **范围**：对比 LangChain v1 `AgentMiddleware` 系统与 Pi 的多层执行管线（Agent Loop 回调 + AgentEvent + Harness/Extension Hook），分析 Middleware 模式在 Pi 中的等价实现
>
> **综合自**：langchain v1, pi-mono (agent + agent-harness + coding-agent)
>
> **优先级**：P1

---

## 概述

LangChain v1 引入了一套完整的 `AgentMiddleware` 系统，以统一的类抽象覆盖了 Agent 执行的**全生命周期**——从开始到结束的每个阶段都可以被拦截、观测和修改。这个系统基于 LangGraph 的图节点模型，将 Middleware 生命周期钩子编排进 ReAct Loop 的图结构中，而 `wrap_model_call` / `wrap_tool_call` 则采用洋葱包装模式（onion wrapping）实现拦截。

Pi 没有 "Middleware" 这个概念名称，但它的三层架构实现了等价甚至更细分的能力：

1. **Agent Loop 层**（`AgentLoopConfig` 回调）—— 对应 LC 的生命周期钩子（`before_model`、`after_model`）
2. **Agent Event 层**（`AgentEvent` 流 + `subscribe()`）—— 对应 LC 的旧版 `BaseCallbackHandler`（纯观测）
3. **Harness/Extension 层**（`HookEvent` + `ExtensionRunner`）—— 对应 LC 的拦截器（`wrap_model_call`、`wrap_tool_call`）+ 工具注册

两种设计的根本差异在于：LangChain 将所有能力统一在一个 `AgentMiddleware` 类中；Pi 将能力按层次和职责拆分到三个独立的系统中。

---

## 问题描述

Agent 框架需要一个标准化的扩展机制，允许开发者在不修改框架核心代码的情况下：

1. **观测** Agent 的执行过程（日志、监控、追踪）
2. **修改** Agent 的行为（改写消息、替换模型、注入指令）
3. **阻断** 危险的工具调用或 LLM 响应
4. **注册** 额外的工具/资源到 Agent
5. **控制** Agent 的循环终止条件

LangChain 通过 Middleware 统一解决了这些问题。Pi 通过三层架构分别解决，每一层有明确的职责边界。

---

## 核心概念

### 1. LangChain 的 Middleware 系统

#### 架构：统一的类 + 图节点编排

`AgentMiddleware` 是一个泛型基类（`types.py:383`），提供 12 个可覆写的钩子方法，分为三类：

**A. 生命周期钩子**（图节点模式）

```python
class AgentMiddleware(Generic[StateT, ContextT, ResponseT]):
    state_schema: type[StateT]    # 可自定义状态 schema
    tools: Sequence[BaseTool]     # 可注册额外工具

    def before_agent(self, state, runtime) -> dict | None: ...
    def before_model(self, state, runtime) -> dict | None: ...
    def after_model(self, state, runtime) -> dict | None: ...
    def after_agent(self, state, runtime) -> dict | None: ...
    # + 对应的 async 版本
```

这些钩子被编排为 LangGraph 图节点（`factory.py:1386-1660`），按声明的顺序链式连接：

```
START → before_agent[0] → before_agent[1] → ... → loop_entry
  loop_entry → before_model[0] → ... → before_model[n] → model
  model → after_model[n] → ... → after_model[0]
  ... → after_agent[n] → ... → after_agent[0] → END
```

**B. 拦截器**（洋葱包装模式）

```python
def wrap_model_call(
    self,
    request: ModelRequest,
    handler: Callable[[ModelRequest], ModelResponse],
) -> ModelResponse | AIMessage: ...

def wrap_tool_call(
    self,
    request: ToolCallRequest,
    handler: Callable[[ToolCallRequest], ToolMessage | Command],
) -> ToolMessage | Command: ...
```

这是 Middleware 最强大的能力。`handler` 是一个可多次调用的回调函数，代表"继续执行"。Middleware 可以：

- 调用 `handler(request)` 多次（重试）
- 调用 `handler(request.override(...))` 修改请求
- 完全跳过 handler（短路/缓存）
- 修改返回值后再返回

多个 Middleware 的拦截器通过洋葱包装组合（`factory.py:221`）：

```python
# [middleware_a, middleware_b, middleware_c]
# 包装顺序：a(b(c(handler)))
# Middleware c 最先调用 handler，a 最后
```

**C. 装饰器模式**

除了子类化，LangChain 提供了 7 个装饰器来快速创建 Middleware：

```python
@before_model
def log_before(state: AgentState, runtime: Runtime) -> None:
    print(f"Messages: {len(state['messages'])}")

@wrap_model_call
def retry_on_failure(request: ModelRequest, handler) -> ModelResponse:
    for i in range(3):
        try:
            return handler(request)
        except Exception:
            if i == 2: raise

@before_model(can_jump_to=["end"])
def conditional_exit(state: AgentState, runtime: Runtime):
    if state.get("should_stop"):
        return {"jump_to": "end"}
```

**设计理由**：
- 统一抽象降低学习成本——所有扩展点在一个类中
- 图节点编排利用 LangGraph 的并行能力
- 洋葱包装模式天然支持链式处理（类似 HTTP 中间件）
- 装饰器让简单场景一目了然

**权衡**：
- 优点：一站式管理；状态 schema 合并；装饰器快速开发
- 缺点：图节点编排在 before/after 钩子很多时增加开销；同步/异步版本重复实现；与 LangGraph 耦合

---

### 2. Pi 的三层等价架构

#### 层 1：Agent Loop 回调（执行控制）

**对应关系**：`AgentLoopConfig` 回调 ≈ LC 的 `before_model`/`after_model` 生命周期钩子

```typescript
// packages/agent/src/types.ts:135
export interface AgentLoopConfig {
    // 生命周期控制
    transformContext: (messages) => Promise<AgentMessage[]>   // ≈ LC before_model (修改上下文)
    convertToLlm: (messages) => Message[]                      // ≈ LC before_model (消息转换)
    prepareNextTurn: (ctx) => TurnUpdate                       // ≈ LC before_model (控制轮次)
    shouldStopAfterTurn: (ctx) => boolean                      // ≈ LC after_model (终止决策)

    // 工具拦截
    beforeToolCall: (ctx) => Promise<{ block?: boolean }>      // ≈ LC wrap_tool_call
    afterToolCall: (ctx) => Promise<{ patch? }>                // ≈ LC wrap_tool_call 的返回修改

    // 其他
    getApiKey: (provider) => Promise<string>
    getSteeringMessages: () => Promise<AgentMessage[]>
    getFollowUpMessages: () => Promise<AgentMessage[]>
}
```

这些是**函数回调**，由 `Agent.prompt()` 创建 `AgentLoopConfig`（`agent.ts:422`），然后传入 `runLoop()`（`agent-loop.ts:159`），在执行流的关键节点直接调用。它们是**同步执行、影响控制流**的，返回值参与逻辑判断。

关键区别：LC 的生命周期钩子返回 `dict | None`（状态更新），被添加到图节点中作为一个独立步骤。Pi 的生命周期回调直接 inline 执行，更轻量但也少了解耦性。

#### 层 2：Agent Event 层（纯观测）

**对应关系**：≈ LC 旧版 `BaseCallbackHandler`（非 Middleware 系统的回调）

```typescript
// packages/agent/src/types.ts:403
export type AgentEvent =
    | { type: "agent_start" }
    | { type: "turn_start" }
    | { type: "message_start"; message: AgentMessage }
    | { type: "message_update"; message: AgentMessage }
    | { type: "message_end"; message: AgentMessage }
    | { type: "tool_execution_start"; toolCallId: string; toolName: string; args: any }
    | { type: "tool_execution_end"; ... }
    | { type: "turn_end"; ... }
    | { type: "agent_end"; messages: AgentMessage[] };
```

这是**只读事件流**，通过 `agent.subscribe(callback)` 注册（`agent.ts:509-556` 调用所有监听器）。用于 UI 更新、Session 持久化、日志记录。不参与执行控制。

#### 层 3：Harness/Extension 层（可拦截管道）

**对应关系**：≈ LC 的 `wrap_model_call` + `wrap_tool_call` + 工具注册

这是 Pi 中最接近 LC Middleware 拦截能力的层，通过 `AgentHarness` 和 `ExtensionRunner` 实现：

```typescript
// coding-agent/src/core/extensions/runner.ts:693
class ExtensionRunner {
    // 链式管道：顺序遍历所有扩展，逐个调用处理器
    async emit<TEvent>(event: TEvent): Promise<RunnerEmitResult<TEvent>> {
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get(event.type);
            if (!handlers) continue;
            for (const handler of handlers) {
                const result = await handler(event, ctx);
                if (result.cancel) return result;  // 短路阻断
            }
        }
        return result;
    }
}
```

Harness 事件类型（20+）支持 block/patch/cancel 语义：

| 事件 | 能力 | LC 等价 |
|------|------|---------|
| `before_agent_start` | 修改 systemPrompt，注入初始消息 | `before_agent` 状态更新 |
| `context` | 替换整个消息数组 | `wrap_model_call` 请求修改 |
| `before_provider_request` | 修改 LLM 请求参数 | `wrap_model_call` 请求修改 |
| `before_provider_payload` | 修改序列化后的 payload | 无直接等价 |
| `tool_call` | 阻断工具执行（`block: true`） | `wrap_tool_call` 短路 |
| `tool_result` | patch 工具结果的 content/details/isError | `wrap_tool_call` 返回修改 |
| `message_end` | 修改消息内容 | `wrap_model_call` 返回修改 |
| `session_before_compact` | 取消或自定义压缩 | 无直接等价 |

**设计理由**：
- 按能力分层：控制流的归 Loop 层、观测的归 Event 层、拦截的归 Harness 层
- Extension 是插件化的——可以热加载/卸载
- 类型安全：每个事件类型有类型化的 Result（通过 `AgentHarnessEventResultMap`）

**权衡**：
- 优点：职责清晰；热插拔；类型安全的 block/patch/cancel
- 缺点：三层系统学习成本高；Hook 分散在多个位置；没有统一的"扩展点"入口

---

### 3. 洋葱包装 vs 链式管道

两种系统都使用了**顺序组合**，但实现方式不同：

**LangChain 洋葱包装**（拦截器）：

```
outer_middleware(inner_middleware(core_handler))
```

每个 Middleware 显式调用 `handler(request)` 来将控制权交给下一层。这给 Middleware 完全的自由：可以在调用前后插入逻辑、完全跳过 handler、或多次调用。

```python
# factory.py:221
def _chain_model_call_handlers(mw_list, core_handler):
    handler = core_handler
    for m in reversed(mw_list):         # 从右向左包装
        handler = make_handler(m, handler)  # 创建闭包
    return handler
```

**Pi 链式管道**（Harness 事件）：

```
for ext in extensions:
    for h in ext.handlers.get(event_type):
        result = await h(event, ctx)   # 顺序遍历，非闭包
        if result.cancel: return
```

每个扩展可以返回 `block` 或 `cancel` 来短路后续处理，也可以返回修改后的数据。但不是闭包模式——下游扩展**看不到**上游扩展的修改，因为事件对象可以原地修改。

**关键差异**：
- LC 的洋葱包装让内层 Middleware 也能感知外层，形成完整的调用栈
- Pi 的链式管道更简单，是顺序处理，不支持"恢复执行"（handler 只能执行一次，不能重试）

---

## 完整对比矩阵

| 维度 | LangChain Middleware | Pi Agent Loop | Pi AgentEvent | Pi Harness/Extension |
|------|---------------------|---------------|---------------|----------------------|
| **核心抽象** | `AgentMiddleware` 类 | `AgentLoopConfig` 回调 | `AgentEvent` 联合类型 | `ExtensionRunner` + `HookEvent` |
| **触发时机** | 图节点 + 洋葱包装 | 内联函数调用 | 事件循环中的 `subscribe` | 扩展管道 `emit()` |
| **修改能力** | 状态更新 + 请求/响应修改 | 上下文/消息/行为修改 | 只读 | block/patch/cancel + 链式修改 |
| **流控制** | `jump_to` 条件跳转 | `shouldStopAfterTurn` 终止 | 无 | `cancel` 短路 |
| **工具注册** | `tools` 属性自动合并 | 无（由配置提供） | 无 | `registerTool()` 按扩展隔离 |
| **状态管理** | `state_schema` 自定义状态合并 | 直接操作 `Agent._state` | 无 | `rootState()` API |
| **组合方式** | 图节点链 + 洋葱闭包 | 顺序函数调用 | 多播（并行通知） | 顺序管道 + 短路 |
| **sync/async** | 显式分 sync/async 方法 | 全部 async（await） | 全部 async | 全部 async |
| **创建方式** | 子类化 + 7 个装饰器 | 设置 `Agent` 属性 | `agent.subscribe()` | `ExtensionFactory` + `on()` |
| **热插拔** | 不支持 | 不支持 | 支持 add/remove | 支持 reload |
| **类型安全** | Python 泛型 | TypeScript 接口 | TypeScript 联合类型 | TypeScript 泛型 + Phantom |
| **错误处理** | 中间件异常传播到调用方 | 抛错中断循环（有兜底） | 异常不传播 | 异常隔离，记录日志 |

---

## Middleware 能力在 Pi 中的具体映射

以下按 LangChain Middleware 的 12 个钩子方法，逐一映射到 Pi 的对应机制：

### 生命周期钩子映射

| LC 方法 | Pi 等价 | 实现方式 |
|---------|---------|----------|
| `before_agent` | `AgentHarness.before_agent_start` 事件 | Extension 注册 `on("before_agent_start")` 处理器 |
| `after_agent` | `AgentEvent.agent_end` + `AgentHarness.agent_end` | subscribe() 观测；Extension 处理器不参与控制 |
| `before_model` | `AgentLoopConfig.transformContext` + `convertToLlm` + `Harness.before_provider_request` | 在 `streamAssistantResponse` 中按顺序调用 |
| `after_model` | `Harness.after_provider_response` | 在 LLM 响应完成后 emit |

### 拦截器映射

| LC 方法 | Pi 等价 | 实现方式 |
|---------|---------|----------|
| `wrap_model_call` | `Harness.context` + `before_provider_request` + `before_provider_payload` + `after_provider_response` 的组合 | Extension 管道链式处理，可修改 request/response |
| `wrap_tool_call` | `AgentLoopConfig.beforeToolCall` + `afterToolCall` + `Harness.tool_call` + `tool_result` | Agent Loop 钩子做阻断 + Extension 做事件级拦截 |

### 工具/状态注册映射

| LC 能力 | Pi 等价 | 实现方式 |
|---------|---------|----------|
| `tools` 属性 | `ExtensionAPI.registerTool()` | 扩展注册工具，`_refreshToolRegistry()` 合并到 agent |
| `state_schema` | `rootState()` / `Agent._state` | 扩展通过 API 读写根状态；Agent 直接持有 `_state` |
| `transformers` | 无直接等价 | Pi 的流式事件通过 `onPayload`/`onResponse` 处理，但无通用 transformer 链 |

---

## 代码示例：同一功能在两种系统中的实现

### 示例 1：重试失败的模型调用

**LangChain（子类化）**：
```python
class ModelRetryMiddleware(AgentMiddleware):
    def __init__(self, max_retries=2):
        self.max_retries = max_retries

    def wrap_model_call(self, request, handler):
        for attempt in range(self.max_retries + 1):
            try:
                return handler(request)
            except Exception as e:
                if attempt < self.max_retries:
                    time.sleep(2 ** attempt)
                else:
                    raise
```

**Pi（AgentLoopConfig 没有等价——LLM 调用不能从外部重试，但可以通过 Harness 层观测+报告）**：
```typescript
// Pi 的 LLM 调用重试由 provider 层处理（SimpleStreamOptions.maxRetries）
// 外部无法在 AgentLoopConfig 层面拦截和重试模型调用
// 最近的等价是 streamSimple 的 onResponse 回调，但只有观测能力
```

**差异**：LC 的 `wrap_model_call` 可以多次调用 handler 实现重试；Pi 的 LLM 调用封装在 `streamFn` 闭包中，外部无法触及 handler。Pi 设计上认为重试是 provider 层的事。

### 示例 2：阻断危险的工具调用

**LangChain**：
```python
class HumanInTheLoopMiddleware(AgentMiddleware):
    def wrap_tool_call(self, request, handler):
        tool_name = request.tool_call["name"]
        if tool_name in DANGEROUS_TOOLS:
            approved = input(f"Approve {tool_name}? (y/n): ")
            if approved.lower() != "y":
                return ToolMessage(
                    content="Blocked by user.",
                    tool_call_id=request.tool_call["id"]
                )
        return handler(request)
```

**Pi**：
```typescript
// Agent Loop 层
agent.beforeToolCall = async ({ toolCall, args }) => {
    if (["rm", "delete"].includes(toolCall.name)) {
        return { block: true };
    }
};

// 或者 Extension 层
extension.on("tool_call", async (event, ctx) => {
    if (event.toolName === "rm") {
        const approved = await ctx.ui.confirm("Approve rm?");
        if (!approved) return { block: true };
    }
});
```

**差异**：LC 通过 `wrap_tool_call` 返回 `ToolMessage` 来"伪造"工具结果（让 LLM 以为工具执行了）；Pi 的 `block: true` 会让 agent-loop 生成一个 error tool result。语义略有不同，但都达到了阻断效果。

### 示例 3：消息上下文裁剪

**LangChain**：
```python
class SummarizationMiddleware(AgentMiddleware):
    def before_model(self, state, runtime):
        messages = state["messages"]
        if count_tokens(messages) > MAX_TOKENS:
            summary = summarize(messages[:-10])
            state["messages"] = [SystemMessage(summary)] + messages[-10:]
            return {"messages": state["messages"]}
```

**Pi**：
```typescript
agent.transformContext = async (messages) => {
    const tokens = estimateTokens(messages);
    if (tokens > MAX_TOKENS) {
        const summary = await summarize(messages.slice(0, -10));
        return [systemMessage(summary), ...messages.slice(-10)];
    }
    return messages;
};
```

**差异**：功能完全等价。LC 返回 `dict` 状态更新（图节点写回）；Pi 直接返回修改后的消息数组（内联转换）。Pi 更简洁，LC 更显式（明确的状态变更）。

---

## 设计哲学对比

### 本质差异：钩子的组织方式

两种系统的 Agent 均独立于钩子存在——不带 Middleware 的 LangChain agent 一样能跑，不注册任何 hook 的 Pi agent 也照常执行。本质差异**不是谁定义生命周期**，而是**钩子的组织方式**：

- **LangChain（打包派）**：生命周期钩子打包在一个类里。你要介入多个阶段（比如同时做 `before_model` + `wrap_tool_call`），就子类化一个 `AgentMiddleware`，覆写对应方法，传进去。**一个类 = 一组生命周期干预点**。

- **Pi（松散派）**：生命周期钩子分散在三处独立注册。`beforeToolCall` 设到 Agent 属性上，观测用 `agent.subscribe()`，拦截用 `extension.on("tool_call")`。**互不依赖，各自注册**。

| 维度 | LangChain（打包派） | Pi（松散派） |
|------|--------------------|-------------|
| 钩子组织 | 一个子类囊括多个阶段钩子 | 三处独立注册点，各自管理 |
| 耦合度 | 一个类 = 一组干预点，内聚在一个文件 | 互不依赖，改一处不影响别处 |
| 心智模型 | "创建一个 Middleware 来介入 Agent" | "到对应的注册点挂一个回调/事件处理器" |
| 典型用法 | `create_agent(model, middleware=[My()])` | `agent.beforeToolCall = fn` + `agent.subscribe()` + `ext.on(...)` |

### LangChain：大一统的 Middleware 类

- 所有扩展点集成在一个基类中
- 子类化 + 装饰器两种创建方式
- 强依赖于 LangGraph（图执行引擎）
- Middleware 之间的顺序直接影响执行行为
- 适合**库设计者**：一次性定义好所有 Middleware，提交给 `create_agent()`

### Pi：职责分离的三层架构

- 控制权归 Loop 层、观测归 Event 层、拦截归 Extension 层
- 各自独立注册，互不耦合
- 不依赖特定执行引擎（纯函数式 ReAct loop）
- Extension 支持热加载/卸载
- 适合**应用开发者**：按需在任意层级注入代码，灵活度高

---

## 最佳实践

1. **简单观测用 Event 层**：如果只需要记录日志、显示 UI 进度，用 `agent.subscribe()` 接收 `AgentEvent`，不需要接触 Middleware/Extension
2. **执行控制用 Loop 层**：需要修改消息、决定停止、block 工具时，设置 `AgentLoopConfig` 回调
3. **复杂拦截用 Extension 层**：需要跨消息、跨工具的一致性拦截逻辑（如 PII 检测、内容审核），用 Extension 注册多个事件类型的处理器
4. **遵循职责单一**：不要在一个 Extension 里同时做观测和拦截——观测注册到 `after_*` 事件，拦截注册到 `before_*` 事件
5. **注意执行顺序**：Pi 的 Extension 按加载顺序遍历，先注册的先处理。LC 的 Middleware 按列表顺序，第一个 Middleware 是最外层包装

### 反模式

- 在 Event 层的 handler 中修改状态（它是只读的事件流）
- 在 Loop 层的回调中做异步耗时操作（会阻塞 LLM 调用）
- 在 `before_model` 中修改未初始化的 state 字段

---

## 相关文档

- [Agent Hook 系统对比：Pi vs LangChain](./hook-system-comparison.html) —— Pi 三层 Hook 架构与 LC 旧版 Callback 系统的对比
- [Pi Hook & ReAct Loop 架构](./pi-hook-react-loop-architecture.html) —— Pi 的 ReAct 循环执行流程详解
- [LangChain Callback 系统](./langchain-callback-system.html) —— LC 旧版 Callback（Mixin-Based）的详细分析

---

## 参考

- [LangChain v1 Middleware 源码](https://github.com/langchain-ai/langchain/blob/master/libs/langchain_v1/langchain/agents/middleware/types.py)
- [LangChain create_agent 集成点](https://github.com/langchain-ai/langchain/blob/master/libs/langchain_v1/langchain/agents/factory.py)
- [Pi Agent 源码](https://github.com/earendil-works/pi-mono/blob/main/packages/agent/src/agent.ts)
- [Pi Agent Loop 源码](https://github.com/earendil-works/pi-mono/blob/main/packages/agent/src/agent-loop.ts)
- [Pi Extension Runner 源码](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/src/core/extensions/runner.ts)

---

*创建时间：2026-06-04*
*更新时间：2026-06-04*
