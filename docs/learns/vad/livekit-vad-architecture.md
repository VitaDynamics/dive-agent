---
tags: vad, silero, livekit-agents, streaming, voice-activity-detection
---

# VAD 语音活动检测在 LiveKit Agents

> **范围**：VAD 模块的架构设计、Silero 实现、CPU 部署及与其他模块的协作
>
> **综合自**：livekit-agents
>
> **优先级**：P1

---

## 概述

VAD（Voice Activity Detection）是 LiveKit Agents 中用于检测用户语音活动的核心组件。在实时语音对话中，VAD 负责：

1. **语音边界检测** - 检测用户何时开始说话、何时结束
2. **语音活动监控** - 实时跟踪音频中的语音活动
3. **打断检测** - 结合 `AdaptiveInterruptionDetector` 实现用户打断

VAD 是实现自然语音对话的基础，它让 Agent 能够知道用户的会话轮次。

## 核心抽象层

### 类型体系

```
vad.py (核心抽象)
├── VADEventType (枚举)
│   ├── START_OF_SPEECH  - 语音开始
│   ├── INFERENCE_DONE   - 推理完成（每帧）
│   └── END_OF_SPEECH    - 语音结束
├── VADEvent (数据类)
│   ├── type, timestamp, speech_duration, silence_duration
│   ├── frames, probability, inference_duration
│   └── speaking, raw_accumulated_silence/speech
├── VADCapabilities
│   └── update_interval: float (默认 0.032s)
└── VAD (ABC)
    └── stream() -> VADStream

VADStream (ABC)
├── push_frame(frame)     - 推送音频帧
├── flush()              - 标记当前段结束
├── end_input()           - 标记输入结束
├── aclose()             - 异步关闭
└── __anext__()          - 迭代获取 VADEvent
```

### 核心设计

**异步流式处理**：VADStream 继承自 `AsyncIterator[VADEvent]`，通过 `aio.Chan` 实现异步事件通道。

**指标收集**：`_metrics_monitor_task` 收集推理延迟、推理次数等指标，通过 `metrics_collected` 事件发布。

```python
# livekit/agents/vad.py:110-112
self._metrics_task = asyncio.create_task(
    self._metrics_monitor_task(monitor_aiter), name="TTS._metrics_task"
)
```

---

## Silero VAD 实现

### 目录结构

```
livekit-plugins-silero/
├── vad.py                    # VAD 和 VADStream 实现
├── onnx_model.py             # ONNX 模型加载和推理
└── resources/
    └── silero_vad.onnx       # 模型文件
```

### 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `min_speech_duration` | 0.05s | 最小语音持续时间（防误检） |
| `min_silence_duration` | 0.55s | 结束语音前的静音时长 |
| `prefix_padding_duration` | 0.5s | 前缀填充（包含上下文） |
| `activation_threshold` | 0.5 | 语音激活阈值 |
| `deactivation_threshold` | 0.35 | 语音停阈值 |
| `max_buffered_speech` | 60.0s | 最大缓冲语音时长 |
| `sample_rate` | 16000 | 仅支持 8k/16k |
| `force_cpu` | True | 默认 CPU 推理 |

### 推理流程

```python
# vad.py:291-553 (_main_task)
async for input_frame in self._input_ch:
    # 1. 重采样（如需要）
    if self._input_sample_rate != self._opts.sample_rate:
        resampler = rtc.AudioResampler(...)
    
    # 2. 累积样本直到满足窗口大小
    while available_inference_samples >= self._model.window_size_samples:
        # 3. 运行 ONNX 推理
        p = await self._loop.run_in_executor(None, self._model, inference_f32_data)
        p = self._exp_filter.apply(exp=1.0, sample=p)  # 指数平滑
        
        # 4. 状态机判断
        if p >= activation_threshold:
            speech_threshold_duration += window_duration
            if speech_threshold_duration >= min_speech_duration:
                # 触发 START_OF_SPEECH
        else:
            silence_threshold_duration += window_duration
            if silence_threshold_duration >= min_silence_duration:
                # 触发 END_OF_SPEECH
```

### 性能指标

| 采样率 | 窗口大小 | 窗口时长 | 帧处理间隔 |
|--------|----------|----------|-----------|
| 16kHz | 512 samples | **32ms** | 32ms |
| 8kHz | 256 samples | **32ms** | 32ms |

- `update_interval = 0.032s`
- `SLOW_INFERENCE_THRESHOLD = 0.2s`（200ms 延迟告警）

### ONNX Runtime 配置

```python
# onnx_model.py:36-41
opts.inter_op_num_threads = 1      # 线程池 1 线程
opts.intra_op_num_threads = 1      # 单线程执行算子
opts.execution_mode = ORT_SEQUENTIAL  # 顺序执行
opts.add_session_config_entry("session.intra_op.allow_spinning", "0")
```

**设计理由**：VAD 模型轻量，单线程串行减少线程竞争开销，CPU 推理已远超实时需求。

---

## CPU 部署

### 默认行为

```python
# silero/vad.py:69
force_cpu: bool = True  # 默认强制 CPU
```

### 部署选项

```python
# 1. 默认 CPU 推理（推荐）
vad = silero.VAD.load()

# 2. 强制 CPU
vad = silero.VAD.load(force_cpu=True)

# 3. 允许 GPU（如有可用）
vad = silero.VAD.load(force_cpu=False)
```

### 生产环境建议

| 场景 | 推荐配置 |
|------|----------|
| 通用部署 | CPU (`force_cpu=True`) |
| 高并发 | CPU + 水平扩展 |
| 嵌入式 | CPU（GPU 功耗高） |
| 低延迟优先 | CPU（避免 GPU 拷贝开销） |

**结论**：VAD 模型极轻（ONNX 文件），CPU 推理毫无压力，GPU 对此类轻量模型反而增加开销。

---

## 模块协作关系

### 1. VAD + STT → 流式语音识别

```
AudioInput → VADStream → START/END_OF_SPEECH → STT.recognize() → Transcript
```

**关键文件**：`stt/stream_adapter.py`

当 STT 不支持流式时（如 Deepgram、OpenAI STT），VAD 作为桥梁：

1. VAD 检测语音边界（START_OF_SPEECH, END_OF_SPEECH）
2. END_OF_SPEECH 时，将缓存的音频 frames 合并
3. 调用 STT.recognize() 进行识别

```python
# stt/stream_adapter.py:112-127
async for event in vad_stream:
    if event.type == VADEventType.START_OF_SPEECH:
        self._event_ch.send_nowait(SpeechEvent(STT.START_OF_SPEECH))
    elif event.type == VADEventType.END_OF_SPEECH:
        merged_frames = utils.merge_frames(event.frames)
        t_event = await self._wrapped_stt.recognize(buffer=merged_frames, ...)
```

### 2. VAD + AgentSession → 语音输入处理

**关键文件**：`voice/audio_recognition.py`

```
AudioSource → AudioRecognizer._vad_task() → VADStream → _on_vad_event()
                                                            ├── START_OF_SPEECH → 开启用户轮次 span
                                                            ├── INFERENCE_DONE → 触发 hook
                                                            └── END_OF_SPEECH → 提交用户轮次
```

```python
# audio_recognition.py:990-1013
async def _vad_task(self, vad, audio_input, task):
    stream = vad.stream()
    async for frame in audio_input:
        stream.push_frame(frame)
    async for ev in stream:
        await self._on_vad_event(ev)
```

### 3. VAD + Turn Detection → 对话轮次管理

**关键文件**：`voice/turn.py`, `voice/agent_activity.py`

Turn Detection 模式优先级：

```
realtime_llm → vad → stt → manual
```

当 RealtimeModel 不支持 turn_detection 时，VAD 作为备选：

```python
# agent_activity.py:238-240
if not llm_model.capabilities.turn_detection and vad_model and mode is None:
    mode = "vad"
```

### 4. VAD + Interruption Detection → 打断处理

```python
# audio_recognition.py:1016-1039
async def _interruption_task(self, interruption_detection, audio_input, task):
    stream = interruption_detection.stream()
    async for ev in stream:
        await self._on_overlap_speech_event(ev)
```

VAD 监控语音活动，`AdaptiveInterruptionDetector` 检测重叠语音/打断。

---

## 协作架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                        AgentSession                              │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                   AudioRecognizer                            │ │
│  │  ┌──────────────┐    ┌─────────────────────────────────┐ │ │
│  │  │  _vad_task()  │───→│  VADStream                       │ │ │
│  │  │               │    │  ├── START_OF_SPEECH            │ │ │
│  │  │               │    │  ├── INFERENCE_DONE (每帧)       │ │ │
│  │  │               │    │  └── END_OF_SPEECH              │ │ │
│  │  └──────────────┘    └─────────────────────────────────┘ │ │
│  │           │                                                        │ │
│  │           ▼                                                        │ │
│  │  ┌─────────────────────────────────────────────────────────────┐ │ │
│  │  │  _on_vad_event() → AgentActivity                          │ │ │
│  │  │  - on_start_of_speech: 开启用户轮次                        │ │ │
│  │  │  - on_end_of_speech: 提交轮次给 LLM                       │ │ │
│  │  └─────────────────────────────────────────────────────────────┘ │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                              │                                     │
│         ┌────────────────────┼────────────────────┐                │
│         ▼                    ▼                    ▼                │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐        │
│  │   VAD       │    │    STT      │    │  Interruption   │        │
│  │ (Silero)    │    │ (StreamAdapter)│   │  Detector       │        │
│  └─────────────┘    └─────────────┘    └─────────────────┘        │
│         │                    │                    │                 │
│         └────────────────────┼────────────────────┘                 │
│                              ▼                                      │
│                    ┌─────────────────┐                              │
│                    │  Agent (LLM)   │                               │
│                    └─────────────────┘                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 最佳实践

### 1. VAD 模型加载

```python
# 在 prewarm 中加载（避免运行时延迟）
def prewarm(proc: JobProcess):
    proc.userdata["vad"] = silero.VAD.load(
        min_speech_duration=0.05,
        min_silence_duration=0.55,
        prefix_padding_duration=0.5,
    )

async def entrypoint(ctx: JobContext):
    vad = ctx.proc.userdata["vad"]
    agent = Agent(vad=vad, ...)
```

### 2. 参数调优

| 场景 | min_silence_duration | 说明 |
|------|---------------------|------|
| 快速响应 | 0.3~0.4s | 用户说完即打断 |
| 正常对话 | 0.5~0.6s | 平衡体验 |
| 长语音 | 0.8~1.0s | 允许用户思考 |

### 3. 注意事项

- **前缀填充**：0.5s 前缀确保包含语音起始上下文，提高识别准确率
- **最小语音时长**：0.05s 防误检（咳嗽、噪音）
- **CPU 足够**：无需 GPU，单线程 CPU 推理已远超实时

---

## 关键要点

1. **VAD 是流式语音对话的核心** - 检测语音边界、触发 STT 识别、管理对话轮次
2. **Silero VAD 是默认实现** - 轻量级 ONNX 模型，CPU 友好
3. **32ms 帧间隔** - 平衡延迟和计算开销
4. **CPU 推理完全满足需求** - VAD 模型极轻，GPU 反而有额外开销
5. **模块解耦设计** - VAD 与 STT 通过 StreamAdapter 协作，与 AgentSession 通过 AudioRecognizer 协作
6. **VAD 事件驱动架构** - START_OF_SPEECH、INFERENCE_DONE、END_OF_SPEECH 三种事件

---

## 相关文档

- [LiveKit Agents 文档](https://docs.livekit.io/agents/)
- [Silero VAD](https://github.com/snakers4/silero-vad)
- [LiveKit Agents 流式处理](../harness/streaming/livekit-agents-duplex-pipeline.md)

---

## 参考

- [livekit-agents vad.py 源码](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/vad.py)
- [Silero VAD 插件源码](https://github.com/livekit/agents/blob/main/livekit-plugins/livekit-plugins-silero/livekit/plugins/silero/vad.py)
- [StreamAdapter 实现](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/stt/stream_adapter.py)
- [AudioRecognizer 实现](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/voice/audio_recognition.py)

---

*创建时间：2026-03-21*
*更新时间：2026-03-21*
