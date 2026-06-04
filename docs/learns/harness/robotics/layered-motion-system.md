---
tags: robotics, motion-control, embodied-ai, reachy
---

# 分层运动系统（Layered Motion System）

> **范围**：机器人运动控制中的分层架构设计，实现主要动作与次要偏移的融合
>
> **综合自**：reachy-mini-conversation-app
>
> **优先级**：P0

---

## 概述

分层运动系统是一种用于机器人实时运动控制的架构模式。它将运动分为两层：

1. **主要动作层（Primary Moves）**：顺序执行的互斥动作，如舞蹈、情绪表达、位置移动和呼吸动画
2. **次要偏移层（Secondary Offsets）**：叠加在主要动作之上的实时偏移，如语音反应摇摆和面部追踪

这种设计的核心思想是：**单一控制点 + 姿态融合**。所有运动最终通过一个 `set_target()` 接口输出，在每一帧将主要姿态和次要偏移融合后发送给机器人。

这种模式对于 Embodied AI 应用至关重要，因为它解决了以下问题：
- 如何让机器人在执行预设动作的同时，保持对语音的实时反应
- 如何在不打断当前动作的情况下，叠加面部追踪功能
- 如何确保运动的平滑过渡，避免姿态跳变

---

## 问题描述

### 挑战

在机器人对话应用中，运动系统面临多重挑战：

1. **并发运动需求**：机器人需要在说话时摇摆头部（语音反应），同时可能正在执行舞蹈或情绪动作
2. **实时性要求**：语音反应需要 200ms 内的延迟，面部追踪需要持续更新
3. **平滑过渡**：动作之间的切换不能有跳变，需要插值
4. **资源竞争**：多个线程可能同时请求不同的运动

### 传统方案的局限

| 方案 | 问题 |
|------|------|
| 直接调用机器人 API | 无法协调多个运动源，导致冲突和跳变 |
| 状态机 | 难以处理叠加运动，状态爆炸 |
| 优先级抢占 | 低优先级运动被完全忽略，失去细微表现 |

---

## 核心概念

### 1. 双层运动架构

#### 框架：reachy-mini-conversation-app

系统将运动分为两个层次：

```python
# moves.py - 核心架构设计
"""
Design overview
- Primary moves (emotions, dances, goto, breathing) are mutually exclusive and run sequentially.
- Secondary moves (speech sway, face tracking) are additive offsets applied on top of the current primary pose.
- There is a single control point to the robot: `ReachyMini.set_target`.
- The control loop runs near 100 Hz and is phase-aligned via a monotonic clock.
"""
```

**主要动作（Primary Moves）**：
- **互斥执行**：一次只有一个主要动作在运行
- **队列管理**：动作按顺序排队执行
- **类型**：`BreathingMove`、`DanceQueueMove`、`EmotionQueueMove`、`GotoQueueMove`

**次要偏移（Secondary Offsets）**：
- **叠加模式**：多个偏移可以同时生效
- **实时更新**：来自音频或视觉线程的实时数据
- **类型**：语音摇摆偏移（`speech_offsets`）、面部追踪偏移（`face_tracking_offsets`）

```python
@dataclass
class MovementState:
    """Movement system state tracking."""
    # Primary move state
    current_move: Move | None = None
    move_start_time: float | None = None
    last_activity_time: float = 0.0

    # Secondary move state (offsets)
    speech_offsets: Tuple[float, float, float, float, float, float] = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    face_tracking_offsets: Tuple[float, float, float, float, float, float] = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
```

**设计理由**：
- 主要动作需要完整控制机器人，不能同时执行两个舞蹈
- 次要偏移是"点缀"，不会破坏主要动作的完整性
- 分层设计简化了并发控制

---

### 2. 姿态融合（Pose Composition）

#### 框架：reachy-mini-conversation-app

姿态融合是将主要姿态和次要偏移合并的核心机制：

```python
# moves.py
def combine_full_body(primary_pose: FullBodyPose, secondary_pose: FullBodyPose) -> FullBodyPose:
    """Combine primary and secondary full body poses."""
    primary_head, primary_antennas, primary_body_yaw = primary_pose
    secondary_head, secondary_antennas, secondary_body_yaw = secondary_pose

    # Head pose: use compose_world_offset for proper 3D transform composition
    combined_head = compose_world_offset(primary_head, secondary_head, reorthonormalize=True)

    # Antennas and body_yaw: simple addition
    combined_antennas = (
        primary_antennas[0] + secondary_antennas[0],
        primary_antennas[1] + secondary_antennas[1],
    )
    combined_body_yaw = primary_body_yaw + secondary_body_yaw

    return (combined_head, combined_antennas, combined_body_yaw)
```

**关键点**：
- **头部姿态**：使用 4x4 变换矩阵，通过 `compose_world_offset` 进行正确的 3D 变换组合
- **天线和身体偏航**：简单加法，因为它们是单自由度的

```python
# Full body pose type definition
FullBodyPose = Tuple[NDArray[np.float32], Tuple[float, float], float]
# (head_pose_4x4_matrix, (left_antenna, right_antenna), body_yaw)
```

**权衡**：
- 优点：数学上正确的姿态组合，避免万向节锁
- 缺点：需要理解 3D 变换矩阵，调试复杂度高

---

### 3. 100 Hz 实时控制循环

#### 框架：reachy-mini-conversation-app

控制循环是整个系统的心脏，以 100 Hz 频率运行：

```python
# moves.py
CONTROL_LOOP_FREQUENCY_HZ = 100.0  # Hz - Target frequency

def working_loop(self) -> None:
    """Control loop main movements - single set_target() call with pose fusion."""
    logger.debug("Starting enhanced movement control loop (100Hz)")

    while not self._stop_event.is_set():
        loop_start = self._now()

        # 1) Poll external commands and apply pending offsets (atomic snapshot)
        self._poll_signals(loop_start)

        # 2) Manage the primary move queue (start new move, end finished move, breathing)
        self._update_primary_motion(loop_start)

        # 3) Update vision-based secondary offsets
        self._update_face_tracking(loop_start)

        # 4) Build primary and secondary full-body poses, then fuse them
        head, antennas, body_yaw = self._compose_full_body_pose(loop_start)

        # 5) Apply listening antenna freeze or blend-back
        antennas_cmd = self._calculate_blended_antennas(antennas)

        # 6) Single set_target call - the only control point
        self._issue_control_command(head, antennas_cmd, body_yaw)

        # 7) Adaptive sleep to align to next tick
        sleep_time, freq_stats = self._schedule_next_tick(loop_start, freq_stats)

        if sleep_time > 0:
            time.sleep(sleep_time)
```

**设计理由**：
- 100 Hz 是机器人控制的常见频率，平衡了响应性和计算负载
- 使用 `time.monotonic()` 避免系统时间跳变
- 自适应睡眠确保稳定的控制频率

---

### 4. 线程安全的状态管理

#### 框架：reachy-mini-conversation-app

由于多个线程需要与运动系统交互，状态管理需要特别小心：

```python
# moves.py
class MovementManager:
    def __init__(self, current_robot: ReachyMini, camera_worker: Any = None):
        # Cross-thread signalling
        self._command_queue: "Queue[Tuple[str, Any]]" = Queue()

        # Secondary offsets with dirty flags and locks
        self._speech_offsets_lock = threading.Lock()
        self._pending_speech_offsets: Tuple[float, ...] = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        self._speech_offsets_dirty = False

        self._face_offsets_lock = threading.Lock()
        self._pending_face_offsets: Tuple[float, ...] = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        self._face_offsets_dirty = False
```

**线程安全模式**：

```python
def set_speech_offsets(self, offsets: Tuple[float, ...]) -> None:
    """Thread-safe: Update speech-induced secondary offsets."""
    with self._speech_offsets_lock:
        self._pending_speech_offsets = offsets
        self._speech_offsets_dirty = True

def _apply_pending_offsets(self) -> None:
    """Apply the most recent speech/face offset updates (called in control loop)."""
    with self._speech_offsets_lock:
        if self._speech_offsets_dirty:
            self.state.speech_offsets = self._pending_speech_offsets
            self._speech_offsets_dirty = False
```

**设计理由**：
- **脏标志模式**：避免每次循环都获取锁，只在有更新时才复制数据
- **命令队列**：主要动作通过队列传递，确保状态变更只在控制线程中发生
- **原子快照**：控制循环中一次性获取所有需要的偏移量

---

### 5. 语音反应运动（Speech Reactive Motion）

#### 框架：reachy-mini-conversation-app

语音反应是通过分析音频信号生成实时运动偏移：

```python
# audio/speech_tapper.py
class SwayRollRT:
    """Feed audio chunks -> per-hop sway outputs."""

    def feed(self, pcm: NDArray[Any], sr: int | None) -> List[Dict[str, float]]:
        """Stream in PCM chunk. Returns sway dicts, one per hop (HOP_MS=50ms)."""
        # ... audio processing ...

        # Oscillators for each DOF
        pitch = (math.radians(SWAY_A_PITCH_DEG) * loud * env *
                 math.sin(2 * math.pi * SWAY_F_PITCH * self.t + self.phase_pitch))
        yaw = (math.radians(SWAY_A_YAW_DEG) * loud * env *
               math.sin(2 * math.pi * SWAY_F_YAW * self.t + self.phase_yaw))
        roll = (math.radians(SWAY_A_ROLL_DEG) * loud * env *
                math.sin(2 * math.pi * SWAY_F_ROLL * self.t + self.phase_roll))

        # Translation oscillators
        x_mm = SWAY_A_X_MM * loud * env * math.sin(2 * math.pi * SWAY_F_X * self.t + self.phase_x)
        y_mm = SWAY_A_Y_MM * loud * env * math.sin(2 * math.pi * SWAY_F_Y * self.t + self.phase_y)
        z_mm = SWAY_A_Z_MM * loud * env * math.sin(2 * math.pi * SWAY_F_Z * self.t + self.phase_z)

        return [{"pitch_rad": pitch, "yaw_rad": yaw, "roll_rad": roll,
                 "x_mm": x_mm, "y_mm": y_mm, "z_mm": z_mm}]
```

**关键参数**：

| 参数 | 值 | 描述 |
|------|-----|------|
| `SWAY_F_PITCH` | 2.2 Hz | 俯仰振动频率 |
| `SWAY_F_YAW` | 0.6 Hz | 偏航振动频率 |
| `SWAY_F_ROLL` | 1.3 Hz | 翻滚振动频率 |
| `SWAY_A_PITCH_DEG` | 4.5° | 俯仰振幅 |
| `SWAY_A_YAW_DEG` | 7.5° | 偏航振幅 |
| `VAD_DB_ON/OFF` | -35/-45 dB | 语音活动检测阈值 |

**设计理由**：
- 不同轴使用不同频率，产生自然的"不规则"运动
- 振幅与音量相关，说话越大动作越大
- VAD（语音活动检测）确保只在说话时产生运动

---

### 6. 空闲呼吸（Idle Breathing）

#### 框架：reachy-mini-conversation-app

当机器人空闲时，自动启动呼吸动画：

```python
# moves.py
class BreathingMove(Move):
    """Breathing move with interpolation to neutral and then continuous breathing patterns."""

    @property
    def duration(self) -> float:
        return float("inf")  # Continuous breathing (never ends naturally)

    def evaluate(self, t: float) -> tuple[...]:
        if t < self.interpolation_duration:
            # Phase 1: Interpolate to neutral base position
            head_pose = linear_pose_interpolation(
                self.interpolation_start_pose, self.neutral_head_pose, interpolation_t,
            )
        else:
            # Phase 2: Breathing patterns from neutral base
            breathing_time = t - self.interpolation_duration
            z_offset = self.breathing_z_amplitude * np.sin(2 * np.pi * self.breathing_frequency * breathing_time)
            head_pose = create_head_pose(x=0, y=0, z=z_offset, roll=0, pitch=0, yaw=0)

            # Antenna sway (opposite directions)
            antenna_sway = self.antenna_sway_amplitude * np.sin(2 * np.pi * self.antenna_frequency * breathing_time)
            antennas = np.array([antenna_sway, -antenna_sway])

        return (head_pose, antennas, 0.0)
```

**呼吸参数**：
- Z 轴振幅：5mm（轻微上下移动）
- 呼吸频率：0.1 Hz（每分钟 6 次呼吸）
- 天线摆动：±15°，0.5 Hz

---

## 架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         MovementManager (100 Hz Loop)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────────┐  │
│  │  Command Queue  │    │  Primary Moves  │    │   Secondary Offsets     │  │
│  │                 │    │                 │    │                         │  │
│  │  queue_move()   │───▶│ DanceQueueMove  │    │  speech_offsets (lock)  │  │
│  │  clear_queue()  │    │ EmotionQueueMove│    │  face_offsets (lock)    │  │
│  │  set_listening()│    │ GotoQueueMove   │    │                         │  │
│  └─────────────────┘    │ BreathingMove   │    └───────────┬─────────────┘  │
│                         └────────┬────────┘                │                │
│                                  │                         │                │
│                                  ▼                         ▼                │
│                         ┌────────────────────────────────────────┐         │
│                         │         Pose Composition               │         │
│                         │                                        │         │
│                         │  primary_pose + secondary_offsets      │         │
│                         │       = combined_pose                  │         │
│                         └────────────────────┬───────────────────┘         │
│                                              │                              │
│                                              ▼                              │
│                         ┌────────────────────────────────────────┐         │
│                         │    Antenna Blending (Listening Mode)   │         │
│                         └────────────────────┬───────────────────┘         │
│                                              │                              │
└──────────────────────────────────────────────┼──────────────────────────────┘
                                               │
                                               ▼
                                    ┌─────────────────────┐
                                    │   set_target()      │
                                    │   (Robot Hardware)  │
                                    └─────────────────────┘
```

---

## 比较矩阵

| 方面 | 分层运动系统 | 状态机 | 优先级抢占 |
|------|-------------|--------|-----------|
| 并发运动 | ✅ 主要+次要叠加 | ❌ 状态互斥 | ⚠️ 仅高优先级 |
| 平滑过渡 | ✅ 插值+融合 | ⚠️ 需额外处理 | ❌ 可能跳变 |
| 实时响应 | ✅ 次要层即时生效 | ❌ 需等待状态切换 | ✅ 抢占响应 |
| 实现复杂度 | ⚠️ 中等 | ✅ 简单 | ⚠️ 中等 |
| 可扩展性 | ✅ 易添加新偏移源 | ❌ 状态爆炸 | ⚠️ 优先级冲突 |

---

## 最佳实践

1. **单一控制点原则**：所有运动最终通过一个接口输出，避免多个线程直接操作机器人
2. **脏标志模式**：使用锁+脏标志减少锁竞争，控制循环只在有更新时才复制数据
3. **单调时钟**：使用 `time.monotonic()` 而非 `time.time()`，避免系统时间调整导致的跳变
4. **分层设计**：将"必须完成的动作"和"实时反应"分开处理，简化并发逻辑
5. **平滑插值**：所有姿态变化都使用插值，避免机械感的突然跳变

**反模式**：
- ❌ 在多个线程中直接调用机器人 API
- ❌ 使用固定睡眠时间而非自适应调度
- ❌ 忽略 3D 变换的正确组合顺序

---

## 代码示例

### 基础用法：排队一个舞蹈动作

```python
# From tools/dance.py
async def __call__(self, deps: ToolDependencies, **kwargs) -> Dict[str, Any]:
    move_name = kwargs.get("move", "random")
    repeat = int(kwargs.get("repeat", 1))

    movement_manager = deps.movement_manager
    for _ in range(repeat):
        dance_move = DanceQueueMove(move_name)
        movement_manager.queue_move(dance_move)  # Thread-safe

    return {"status": "queued", "move": move_name}
```

### 高级用法：语音反应偏移

```python
# From audio/head_wobbler.py
def working_loop(self) -> None:
    """Convert audio deltas into head movement offsets."""
    while not self._stop_event.is_set():
        # Get audio chunk from queue
        chunk_generation, sr, chunk = self.audio_queue.get_nowait()

        # Process audio through SwayRollRT
        results = self.sway.feed(pcm, sr)

        for r in results:
            # Convert to 6-DOF offsets (x, y, z, roll, pitch, yaw)
            offsets = (
                r["x_mm"] / 1000.0,
                r["y_mm"] / 1000.0,
                r["z_mm"] / 1000.0,
                r["roll_rad"],
                r["pitch_rad"],
                r["yaw_rad"],
            )
            # Thread-safe update to movement manager
            self._apply_offsets(offsets)
```

---

## 相关文档

- [reachy-mini-conversation-app 架构概述](https://github.com/VitaDynamics/dive-agent/blob/main/repos/agent/README.md) - 整体应用架构
- [异步流式处理](../streaming/async-streaming-first-class.md) - 音频流的异步处理模式
- [并发模式](/learns/harness/concurrency/state-snapshot-concurrency) - 线程安全的最佳实践

---

## 参考

- [reachy-mini-conversation-app 源码](https://github.com/pollen-robotics/reachy_mini_conversation_app)
- [Reachy Mini SDK](https://github.com/pollen-robotics/reachy-mini)
- [3D 变换矩阵组合](https://en.wikipedia.org/wiki/Transformation_matrix#Composing_and_inverting_transformations)

---

*创建时间：2026-03-02*
*更新时间：2026-03-02*
