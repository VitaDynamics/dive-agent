# Kimi-CLI 架构深度分析

> **Related topics**: [[kosong-package]], [[kaos-package]], [[wire-protocol]], [[agent-spec]], [[labor-market]]

## 概述

Kimi-CLI 是一个现代化的 AI Agent CLI 工具，采用分层架构设计，实现了 Soul（核心智能）、Wire（通信协议）和 UI（多种界面）的完全分离。其核心设计理念是 **"一切皆异步、一切皆可扩展、一切皆可控"**。

---

## 1. 整体架构层级

Kimi-CLI 采用清晰的五层架构：

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLI Layer                                │
│  (kimi_cli.cli.__main__ / cli.py)                               │
│  - 命令行参数解析，入口点                                         │
├─────────────────────────────────────────────────────────────────┤
│                          App Layer                               │
│  (kimi_cli.app.KimiCLI)                                         │
│  - 应用生命周期管理，配置加载，多UI模式协调                        │
├─────────────────────────────────────────────────────────────────┤
│                       Runtime Layer                              │
│  (kimi_cli.soul.agent.Runtime)                                  │
│  - 运行时环境：技能、OAuth、审批、子代理市场、环境检测              │
├─────────────────────────────────────────────────────────────────┤
│                        Agent Layer                               │
│  (kimi_cli.soul.agent.Agent)                                    │
│  - Agent 配置：系统提示词、工具集、子代理定义                       │
├─────────────────────────────────────────────────────────────────┤
│                        Soul Layer                                │
│  (kimi_cli.soul.kimisoul.KimiSoul)                              │
│  - 核心智能循环：LLM交互、工具调用、状态管理、D-Mail机制           │
└─────────────────────────────────────────────────────────────────┘
```

### 代码示例

**App 创建流程** (`kimi_cli/app.py:54-168`):
```python
class KimiCLI:
    @staticmethod
    async def create(
        session: Session,
        config: Config | Path | None = None,
        model_name: str | None = None,
        # ... 其他参数
    ) -> KimiCLI:
        config = load_config(config)
        oauth = OAuthManager(config)
        llm = create_llm(provider, model, thinking=thinking, ...)
        
        # 1. 创建 Runtime
        runtime = await Runtime.create(config, oauth, llm, session, yolo, skills_dir)
        
        # 2. 加载 Agent
        agent = await load_agent(agent_file, runtime, mcp_configs=mcp_configs or [])
        
        # 3. 恢复/创建 Context
        context = Context(session.context_file)
        await context.restore()
        
        # 4. 创建 Soul
        soul = KimiSoul(agent, context=context)
        return KimiCLI(soul, runtime, env_overrides)
```

---

## 2. Agent Spec 系统（YAML 配置、继承、工具选择）

### 核心设计

Agent Spec 是一个基于 YAML 的配置系统，支持**继承机制**和**模块化工具选择**。

**AgentSpec 模型** (`kimi_cli/agentspec.py:31-47`):
```python
class AgentSpec(BaseModel):
    extend: str | None = Field(default=None, description="Agent file to extend")
    name: str | Inherit = Field(default=inherit, description="Agent name")
    system_prompt_path: Path | Inherit = Field(default=inherit, description="System prompt path")
    system_prompt_args: dict[str, str] = Field(default_factory=dict)
    tools: list[str] | None | Inherit = Field(default=inherit, description="Tools")
    exclude_tools: list[str] | None | Inherit = Field(default=inherit)
    subagents: dict[str, SubagentSpec] | None | Inherit = Field(default=inherit)
```

### 继承机制

继承通过特殊的 `inherit` 标记实现（`kimi_cli/agentspec.py:24-28`）:
```python
class Inherit(NamedTuple):
    """Marker class for inheritance in agent spec."""
inherit = Inherit()
```

**继承解析逻辑** (`kimi_cli/agentspec.py:123-142`):
```python
if agent_spec.extend:
    base_agent_file = (agent_file.parent / agent_spec.extend).absolute()
    base_agent_spec = _load_agent_spec(base_agent_file)
    
    # 子配置覆盖父配置，未覆盖的继承父配置
    if not isinstance(agent_spec.name, Inherit):
        base_agent_spec.name = agent_spec.name
    if not isinstance(agent_spec.system_prompt_path, Inherit):
        base_agent_spec.system_prompt_path = agent_spec.system_prompt_path
    # ... 其他字段同理
    agent_spec = base_agent_spec
```

### 实际配置示例

**父 Agent** (`kimi_cli/agents/default/agent.yaml`):
```yaml
version: 1
agent:
  name: ""
  system_prompt_path: ./system.md
  system_prompt_args:
    ROLE_ADDITIONAL: ""
  tools:
    - "kimi_cli.tools.multiagent:Task"
    - "kimi_cli.tools.shell:Shell"
    # ... 更多工具
  subagents:
    coder:
      path: ./sub.yaml
      description: "Good at general software engineering tasks."
```

**子 Agent** (`kimi_cli/agents/default/sub.yaml`):
```yaml
version: 1
agent:
  extend: ./agent.yaml  # 继承父配置
  system_prompt_args:
    ROLE_ADDDITIONAL: |
      You are now running as a subagent...
  exclude_tools:  # 排除特定工具
    - "kimi_cli.tools.multiagent:Task"
    - "kimi_cli.tools.multiagent:CreateSubagent"
  subagents: {}  # 空配置覆盖父配置
```

---

## 3. Toolset 和工具加载机制

### 工具类层次结构

Kimi-CLI 使用 `kosong` 包提供的工具基类：

```
CallableTool2[Params] (kosong.tooling)
    ├── name: str
    ├── description: str  
    ├── params: type[Params] (Pydantic BaseModel)
    └── async __call__(self, params: Params) -> ToolReturnValue

KimiToolset (kimi_cli.soul.toolset)
    ├── 内置工具加载
    ├── MCP 工具加载
    └── Wire 外部工具注册
```

### 工具定义示例

**ReadFile 工具** (`kimi_cli/tools/file/read.py:45-185`):
```python
class Params(BaseModel):
    path: str = Field(description="The path to the file to read.")
    line_offset: int = Field(default=1, ge=1)
    n_lines: int = Field(default=MAX_LINES, ge=1)

class ReadFile(CallableTool2[Params]):
    name: str = "ReadFile"
    params: type[Params] = Params

    def __init__(self, runtime: Runtime) -> None:
        # 通过 Runtime 依赖注入
        super().__init__(description=...)
        self._runtime = runtime
        self._work_dir = runtime.builtin_args.KIMI_WORK_DIR

    async def __call__(self, params: Params) -> ToolReturnValue:
        # 参数已自动验证为 Params 类型
        p = KaosPath(params.path).expanduser()
        # ... 实现逻辑
        return ToolOk(output="...", message="...")
```

### 工具加载机制

**依赖注入模式** (`kimi_cli/soul/toolset.py:178-200`):
```python
@staticmethod
def _load_tool(tool_path: str, dependencies: dict[type[Any], Any]) -> ToolType | None:
    module_name, class_name = tool_path.rsplit(":", 1)
    module = importlib.import_module(module_name)
    tool_cls = getattr(module, class_name, None)
    
    args: list[Any] = []
    if "__init__" in tool_cls.__dict__:
        for param in inspect.signature(tool_cls).parameters.values():
            if param.kind == inspect.Parameter.KEYWORD_ONLY:
                break  # 遇到 keyword-only 参数停止注入
            if param.annotation not in dependencies:
                raise ValueError(f"Tool dependency not found: {param.annotation}")
            args.append(dependencies[param.annotation])
    return tool_cls(*args)
```

### MCP 工具集成

**MCP 工具加载** (`kimi_cli/soul/toolset.py:203-325`):
```python
async def load_mcp_tools(self, mcp_configs: list[MCPConfig], runtime: Runtime, ...):
    async def _connect_server(server_name: str, server_info: MCPServerInfo):
        async with server_info.client as client:
            for tool in await client.list_tools():
                server_info.tools.append(MCPTool(server_name, tool, client, runtime=runtime))
            for tool in server_info.tools:
                self.add(tool)
    
    # 后台异步连接
    if in_background:
        self._mcp_loading_task = asyncio.create_task(_connect())
```

---

## 4. LaborMarket 和子代理管理系统

### LaborMarket 设计

LaborMarket 是子代理的注册中心，支持**固定子代理**和**动态子代理**两种模式 (`kimi_cli/soul/agent.py:183-201`):

```python
class LaborMarket:
    def __init__(self):
        self.fixed_subagents: dict[str, Agent] = {}      # 配置定义的子代理
        self.fixed_subagent_descs: dict[str, str] = {}   # 固定子代理描述
        self.dynamic_subagents: dict[str, Agent] = {}    # 运行时创建的子代理

    @property
    def subagents(self) -> Mapping[str, Agent]:
        return {**self.fixed_subagents, **self.dynamic_subagents}
```

### 子代理 Runtime 复制策略

**固定子代理**（独立 LaborMarket）:
```python
def copy_for_fixed_subagent(self) -> Runtime:
    return Runtime(
        config=self.config,
        oauth=self.oauth,
        llm=self.llm,
        session=self.session,
        builtin_args=self.builtin_args,
        denwa_renji=DenwaRenji(),  # 独立的 DenwaRenji
        approval=self.approval.share(),  # 共享审批状态
        labor_market=LaborMarket(),  # 独立的 LaborMarket
        environment=self.environment,
        skills=self.skills,
    )
```

**动态子代理**（共享 LaborMarket）:
```python
def copy_for_dynamic_subagent(self) -> Runtime:
    return Runtime(
        # ... 相同配置
        denwa_renji=DenwaRenji(),
        approval=self.approval.share(),
        labor_market=self.labor_market,  # 共享 LaborMarket
        # ...
    )
```

### 子代理创建和执行

**CreateSubagent 工具** (`kimi_cli/tools/multiagent/create.py:24-58`):
```python
class CreateSubagent(CallableTool2[Params]):
    async def __call__(self, params: Params) -> ToolReturnValue:
        if params.name in self._runtime.labor_market.subagents:
            return ToolError(message=f"Subagent with name '{params.name}' already exists.")
        
        subagent = Agent(
            name=params.name,
            system_prompt=params.system_prompt,
            toolset=self._toolset,  # 共享工具集
            runtime=self._runtime.copy_for_dynamic_subagent(),
        )
        self._runtime.labor_market.add_dynamic_subagent(params.name, subagent)
        
        # 持久化到会话状态
        self._runtime.session.state.dynamic_subagents.append(
            DynamicSubagentSpec(name=params.name, system_prompt=params.system_prompt)
        )
        self._runtime.session.save_state()
```

**Task 工具执行子代理** (`kimi_cli/tools/multiagent/task.py:52-161`):
```python
class Task(CallableTool2[Params]):
    async def _run_subagent(self, agent: Agent, prompt: str) -> ToolReturnValue:
        super_wire = get_wire_or_none()
        
        # 子代理事件转发到父 wire
        def _super_wire_send(msg: WireMessage) -> None:
            if isinstance(msg, ApprovalRequest | ApprovalResponse | ToolCallRequest):
                super_wire.soul_side.send(msg)  # 审批请求直接透传
                return
            event = SubagentEvent(task_tool_call_id=current_tool_call_id, event=msg)
            super_wire.soul_side.send(event)
        
        # 创建独立 context 和 soul
        subagent_context_file = await self._get_subagent_context_file()
        context = Context(file_backend=subagent_context_file)
        soul = KimiSoul(agent, context=context)
        
        await run_soul(soul, prompt, _ui_loop_fn, asyncio.Event())
        # 提取子代理最后一条消息作为结果
        return ToolOk(output=context.history[-1].extract_text())
```

---

## 5. Context 和对话历史管理

### Context 设计

Context 负责对话历史的**持久化**和**Checkpoint 管理** (`kimi_cli/soul/context.py:16-176`):

```python
class Context:
    def __init__(self, file_backend: Path):
        self._file_backend = file_backend
        self._history: list[Message] = []
        self._token_count: int = 0
        self._next_checkpoint_id: int = 0
```

### Checkpoint 机制

Checkpoint 用于支持 **D-Mail（时间旅行）机制**:

```python
async def checkpoint(self, add_user_message: bool):
    checkpoint_id = self._next_checkpoint_id
    self._next_checkpoint_id += 1
    
    async with aiofiles.open(self._file_backend, "a") as f:
        await f.write(json.dumps({"role": "_checkpoint", "id": checkpoint_id}) + "\n")
```

### 时间旅行（Revert）

```python
async def revert_to(self, checkpoint_id: int):
    # 1. 旋转日志文件
    rotated_file_path = await next_available_rotation(self._file_backend)
    await aiofiles.os.replace(self._file_backend, rotated_file_path)
    
    # 2. 恢复指定 checkpoint 之前的历史
    self._history.clear()
    async with aiofiles.open(rotated_file_path) as old_file, \
               aiofiles.open(self._file_backend, "w") as new_file:
        async for line in old_file:
            line_json = json.loads(line)
            if line_json["role"] == "_checkpoint" and line_json["id"] == checkpoint_id:
                break
            await new_file.write(line)
            # 重建内存状态
```

---

## 6. Wire 协议和 UI 分离设计

### Wire 协议核心设计

Wire 是一个 **SPMC（单生产者多消费者）** 消息总线，实现 Soul 和 UI 的完全解耦 (`kimi_cli/wire/__init__.py:18-148`):

```python
class Wire:
    """
    A spmc channel for communication between the soul and the UI during a soul run.
    """
    def __init__(self, *, file_backend: WireFile | None = None):
        self._raw_queue = WireMessageQueue()      # 原始消息队列
        self._merged_queue = WireMessageQueue()   # 合并后消息队列
        self._soul_side = WireSoulSide(self._raw_queue, self._merged_queue)
        
    @property
    def soul_side(self) -> WireSoulSide:
        return self._soul_side
        
    def ui_side(self, *, merge: bool) -> WireUISide:
        if merge:
            return WireUISide(self._merged_queue.subscribe())
        else:
            return WireUISide(self._raw_queue.subscribe())
```

### 消息类型层次

```
WireMessage
├── Event (事件，单向通知)
│   ├── TurnBegin / TurnEnd
│   ├── StepBegin / StepInterrupted
│   ├── CompactionBegin / CompactionEnd
│   ├── StatusUpdate
│   ├── ContentPart (TextPart, ThinkPart, ImageURLPart...)
│   ├── ToolCall / ToolCallPart
│   ├── ToolResult
│   ├── ApprovalResponse
│   └── SubagentEvent
│
└── Request (请求，需响应)
    ├── ApprovalRequest (用户审批)
    └── ToolCallRequest (外部工具调用)
```

### Soul 侧发送逻辑

```python
class WireSoulSide:
    def send(self, msg: WireMessage) -> None:
        # 发送原始消息
        self._raw_queue.publish_nowait(msg)
        
        # 合并可合并的消息（如连续的 TextPart）
        match msg:
            case MergeableMixin():
                if self._merge_buffer is None:
                    self._merge_buffer = copy.deepcopy(msg)
                elif self._merge_buffer.merge_in_place(msg):
                    pass  # 合并成功
                else:
                    self.flush()
                    self._merge_buffer = copy.deepcopy(msg)
            case _:
                self.flush()
                self._send_merged(msg)
```

### 多种 UI 实现

**Shell UI** (`kimi_cli/ui/shell/__init__.py`):
- 交互式终端界面
- 支持 slash 命令
- 实时流式显示
- 基于 prompt_toolkit

**Print UI** (`kimi_cli/ui/print/__init__.py`):
- 非交互式，适合脚本调用
- 支持 JSON stream 输入
- 支持 text/json 输出

**ACP UI** (`kimi_cli/ui/acp/__init__.py`):
- Agent Communication Protocol
- 适合作为服务运行

**Wire Server** (`kimi_cli/wire/server.py`):
- stdio/jsonrpc 接口
- 供外部客户端连接

---

## 7. Soul 循环（KimiSoul.run）的设计

### Soul 协议

```python
@runtime_checkable
class Soul(Protocol):
    @property
    def name(self) -> str: ...
    @property
    def model_name(self) -> str: ...
    @property
    def status(self) -> StatusSnapshot: ...
    
    async def run(self, user_input: str | list[ContentPart]):
        """Run the agent with given input until max steps or no more tool calls."""
```

### KimiSoul 核心循环

**Run 方法入口** (`kimi_cli/soul/kimisoul.py:231-258`):
```python
async def run(self, user_input: str | list[ContentPart]):
    await self._runtime.oauth.ensure_fresh(self._runtime)
    
    wire_send(TurnBegin(user_input=user_input))
    user_message = Message(role="user", content=user_input)
    
    if command_call := parse_slash_command_call(text_input):
        # 处理 slash 命令
        await self._run_slash_command(command_call)
    elif self._loop_control.max_ralph_iterations != 0:
        # Ralph 模式（自动循环）
        runner = FlowRunner.ralph_loop(user_message, self._loop_control.max_ralph_iterations)
        await runner.run(self, "")
    else:
        # 普通单次运行
        await self._turn(user_message)
    
    wire_send(TurnEnd())
```

### Agent Loop（步骤循环）

```python
async def _agent_loop(self) -> TurnOutcome:
    step_no = 0
    while True:
        step_no += 1
        if step_no > self._loop_control.max_steps_per_turn:
            raise MaxStepsReached(self._loop_control.max_steps_per_turn)
        
        wire_send(StepBegin(n=step_no))
        
        # 1. 检查 Context 长度，需要时压缩
        if self._context.token_count + reserved >= self._runtime.llm.max_context_size:
            await self.compact_context()
        
        # 2. 执行单步
        step_outcome = await self._step()
        
        # 3. 处理 D-Mail（时间旅行）
        if dmail := self._denwa_renji.fetch_pending_dmail():
            raise BackToTheFuture(dmail.checkpoint_id, [...])
        
        # 4. 检查是否结束
        if step_outcome.stop_reason == "no_tool_calls":
            return TurnOutcome(...)
```

### 单步执行逻辑

```python
async def _step(self) -> StepOutcome | None:
    # 1. 调用 kosong.step 生成 LLM 响应
    result = await kosong.step(
        chat_provider,
        self._agent.system_prompt,
        self._agent.toolset,
        self._context.history,
        on_message_part=wire_send,    # 流式内容发送到 UI
        on_tool_result=wire_send,     # 工具结果发送到 UI
    )
    
    # 2. 等待所有工具执行完成
    tool_results = await result.tool_results()
    
    # 3. 更新 Context
    await self._grow_context(result, tool_results)
    
    # 4. 检查是否有拒绝
    if any(isinstance(r.return_value, ToolRejectedError) for r in tool_results):
        return StepOutcome(stop_reason="tool_rejected", ...)
    
    # 5. 检查是否还有工具调用
    if result.tool_calls:
        return None  # 继续下一步
    return StepOutcome(stop_reason="no_tool_calls", ...)
```

---

## 8. kosong 和 kaos 包的职责

### kosong - LLM 抽象层

> kosong 是印尼语/马来语中 "空" 的意思，代表纯净的抽象层。

**核心模块**:

```python
# kosong/__init__.py
async def step(
    chat_provider: ChatProvider,
    system_prompt: str,
    toolset: Toolset,
    history: Sequence[Message],
    *,
    on_message_part: Callback[[StreamedMessagePart], None] | None = None,
    on_tool_result: Callable[[ToolResult], None] | None = None,
) -> "StepResult":
    """Run one agent step."""
```

**Chat Provider 抽象**:
```python
# kosong/chat_provider/__init__.py
class ChatProvider(Protocol):
    async def generate(self, system_prompt, tools, history) -> MessageStream: ...
    @property
    def model_name(self) -> str: ...
    @property
    def capabilities(self) -> set[ModelCapability]: ...
```

**支持 Provider**: Kimi, OpenAI, Anthropic, Google GenAI

### kaos - Kimi Agent Operating System

> kaos 提供操作系统级别的异步抽象。

**核心功能** (`kaos/__init__.py`):

```python
@runtime_checkable
class Kaos(Protocol):
    """Kimi Agent Operating System (KAOS) interface."""
    
    # 文件系统操作
    async def readtext(self, path, ...) -> str: ...
    async def writetext(self, path, data, ...) -> int: ...
    def iterdir(self, path) -> AsyncGenerator[KaosPath]: ...
    
    # 进程执行
    async def exec(self, *args, env=None) -> KaosProcess: ...
    
    # 路径管理
    def normpath(self, path) -> KaosPath: ...
    async def chdir(self, path) -> None: ...
```

**实现方式**:
- `kaos.local.LocalKaos` - 本地文件系统和进程
- 可通过上下文变量切换实现（支持远程 SSH 等场景）

---

## 9. 独特的设计模式

### 9.1 D-Mail（时间旅行）模式

受《命运石之门》启发，允许工具向过去发送消息改变执行流程。

```python
# kimi_cli/soul/denwarenji.py
class DMail(BaseModel):
    message: str
    checkpoint_id: int  # 目标 checkpoint

class DenwaRenji:
    def send_dmail(self, dmail: DMail):
        self._pending_dmail = dmail
    
    def fetch_pending_dmail(self) -> DMail | None:
        pending = self._pending_dmail
        self._pending_dmail = None
        return pending
```

在 Agent Loop 中处理:
```python
if dmail := self._denwa_renji.fetch_pending_dmail():
    raise BackToTheFuture(dmail.checkpoint_id, [system_message])
    # 被捕获后执行 revert_to(checkpoint_id)
```

### 9.2 Steer（舵轮）模式

允许 UI 在运行中向 Soul 注入实时指令。

```python
def steer(self, content: str | list[ContentPart]) -> None:
    """Queue a steer message for injection into the current turn."""
    self._steer_queue.put_nowait(content)
```

Steer 被实现为**合成工具调用**:
```python
async def _inject_steer(self, content) -> None:
    steer_id = f"steer_{uuid4().hex[:8]}"
    await self._context.append_message([
        Message(role="assistant", tool_calls=[
            ToolCall(id=steer_id, function=ToolCall.FunctionBody(name="_steer", ...))
        ]),
        Message(role="tool", content=[system(f"Real-time instruction: {text}")], tool_call_id=steer_id)
    ])
```

### 9.3 ContextVar 依赖管理

使用 Python 的 `contextvars` 实现隐式依赖传递:

```python
# kimi_cli/soul/__init__.py
_current_wire = ContextVar[Wire | None]("current_wire", default=None)

def get_wire_or_none() -> Wire | None:
    return _current_wire.get()

def wire_send(msg: WireMessage) -> None:
    wire = get_wire_or_none()
    assert wire is not None
    wire.soul_side.send(msg)
```

### 9.4 Broadcast Queue 模式

实现多消费者消息订阅:

```python
# kimi_cli/utils/broadcast.py
class BroadcastQueue[T]:
    def subscribe(self) -> Queue[T]:
        """Create a new subscriber queue."""
        queue = Queue[T](maxsize=self._maxsize)
        self._subscribers.append(queue)
        return queue
    
    def publish_nowait(self, item: T) -> None:
        for queue in self._subscribers:
            queue.put_nowait(item)
```

### 9.5 技能（Skill）系统

基于 Markdown + Frontmatter 的轻量级扩展系统:

```markdown
---
name: repo-learner
description: Learn about a code repository
type: flow
---

# Repository Learning

## Usage
Send `/skill:repo-learner` to activate.
```

支持两种类型:
- `standard` - 普通技能（注入提示词）
- `flow` - 流程技能（支持 Mermaid/D2 流程图定义 Agent 工作流）

---

## 相关文件

| 文件 | 描述 |
|------|------|
| `kimi_cli/app.py` | 应用主类，协调各层 |
| `kimi_cli/soul/kimisoul.py` | Soul 核心实现 |
| `kimi_cli/soul/agent.py` | Agent 和 Runtime 定义 |
| `kimi_cli/soul/context.py` | 对话历史管理 |
| `kimi_cli/soul/toolset.py` | 工具加载和管理 |
| `kimi_cli/wire/__init__.py` | Wire 协议实现 |
| `kimi_cli/wire/types.py` | Wire 消息类型定义 |
| `kimi_cli/agentspec.py` | Agent YAML 规范 |
| `packages/kosong/` | LLM 抽象层 |
| `packages/kaos/` | 操作系统抽象层 |

---

*Last updated: 2026-02-25*
