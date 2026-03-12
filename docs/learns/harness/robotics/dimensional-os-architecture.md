---
tags: robotics, operating-system, agent-native, blueprint, physical-ai, dimos
---

# Dimensional OS (DimOS) 架构设计分析

> **Related topics**: [[layered-motion-system]], [[emotion-system-design]]

## 概述

Dimensional OS (DimOS) 是一个面向物理空间的 Agent 原生操作系统，旨在为通用机器人设置下一代 SDK 标准。它无需 ROS，完全用 Python 构建，可运行在任何人形机器人、四足机器人或无人机上。

**项目地址**: https://github.com/dimensionalOS/dimos

---

## 1. 核心设计理念

### 1.1 Agent 原生 (Agent Native)

- **vibecode**: 用自然语言"氛围编程"机器人
- **本地 & 托管多 Agent 系统**: 无缝对接硬件
- **原生模块**: Agent 作为原生模块运行，订阅任何嵌入式流

### 1.2 无需 ROS

- 纯 Python 实现
- 简单的安装，无需 ROS 依赖
- 跨平台支持 (Linux, NixOS, macOS)

### 1.3 硬件抽象

支持多种机器人类型：
- **四足机器人**: Unitree Go2, Unitree B1
- **人形机器人**: Unitree G1
- **机械臂**: Xarm, AgileX Piper
- **无人机**: MAVLink, DJI Mavic

---

## 2. 系统架构

```
+-------------------------------------------------------------------------------------+
|                              Dimensional OS                                           |
+-------------------------------------------------------------------------------------+
|                                                                                      |
|  +------------------+    +------------------+    +------------------+               |
|  |    CLI / MCP     |    |   Blueprints     |    |    Modules       |               |
|  |   (入口)         |    |   (组合)         |    |   (组件)         |               |
|  +--------+---------+    +--------+---------+    +--------+---------+               |
|           |                       |                       |                         |
|           +-----------------------+-----------------------+                         |
|                                       |                                             |
|                                       v                                             |
|  +----------------------------------------------------------------------+          |
|  |                         Core Layer                                     |          |
|  |                                                                       |          |
|  |  +------------------+  +------------------+  +------------------+  |          |
|  |  | Stream (In/Out)  |  |   Transport      |  |    Blueprint     |  |          |
|  |  |   数据流         |  |  LCM/SHM/DDS    |  |    自动连接      |  |          |
|  |  +------------------+  +------------------+  +------------------+  |          |
|  +----------------------------------------------------------------------+          |
|                                       |                                             |
|           +---------------------------+---------------------------+               |
|           |                           |                           |               |
|           v                           v                           v               |
|  +------------------+    +------------------+    +------------------+            |
|  |    Navigation    |    |   Perception     |    |     Agents       |            |
|  |  SLAM/路径规划   |    |  检测/VLM/音频   |    |  MCP/LLM/VLM    |            |
|  +------------------+    +------------------+    +------------------+            |
|           |                           |                           |               |
|           v                           v                           v               |
|  +------------------+    +------------------+    +------------------+            |
|  |     Control      |    |    Memory        |    |     Skills       |            |
|  |   运动控制       |    |  空间记忆/RAG    |    |    工具能力      |            |
|  +------------------+    +------------------+    +------------------+            |
|                                                                                      |
+-------------------------------------------------------------------------------------+
|                              Hardware Layer                                          |
+-------------------------------------------------------------------------------------+
|  +-------------+  +-------------+  +-------------+  +-------------+              |
|  | Unitree Go2 |  | Unitree G1  |  |   Xarm      |  |   Drone    |              |
|  |  (四足)     |  |  (人形)     |  |   (机械臂)   |  |   (无人机)  |              |
|  +-------------+  +-------------+  +-------------+  +-------------+              |
+-------------------------------------------------------------------------------------+
```

---

## 3. 核心组件

### 3.1 Module (模块)

Module 是机器人的子系统，使用标准化消息与其他模块通信：

```python
from dimos.core.module import Module
from dimos.core.stream import In, Out
from dimos.msgs.geometry_msgs import Twist
from dimos.msgs.sensor_msgs import Image

class RobotConnection(Module):
    cmd_vel: Out[Twist]           # 输出流
    color_image: In[Image]        # 输入流

    @rpc
    def start(self):
        # 启动逻辑
        pass
```

### 3.2 Stream (数据流)

- **In[T]**: 输入流订阅
- **Out[T]**: 输出流发布
- 支持类型安全的流通信

### 3.3 Blueprint (蓝图)

Blueprint 定义如何构建和连接模块：

```python
from dimos.core.blueprints import autoconnect

# 自动连接：按 (name, type) 连接流
blueprint = autoconnect(
    robot_connection(),
    agent(),
).build()

# 运行
blueprint.loop()
```

### 3.4 Transport (传输层)

支持多种传输协议：
- **LCM**: 轻量级通信模块
- **SHM**: 共享内存
- **DDS**: 数据分发服务
- **ROS 2**: 兼容 ROS 2

---

## 4. Agent 系统

### 4.1 Agent 类型

| 类型 | 说明 |
|------|------|
| **VLM Agent** | 视觉语言模型 Agent |
| **Ollama Agent** | 本地 LLM Agent |
| **Test Agent** | 测试 Agent |

### 4.2 MCP 集成

DimOS 支持 Model Context Protocol (MCP)，可通过自然语言控制机器人：

```bash
dimos agent-send "explore the room"  # 发送指令
dimos mcp list-tools                  # 列出可用工具
dimos mcp call relative_move --arg forward=0.5
```

### 4.3 Skills (技能)

Skills 是 Agent 可用的工具能力：
- 导航技能
- 移动技能
- 感知技能

---

## 5. 关键能力

### 5.1 导航与定位

- **SLAM**: 即时定位与地图构建
- **动态障碍物回避**
- **路径规划**: A* 算法
- **自主探索**

### 5.2 感知

- **目标检测**
- **3D 投影**
- **VLM**: 视觉语言模型
- **音频处理**

### 5.3 空间记忆

- **时空 RAG**: 结合时间和空间的检索增强
- **动态记忆**
- **物体定位与持久性**

### 5.4 操控

- **机械臂控制**
- **灵巧操作**

---

## 6. 执行模式

### 6.1 实时控制

```bash
export ROBOT_IP=<YOUR_ROBOT_IP>
dimos run unitree-go2
```

### 6.2 模拟

```bash
dimos --simulation run unitree-go2
```

### 6.3 回放

```bash
dimos --replay run unitree-go2
```

---

## 7. 技术栈

| 组件 | 技术 |
|------|------|
| 核心语言 | Python 3.12+ |
| 包管理 | uv |
| 消息格式 | LCM |
| 传输层 | LCM, SHM, DDS, ROS 2 |
| 模拟器 | MuJoCo |
| CLI | Rich, Pydantic |
| 多语言支持 | C++, Lua, TypeScript |

---

## 8. 与传统机器人框架的对比

| 特性 | ROS/ROS 2 | DimOS |
|------|------------|-------|
| 语言 | C++/Python | Python 优先 |
| 学习曲线 | 高 | 低 |
| Agent 集成 | 需额外工作 | 原生支持 |
| 依赖 | 大量系统依赖 | 轻量 |
| 硬件支持 | 通用 | 专注集成 |

---

## 9. 关键洞察

1. **Agent 是未来**: 机器人需要 AI Agent 能力来实现自然语言控制
2. **简化复杂度**: 无需 ROS，降低入门门槛
3. **Python-first**: 用 Python 胶水语言快速原型开发
4. **硬件抽象**: 统一的接口支持多种机器人
5. **可组合性**: Blueprint 机制支持模块灵活组合

---

## 参考资料

- [Dimensional OS GitHub](https://github.com/dimensionalOS/dimos)
- [官方文档](docs/)
- [Blueprints 文档](docs/usage/blueprints.md)
- [CLI 参考](docs/usage/cli.md)
