---
tags: streaming, realtime, livekit-agents, preflight, flushsentinel, tts, stt, async, architecture, voice-agent
---

# FlushSentinel 与 PREFLIGHT 抢占机制深度分析

> **范围**：LiveKit Agents 中两个核心低延迟优化机制的完整实现：FlushSentinel（TTS 分段信号）和 PREFLIGHT_TRANSCRIPT（意图预判与抢占生成）
>
> **综合自**：livekit/agents（`sources/agent-harness/livekit-agents/`）
>
> **优先级**：P0

---

## 概述

[上一篇笔记](./livekit-agents-duplex-pipeline.md)描述了 LiveKit Agents 的整体管道架构。本文深入两个机制，它们共同回答了一个问题：**框架如何在 <500ms 内让用户听到回复？**

- **FlushSentinel**：解决 LLM→TTS 之间的"分批合成"问题——LLM 说完第一句话时，TTS 就开始合成，不等 LLM 生成完整回复
- **PREFLIGHT_TRANSCRIPT**：解决 STT→LLM 之间的"提前开工"问题——用户还没说完，LLM 就提前开始推理，等用户说完时 LLM 已经领先了一段

两者在时序上互相配合：

```
用户说话 ──────────────────────── 停止说话
         ↑ PREFLIGHT 触发           ↑ 确认用户意图
         │ LLM 开始推理             │ 直接调度已有 SpeechHandle
         │ 生成第一句话 ──FlushSentinel──▶ TTS 立即合成第一句
         │ 继续生成第二句 ──FlushSentinel──▶ TTS 合成第二句
         ▼
   "有了这两层优化，用户停止说话的瞬间音频就可以开始播放"
```

---

## 第一部分：FlushSentinel — LLM→TTS 分段信号

### 问题：为什么需要分段合成？

如果 TTS 等 LLM 生成完整回复才开始合成，用户就需要等待整个生成过程。但实际上每个"句子"都是独立的合成单元——只要 LLM 产出第一句话，TTS 就可以开始工作。

FlushSentinel 就是 LLM 告诉 TTS "**这一段文字可以合成了**" 的信号。

---

### 1. 定义：纯标记类

**`types.py:50-51`**

```python
class FlushSentinel:
    pass
```

这是一个空的标记类（marker class），本身不携带任何数据。它存在的唯一目的是在 `isinstance()` 检查中被识别。

---

### 2. LLMNode 类型：显式支持 FlushSentinel

**`voice/io.py`（实际定义在 `voice/generation.py:23-34`）**

```python
LLMNode = Callable[
    [
        llm.ChatContext,
        list[llm.Tool],
        ModelSettings,
    ],
    AsyncIterable[llm.ChatChunk | str | FlushSentinel]  # ← FlushSentinel 是返回类型的一部分
    | str
    | llm.ChatChunk
    | None
    | Awaitable[...],
]
```

`LLMNode` 的返回类型**显式包含** `FlushSentinel`，这意味着自定义 LLM 节点可以主动插入分段信号。框架的内置 LLM 节点会在每个句子末尾（遇到 `。?!` 等标点时）自动插入 `FlushSentinel`。

---

### 3. LLM 侧：检测并转发

**`voice/generation.py:183-184`**

```python
# 在 _llm_inference_task() 内部的 chunk 处理循环中
elif isinstance(chunk, FlushSentinel):
    text_ch.send_nowait(chunk)   # 原封不动地发往 TTS 通道
```

`text_ch` 是一个 `aio.Chan[str | FlushSentinel]`（Go 风格的异步通道）。LLM 产出的文本和 FlushSentinel 共享同一个通道，保证了顺序性。

---

### 4. TTS 侧：itertools.tee + 分段生成器

**`voice/generation.py:299-331`** 是理解 FlushSentinel 机制的核心：

```python
async def _tts_inference_task(
    node: io.TTSNode,
    input: AsyncIterable[str | FlushSentinel],
    ...
) -> bool:
    input_tee = itertools.tee(input, 2)  # ← 分流为两路
    finished = False

    # 路线 A：计时用，跳过所有 FlushSentinel，只要第一个真实文本的时间戳
    async def _get_start_time() -> None:
        nonlocal start_time
        async for chunk in input_tee[0]:
            if not isinstance(chunk, FlushSentinel):
                start_time = time.perf_counter()
                break

    # 路线 B：实际数据流——遇到 FlushSentinel 时立即返回，关闭当前段
    async def _input_segment() -> AsyncGenerator[str, None]:
        async for chunk in input_tee[1]:
            if isinstance(chunk, FlushSentinel):
                return   # ← 这是魔法所在：让 TTS 的 async for 循环结束
            yield chunk  # 只 yield 纯文本

        nonlocal finished
        finished = True  # 整个输入流耗尽

    _start_time_task = asyncio.create_task(_get_start_time())
    try:
        while not finished:                        # ← 每段对应一次 TTS API 调用
            input_segment = _input_segment()
            pushed_duration += await _tts_node_inference(input_segment, pushed_duration)
    finally:
        await aio.gracefully_cancel(_start_time_task)
```

**执行过程图解：**

```
LLM 输出流:  "你好，"  "有什么"  "可以"  "帮你？"  [FlushSentinel]  "让我"  "查一下。"  [FlushSentinel]
                                                        ↑
                                    _input_segment() 返回，段一结束
                                    _tts_node_inference(段一) 开始合成
                                                                              ↑
                                                          _input_segment() 返回，段二结束
                                                          _tts_node_inference(段二) 开始合成
```

`itertools.tee()` 的妙用在于：两路流共享同一个底层迭代器，但消费速度可以不同——路线 A 只取第一个时间戳就停止，路线 B 持续消费。

---

### 5. Chan 通道：Go 风格的流控

**`utils/aio/channel.py:49-131`**

```python
class Chan(Generic[T]):
    def __init__(self, maxsize: int = 0, ...) -> None:
        self._maxsize = max(maxsize, 0)
        self._gets: deque[asyncio.Future[T | None]] = deque()  # 等待接收的 Future
        self._puts: deque[asyncio.Future[T | None]] = deque()  # 等待发送的 Future
        self._queue: deque[T] = deque()                        # 实际数据队列

    async def send(self, value: T) -> None:
        """阻塞式发送：队列满时等待接收者"""
        while self.full() and not self._close_ev.is_set():
            p = self._loop.create_future()
            self._puts.append(p)
            await p  # 等待接收者消费后唤醒
        self.send_nowait(value)

    async def recv(self) -> T:
        """阻塞式接收：队列空时等待发送者"""
        while self.empty() and not self._close_ev.is_set():
            g = self._loop.create_future()
            self._gets.append(g)
            await g  # 等待发送者发送后唤醒
        return self.recv_nowait()

    async def __anext__(self) -> T:
        try:
            return await self.recv()
        except ChanClosed:
            raise StopAsyncIteration from None
```

这实现了**背压（backpressure）**：如果 TTS 处理慢，LLM 的 `send()` 会自动阻塞，不会无限堆积文本。

| 特性 | 行为 |
|------|------|
| `maxsize=0` | 无限缓冲（默认，LLM 不会被 TTS 阻塞） |
| `maxsize=N` | 有界缓冲（LLM 生产过快时阻塞等待） |
| `close()` | 向所有等待者广播 `ChanClosed`，干净地结束迭代 |
| `__aiter__` | 支持 `async for chunk in text_ch:` 语法 |

---

## 第二部分：PREFLIGHT_TRANSCRIPT — 意图预判与抢占生成

### 问题：LLM TTFT 延迟从哪来？

在 VAD 检测到用户停止说话之后，才开始 LLM 推理，整个链路是串行的：

```
[用户停止说话] → [EOU 检测+延迟] → [LLM 推理 1-3s] → [TTS 合成] → 播放
                                   ↑ LLM 的首字时间（TTFT）是最大瓶颈
```

**抢占生成**的思路：在用户说完之前，当 STT 对前半段已经有足够置信度时，就提前启动 LLM。等用户真正停下来时，LLM 已经领先了。

---

### 1. 三种转录类型的语义区别

**`stt/stt.py:32-50`**

```python
class SpeechEventType(str, Enum):
    INTERIM_TRANSCRIPT = "interim_transcript"
    """实时流式结果，随时可能变化，用于 UI 显示"""

    PREFLIGHT_TRANSCRIPT = "preflight_transcript"
    """STT 足够自信这段文本不会再大改，但用户可能还在继续说话。
    适合触发抢占生成——如果后续文本和现在不符，可以撤销。"""

    FINAL_TRANSCRIPT = "final_transcript"
    """STT 对这段文本完全确认，对应用户的完整说话段落"""
```

三者的关系：
```
时间轴：
┌─────────────────────────────────────────────────────────┐
│ INTERIM: "你好我想"  "你好我想查"  "你好我想查一下"      │
│ PREFLIGHT:                        "你好我想查一下"(触发)  │
│ FINAL:                                          "你好我想查一下北京天气" │
└─────────────────────────────────────────────────────────┘
```

---

### 2. audio_recognition.py：PREFLIGHT 处理逻辑

**`voice/audio_recognition.py:689-731`**

```python
elif ev.type == stt.SpeechEventType.PREFLIGHT_TRANSCRIPT:
    self._hooks.on_interim_transcript(ev, speaking=...)  # 同步给 UI 显示

    if not transcript:
        return

    # 更新预检转录：= 已提交的最终转录 + 新的预检文本
    self._last_final_transcript_time = time.time()
    self._audio_preflight_transcript = (
        self._audio_transcript + " " + transcript
    ).lstrip()                           # 行 716
    self._audio_interim_transcript = transcript  # 行 717

    if self._turn_detection_mode != "manual" or self._user_turn_committed:
        confidence_vals = list(self._final_transcript_confidence) + [confidence]
        # 触发抢占生成！
        self._hooks.on_preemptive_generation(
            _PreemptiveGenerationInfo(
                new_transcript=self._audio_preflight_transcript,  # 完整预检文本
                transcript_confidence=sum(confidence_vals) / len(confidence_vals),
                started_speaking_at=self._speech_start_time,
            )
        )
```

**关键细节**：`_audio_preflight_transcript` 是"已确认的最终转录 + 当前预检转录"的拼接，确保抢占生成使用完整语义，而不只是最新的片段。

---

### 3. 抢占生成的完整生命周期

#### 阶段一：触发（用户说话中）

**`voice/agent_activity.py:1595-1629`**

```python
def on_preemptive_generation(self, info: _PreemptiveGenerationInfo) -> None:
    if (
        not self._session.options.preemptive_generation  # 功能开关
        or self._scheduling_paused                       # 调度暂停
        or (self._current_speech is not None and not self._current_speech.interrupted)
        or not isinstance(self.llm, llm.LLM)
    ):
        return

    self._cancel_preemptive_generation()  # 取消上一次抢占（若有）

    user_message = llm.ChatMessage(
        role="user",
        content=[info.new_transcript],
        transcript_confidence=info.transcript_confidence,
    )

    chat_ctx = self._agent.chat_ctx.copy()
    speech_handle = self._generate_reply(
        user_message=user_message,
        chat_ctx=chat_ctx,
        schedule_speech=False,      # ← 关键：不立即调度播放
        input_details=InputDetails(modality="audio"),
    )

    # 保存快照，用于后续验证
    self._preemptive_generation = _PreemptiveGeneration(
        speech_handle=speech_handle,   # 正在后台生成的 LLM 输出
        user_message=user_message,     # 触发时的转录文本
        info=info,
        chat_ctx=chat_ctx.copy(),      # 触发时的对话上下文快照
        tools=self.tools.copy(),       # 工具列表快照
        tool_choice=self._tool_choice,
        created_at=time.time(),
    )
```

`_generate_reply(schedule_speech=False)` 会启动 LLM 推理任务，但不把生成的 `SpeechHandle` 加入播放队列——它在后台默默生成，等待最终确认。

#### 阶段二：撤销（用户改变了意图）

**`voice/agent_activity.py:1045-1048`**

```python
def _cancel_preemptive_generation(self) -> None:
    if self._preemptive_generation is not None:
        self._preemptive_generation.speech_handle._cancel()  # 取消 LLM 推理任务
        self._preemptive_generation = None
```

每次新的 PREFLIGHT 到来都会先取消旧的抢占生成，再创建新的。这保证了任何时刻最多只有一个抢占生成在进行。

#### 阶段三：确认或丢弃（用户说完后）

**`voice/agent_activity.py:1798-1823`**

```python
speech_handle: SpeechHandle | None = None
if preemptive := self._preemptive_generation:
    if (
        preemptive.info.new_transcript == user_message.text_content  # 转录没变
        and preemptive.chat_ctx.is_equivalent(temp_mutable_chat_ctx) # 上下文没变
        and preemptive.tools == self.tools                            # 工具没变
        and preemptive.tool_choice == self._tool_choice               # 工具策略没变
    ):
        # ✅ 四个条件全满足：复用抢占生成的结果
        speech_handle = preemptive.speech_handle
        preemptive.user_message.metrics = metrics_report  # 注入指标
        self._schedule_speech(speech_handle, priority=SpeechHandle.SPEECH_PRIORITY_NORMAL)
        logger.debug(
            "using preemptive generation",
            extra={"preemptive_lead_time": time.time() - preemptive.created_at},  # ← 记录提前量
        )
    else:
        # ❌ 状态不一致：抢占生成作废，重新生成
        logger.warning("preemptive generation: chat context or tools changed, discarding")
        preemptive.speech_handle._cancel()

    self._preemptive_generation = None
```

`preemptive_lead_time` 就是这套机制节省的时间——LLM 提前开始推理到用户说完之间的时长。

---

### 4. 重要发现：主流 STT 插件不发 PREFLIGHT

**`livekit-plugins-deepgram/stt.py:675-707`**

```python
def _process_stream_event(self, data: dict) -> None:
    is_final_transcript = data["is_final"]    # Deepgram 的 is_final 字段
    is_endpoint = data["speech_final"]        # Deepgram 的 speech_final 字段

    if is_final_transcript:
        final_event = stt.SpeechEvent(
            type=stt.SpeechEventType.FINAL_TRANSCRIPT,   # ← 只发 FINAL
            ...
        )
    else:
        interim_event = stt.SpeechEvent(
            type=stt.SpeechEventType.INTERIM_TRANSCRIPT, # ← 只发 INTERIM
            ...
        )
```

Deepgram、OpenAI 等主流 STT 插件**目前都不发送 PREFLIGHT_TRANSCRIPT**。`PREFLIGHT_TRANSCRIPT` 是框架预留的接口，供：
1. 自定义 STT 实现（如内部私有 STT 服务）
2. 未来 STT 插件升级支持

**在当前实现中，抢占生成是由 `INTERIM_TRANSCRIPT` 触发的**。`audio_recognition.py` 中对 INTERIM 的处理也会调用 `on_preemptive_generation()`（满足一定条件时），PREFLIGHT 只是提供了一个"更确定的 INTERIM"语义。

---

### 5. EOU（End-of-Utterance）检测：框架如何判断"用户说完了"

**`voice/audio_recognition.py:809-938`**

#### 5.1 TurnDetector 模型预测

```python
# 行 842-854
end_of_turn_probability = await turn_detector.predict_end_of_turn(chat_ctx)
unlikely_threshold = await turn_detector.unlikely_threshold(self._last_language)

if (
    unlikely_threshold is not None
    and end_of_turn_probability < unlikely_threshold
):
    # 概率低 → 用户可能还没说完 → 延长等待时间
    endpointing_delay = self._endpointing.max_delay
else:
    endpointing_delay = self._endpointing.min_delay
```

TurnDetector 是一个可插拔的模型接口，默认基于本地 ML 模型（LiveKit 提供了预训练权重）。它接收当前对话历史，输出一个 `[0, 1]` 的"轮次结束概率"。

#### 5.2 延迟等待

```python
# 行 881-889
extra_sleep = endpointing_delay
if last_speaking_time:
    extra_sleep += last_speaking_time - time.time()  # 从最后说话时间计算剩余等待

if extra_sleep > 0:
    try:
        await asyncio.wait_for(self._closing.wait(), timeout=extra_sleep)
    except asyncio.TimeoutError:
        pass  # 超时后继续 EOU 流程
```

**延迟的含义：**
- `min_delay`（如 0.3s）：EOU 概率高时，等 0.3s 就认为说完了
- `max_delay`（如 1.5s）：EOU 概率低时，等 1.5s 才认为说完了（给用户"想一想"的时间）

这样就避免了把句间停顿误认为对话结束。

#### 5.3 最终触发 on_end_of_turn

```python
# 行 914-924
committed = self._hooks.on_end_of_turn(
    _EndOfTurnInfo(
        skip_reply=skip_reply,
        new_transcript=self._audio_transcript,
        transcript_confidence=confidence_avg,
        transcription_delay=transcription_delay or 0,
        end_of_turn_delay=end_of_turn_delay,
        started_speaking_at=started_speaking_at,
        stopped_speaking_at=stopped_speaking_at,
    )
)
```

`on_end_of_turn` 在 `agent_activity.py` 中实现，就是上面第三阶段的"确认或丢弃"逻辑入口。

---

## 完整时序图

```
用户音频输入
    ↓
[VAD] START_OF_SPEECH
    ↓
[STT] INTERIM_TRANSCRIPT ("你好") ──────────────────────────────────→ UI 显示
    ↓
[STT] PREFLIGHT_TRANSCRIPT ("你好我想查") ──→ on_preemptive_generation()
                                                    ↓
                                            _generate_reply(schedule_speech=False)
                                                    ↓
                                         [LLM] 后台开始推理 ─────→ 生成第一句 ──FlushSentinel──→ [TTS 开始合成段一]
    ↓                                                                                           ↓
[STT] FINAL_TRANSCRIPT ("你好我想查一下北京天气")                               [TTS 段一音频缓存中...]
    ↓
[VAD] END_OF_SPEECH
    ↓
[EOU] TurnDetector.predict_end_of_turn() → 概率高
    ↓ min_delay = 0.3s
[audio_recognition] on_end_of_turn()
    ↓
[agent_activity] 检查抢占生成：
  - 转录匹配 ✅
  - 上下文一致 ✅
  - 工具未变 ✅
    ↓
_schedule_speech(preemptive.speech_handle)
    ↓
[TTS 段一] ──→ 用户立即听到音频（LLM 已提前工作了 N 秒）
```

---

## 关键要点

1. **FlushSentinel 是空标记类**：通过 `isinstance()` 检测，在 `text_ch` 通道中与字符串混流，保证顺序性。TTS 侧用 `itertools.tee()` 分两路流分别处理计时和数据分段。

2. **每个 FlushSentinel = 一次独立的 TTS API 调用**：`while not finished` 循环保证每段文本都触发完整的 TTS 推理，第一段合成完成就可以开始播放，不等后续段落。

3. **Chan 是 Go channel 的 Python 实现**：producer-consumer 模型，支持背压控制，`close()` 后所有等待者收到 `ChanClosed` 异常，实现干净的流终止。

4. **抢占生成需要"四元组快照"**：触发时保存转录 + 上下文 + 工具 + 工具策略，EOU 后逐一比较。只要任何一个不一致，就丢弃抢占结果重新生成。这避免了工具调用变化等导致的错误回复。

5. **主流 STT 不发 PREFLIGHT**：Deepgram 等插件目前只发 INTERIM/FINAL，框架通过 INTERIM 的累积触发抢占逻辑。PREFLIGHT_TRANSCRIPT 接口是为自定义 STT 或未来升级预留的更精确触发点。

---

## 相关文档

- [LiveKit Agents 双工管道](./livekit-agents-duplex-pipeline.md) — 整体管道架构概览
- [异步流式一等公民](./async-streaming-first-class.md) — Python 异步流抽象基础
- [流式工具组装](./streaming-tool-assembly.md) — 流式中的工具调用

---

*创建时间：2026-03-20*
*更新时间：2026-03-20*
