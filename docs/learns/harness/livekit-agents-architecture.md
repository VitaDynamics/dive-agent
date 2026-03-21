---
tags: agent-architecture, livekit, voice-ai, realtime, websocket, webRTC, latency-optimization
---

# LiveKit Agents 架构设计分析（深度版）

> **Related topics**: [[agent-architecture]], [[voice-ai]], [[realtime-systems]], [[latency-optimization]]

## 概述

LiveKit Agents 是一个用于构建**实时语音、视频和物理 AI Agent**的开源框架。代码层面的设计充满了对**延迟**的极致追求——每一个毫秒都被精心计算过。

**官方文档**: https://docs.livekit.io/agents/
**GitHub**: https://github.com/livekit/agents

---

## 1. 延迟优化的核心哲学

### 1.1 不要等待，要预测

LiveKit Agents 的核心理念：**永远不要等待上一阶段完成才启动下一阶段**。

传统模式：
```
User Speaks → Wait for VAD end → STT → LLM → TTS → Playback
             (阻塞等待)           (阻塞等待)
```

LiveKit 模式：
```
User Speaks → STT (streaming) ──────────────────→ LLM (preemptive)
                                          ↑       → TTS (overlap)
              ←── VAD detects end ───────────
```

### 1.2 "宁可浪费计算，不要浪费等待"

Preemptive generation 策略：一旦收到 STT 的最终转录，立即启动 LLM 推理，即使 VAD 还未确定用户说完。这是用**少量冗余计算换取显著延迟降低**的经典 tradeoff。

---

## 2. 核心延迟优化技术

### 2.1 Preemptive Generation（抢占式生成）

**代码位置**: `audio_recognition.py` - `_on_stt_event()`

```python
if ev.type == stt.SpeechEventType.FINAL_TRANSCRIPT:
    # ...
    if self._vad_base_turn_detection or self._user_turn_committed:
        if transcript_changed:
            self._hooks.on_preemptive_generation(
                _PreemptiveGenerationInfo(
                    new_transcript=self._audio_transcript,
                    transcript_confidence=...,
                    started_speaking_at=self._speech_start_time,
                )
            )
```

**设计意图**：
- STT 返回最终转录时，不等待 VAD 的 end_of_speech 事件
- 直接触发 LLM 推理
- LLM 推理和用户可能的继续说话**并行进行**

**代价**：如果用户继续说话，LLM 需要重新推理
**收益**：首 token 延迟（TTFT）降低 1-2 秒

### 2.2 VoiceActivityVideoSampler（自适应视频采样）

**代码位置**: `agent_session.py`

```python
class VoiceActivityVideoSampler:
    def __init__(self, *, speaking_fps: float = 1.0, silent_fps: float = 0.3):
        self.speaking_fps = speaking_fps      # 用户说话时: 1 FPS
        self.silent_fps = silent_fps            # 沉默时: 0.3 FPS
```

**设计意图**：
- 用户说话时，需要看到嘴型同步的视频 → 1 FPS
- 沉默时，视频基本不变 → 0.3 FPS（节省 70% 带宽）

**这是一个经常被忽视的优化**：大多数实现会用固定帧率，而实际上**视频帧率和音频活动高度相关**。

### 2.3 AEC Warmup（回声消除预热）

**代码位置**: `agent_session.py`

```python
aec_warmup_duration: float | None = 3.0  # 默认 3 秒

def _update_agent_state(self, state: AgentState, ...):
    if state == "speaking" and self._aec_warmup_remaining > 0:
        # Agent 开始说话时，启动 3 秒预热计时器
        self._aec_warmup_timer = self._loop.call_later(
            self._aec_warmup_remaining,
            self._on_aec_warmup_expired
        )
```

**问题**：如果 Agent 一说话用户就打断，AEC 还没准备好，会把用户声音当成回声处理。

**解决方案**：Agent 说话后 3 秒内忽略用户打断，让 AEC 有时间"热身"。

### 2.4 实时音频重采样

**代码位置**: `generation.py` - `_audio_forwarding_task()`

```python
async for frame in tts_output:
    if (frame.sample_rate != audio_output.sample_rate
        and resampler is None):
        resampler = rtc.AudioResampler(
            input_rate=frame.sample_rate,
            output_rate=audio_output.sample_rate,
            num_channels=frame.num_channels,
        )
```

**设计意图**：
- TTS 可能输出 24kHz 音频
- 声卡可能需要 48kHz
- 实时重采样，无须等待

### 2.5 TTFB/TTFT 追踪

**代码位置**: `generation.py`

```python
@dataclass
class _LLMGenerationData:
    ttft: float | None = None  # Time To First Token

@dataclass
class _TTSGenerationData:
    ttfb: float | None = None  # Time To First Byte
```

追踪这两个指标用于：
1. **性能监控**：端到端延迟分解
2. **自适应策略**：根据 TTFT 调整预生成行为
3. **SLA 保障**：确保生产环境延迟达标

---

## 3. 中断处理的精妙设计

### 3.1 三层中断检测架构

```
Layer 1: VAD (Voice Activity Detection)
    ↓ 检测用户开始/结束说话

Layer 2: Adaptive Interruption Detector (ML-based)
    ↓ 判断用户是想打断还是只是咳嗽/清嗓子

Layer 3: False Interruption Recovery
    ↓ 识别"假打断"，自动恢复 Agent 说话
```

### 3.2 Overlapping Speech Sentinel（重叠说话哨兵）

**代码位置**: `audio_recognition.py`

```python
# 当用户开始说话但 Agent 还在说时，发送哨兵事件
_on_overlap_speech_event():
    if ev.is_interruption:
        self._hooks.on_interruption(ev)
```

**关键洞察**：不是简单的"检测到声音就打断"，而是**理解重叠说话的意义**：
- 用户声音 > Agent 声音 → 可能是打断
- Agent 声音 > 用户声音 → 可能是回声/背景音

### 3.3 Transcript Buffering（转录缓冲）

**代码位置**: `audio_recognition.py` - `_should_hold_stt_event()`

```python
def _should_hold_stt_event(self, ev: stt.SpeechEvent) -> bool:
    if self._agent_speaking:
        return True  # Agent 说话时，缓冲用户转录
```

**设计意图**：
1. Agent 说话时，用户的转录被**缓冲**
2. Agent 说完后，**延迟提交**缓冲的转录
3. 避免"用户说了一半被打断，结果转录了半句话"的尴尬

### 3.4 False Interruption Recovery（假打断恢复）

**代码位置**: `speech_handle.py`

```python
INTERRUPTION_TIMEOUT = 5.0  # 5 秒超时

def interrupt(self, *, force: bool = False):
    self._cancel()
    # 5 秒后如果 speech 还没完成，强制取消
    self._interrupt_timeout_handle = asyncio.get_event_loop().call_later(
        INTERRUPTION_TIMEOUT,
        self._on_timeout
    )
```

**假打断恢复流程**：
1. 用户开始说话 → Agent 中断
2. 用户停止说话
3. **2 秒沉默窗口**（`false_interruption_timeout`）
4. 如果 2 秒内用户没继续说 → 认为是假打断
5. Agent **自动恢复**之前被中断的内容

### 3.5 循环等待预防

**代码位置**: `speech_handle.py` - `wait_for_playout()`

```python
async def wait_for_playout(self) -> None:
    if task := asyncio.current_task():
        info = _get_activity_task_info(task)
        if info and info.function_call and info.speech_handle == self:
            raise RuntimeError(
                "cannot call `wait_for_playout()` from inside the function tool"
            )
```

**问题**：如果 function tool 内部调用 `wait_for_playout()` 等待自己生成的 speech，会造成死锁。

**解决**：运行时检测并抛出明确错误，而不是静默死锁。

---

## 4. 异步流水线架构

### 4.1 Channel-based Stream（基于 Channel 的流）

**代码位置**: `generation.py`

```python
@dataclass
class _LLMGenerationData:
    text_ch: aio.Chan[str | FlushSentinel]      # 文本流
    function_ch: aio.Chan[llm.FunctionCall]      # 函数调用流
```

使用自定义的 `aio.Chan`（类似 Go 的 channel）：
- `send_nowait()` - 非阻塞发送
- 支持**背压**（backpressure）机制
- 比 asyncio.Queue 更轻量

### 4.2 Flush Sentinel（刷新哨兵）

```python
# 用于在流式输出中标记"可以刷新到用户了"
text_ch.send_nowait(FlushSentinel)
```

**用途**：
- LLM 输出 tokens 时，不立即发送给 TTS
- 积累到一定程度或遇到句尾，再刷新
- 减少 TTS 的碎片化请求

### 4.3 Async Tee（异步分流）

**代码位置**: `generation.py` - `_tts_inference_task()`

```python
input_tee = itertools.tee(input, 2)

# 一个分支：计时
# 另一个分支：实际处理
async def _get_start_time() -> None:
    async for chunk in input_tee[0]:
        if not isinstance(chunk, FlushSentinel):
            start_time = time.perf_counter()
            break
```

TTS 需要知道"什么时候开始"，以便计算 `ttfb`（Time To First Byte）。通过 tee 分流，一个分支计时，一个分支处理。

---

## 5. Turn Detection 多模式架构

### 5.1 模式选择策略

**代码位置**: `turn.py`

```python
TurnDetectionMode = Literal["stt", "vad", "realtime_llm", "manual"] | _TurnDetector
```

| 模式 | 描述 | 延迟 | 准确性 |
|------|------|------|--------|
| `realtime_llm` | 服务端 LLM 判断 | 低 | 高（需要特定模型） |
| `vad` | 语音活动检测 | 最低 | 中 |
| `stt` | STT 结束判断 | 高 | 高 |
| `manual` | 手动控制 | - | - |

**自动回退**：`realtime_llm` → `vad` → `stt` → `manual`

### 5.2 Dynamic Endpointing（动态断句）

**代码位置**: `endpointing.py`

```python
class EndpointingOptions(TypedDict, total=False):
    mode: Literal["fixed", "dynamic"]  # 固定延迟 vs 动态延迟
    min_delay: float  # 最小沉默时长
    max_delay: float  # 最大等待时长
```

**dynamic 模式**：根据对话内容动态调整等待时长
- 问句后等待短
- 陈述句后等待长

---

## 6. 优先级系统

### 6.1 SpeechHandle Priority

**代码位置**: `speech_handle.py`

```python
class SpeechHandle:
    SPEECH_PRIORITY_LOW = 0      # 低优先级（如后台提示音）
    SPEECH_PRIORITY_NORMAL = 5   # 普通优先级（默认）
    SPEECH_PRIORITY_HIGH = 10     # 高优先级（如紧急通知）
```

**队列管理**：
- 高优先级 speech 可以**抢占**低优先级
- 被打断的 speech 不会丢失，可以恢复

---

## 7. 可观测性设计

### 7.1 完整的追踪体系

**代码位置**: 广泛使用 OpenTelemetry

```python
@tracer.start_as_current_span("llm_node")
async def _llm_inference_task(...):
    current_span.set_attributes({
        trace_types.ATTR_CHAT_CTX: json.dumps(chat_ctx.to_dict()),
        trace_types.ATTR_FUNCTION_TOOLS: list(tool_ctx.function_tools.keys()),
        trace_types.ATTR_RESPONSE_TTFT: data.ttft,
    })
```

### 7.2 关键指标追踪

| 指标 | 描述 | 用途 |
|------|------|------|
| `TTFT` | Time To First Token | LLM 响应速度 |
| `TTFB` | Time To First Byte | TTS 响应速度 |
| `transcription_delay` | 用户说话到转录完成 | STT 性能 |
| `end_of_turn_delay` | 说话结束到 Agent 回复 | 端到端延迟 |
| `EOU_PROBABILITY` | Turn 结束概率 | 断句质量 |

---

## 8. 架构亮点总结

### 8.1 设计原则

1. **预测优于等待**：Preemptive generation 用冗余计算换延迟
2. **自适应优于静态**：动态帧率、动态断句、动态中断检测
3. **精确的错误处理**：不静默失败，每种异常都有明确处理
4. **可观测性优先**：每个关键路径都有 tracing

### 8.2 关键技术选型

| 问题 | 方案 | 理由 |
|------|------|------|
| 实时音频流 | WebRTC | UDP 优于 TCP 的延迟 |
| AI 模型通信 | HTTP/WebSocket | 双向流式，低 overhead |
| 进程间通信 | Agent Server 模式 | 资源隔离，优雅扩缩容 |
| 音频格式转换 | 运行时重采样 | 兼容性优先 |
| 中断检测 | VAD + ML 混合 | 准确性 vs 延迟平衡 |

### 8.3 生产级特性

- **Job 生命周期管理**：Agent 可以被重新调度
- **优雅关闭**：drain 模式确保语音播放完毕
- **Mock Tools**：测试时替换真实工具
- **Preconnect Audio**：连接建立前就开始录音

---

## 9. 对比其他框架

| 特性 | LiveKit Agents | 其他 Voice Agent 框架 |
|------|---------------|----------------------|
| Preemptive Generation | ✅ 原生支持 | 通常没有 |
| Adaptive Video FPS | ✅ 聪明地节省带宽 | 通常固定帧率 |
| False Interruption Recovery | ✅ 自动恢复 | 通常不支持 |
| AEC Warmup | ✅ 防止误打断 | 通常没有 |
| 多模式 Turn Detection | ✅ 自动回退 | 通常单一模式 |
| TTFB/TTFT 追踪 | ✅ 完整 | 通常没有 |

---

## 10. 参考资料

- [LiveKit Agents 文档](https://docs.livekit.io/agents/)
- [LiveKit Agents GitHub](https://github.com/livekit/agents)
- [Voice AI Quickstart](https://docs.livekit.io/agents/start/voice-ai/)
- [Silero VAD](https://github.com/snakers4/silero-vad)
