# Agent

独立的 AI Agent 应用和实现。

## 定义

Agent 仓库是完整的、可运行的 Agent 应用：
- **面向终端用户**：设计为直接由最终用户使用
- **自包含**：包含 UI、CLI 或 API 接口
- **生产就绪**：可直接部署和使用
- **领域特定**：可能针对特定用例（编码、研究、自动化）

## 与 Agent-harness 的区别

| 方面 | Agent | Agent-harness |
|------|-------|---------------|
| 目的 | 终端用户应用 | 开发者框架 |
| 使用方式 | 直接使用 | 在其上构建 |
| 抽象级别 | 高（有主见） | 低（灵活） |
| 示例 | CLI 助手、聊天机器人 | SDK、库 |

## 已索引仓库

| 仓库 | 描述 | 语言 | 状态 |
|------|------|------|------|
| [om1](https://github.com/OpenMind/OM1) | 模块化机器人 AI 运行时和框架，用于人形机器人 | Python | ✅ |
| [reachy-mini-conversation-app](https://github.com/pollen-robotics/reachy_mini_conversation_app) | Reachy Mini 机器人对话应用，结合 OpenAI 实时 API、视觉管道和动作库 | Python | ✅ |
| [codex](https://github.com/openai/codex) | OpenAI 的轻量级编码 Agent，在终端中运行 | TypeScript | - |

### om1

**仓库**: https://github.com/OpenMind/OM1

**描述**: 为物理和数字智能体设计的模块化 AI 运行时和框架，特别针对人形机器人。

**技术特点**:
- **模块化运行时**: 支持物理机器人（人形）和数字 Agent 的统一脑部系统。
- **多模态感知**: 整合摄像头、LIDAR 和 Web 数据流。
- **硬件集成**: 插件化架构，支持 ROS2, Zenoh, CycloneDDS 等机器人中间件。
- **LLM/VLM 适配**: 预配置了主流大语言模型和视觉语言模型的端点。
- **分布式计算**: 利用高速通信协议处理实时动作响应。

**架构模式**:
- 基于插件的感知和动作系统。
- 统一的 Agent 状态空间管理。
- 硬件抽象层，实现代码在不同机器人间的重用。

**学习价值**:
- 机器人 Agent 的软件堆栈设计。
- 物理世界感知与 LLM 推理的结合。
- 高性能机器人通信协议的应用。

### reachy-mini-conversation-app

**仓库**: https://github.com/pollen-robotics/reachy_mini_conversation_app

**描述**: Reachy Mini 机器人的对话应用，是一个完整的 Embodied AI 应用。

**技术特点**:
- 实时音频对话循环，基于 OpenAI realtime API 和 fastrtc 低延迟流式传输
- 多模态视觉处理：支持 gpt-realtime、本地 SmolVLM2、YOLO 和 MediaPipe
- 分层运动系统：排队主要动作（舞蹈、情绪、姿势）同时混合语音反应和面部追踪
- 异步工具调度：集成机器人运动、摄像头捕获和面部追踪
- Gradio Web UI 支持实时转录

**架构模式**:
- 分层架构连接用户、AI 服务和机器人硬件
- 可配置的 Profile 系统：自定义指令和工具集
- 锁定 Profile 模式：用于创建固定人格的应用变体

**学习价值**:
- Embodied AI 应用架构设计
- 实时多模态 Agent 实现
- 机器人控制与 AI 服务集成
- 可配置的 Agent 人格系统

### codex

**仓库**: https://github.com/openai/codex

**描述**: OpenAI 官方发布的轻量级编码 Agent，直接在终端中运行，能够理解和修改代码库。

**技术特点**:
- **终端原生**: 直接在命令行界面运行，无需额外 IDE 或 GUI
- **代码理解**: 能够分析整个代码库的结构和上下文
- **多轮对话**: 支持迭代式的代码修改和优化
- **安全检查**: 在执行代码变更前进行安全确认
- **Git 集成**: 自动创建分支和提交更改

**架构模式**:
- 基于 OpenAI API 的 Agent 循环
- 工具使用模式（文件读取、编辑、执行命令）
- 上下文窗口管理和代码分块策略
- 用户确认和撤销机制

**学习价值**:
- 终端 Agent 的交互设计
- 代码库级别的上下文管理
- 安全的代码自动修改模式
- CLI 工具与 LLM 的集成方式

## 建议添加

如果你知道应该包含在此的仓库：
1. 使用 [添加仓库模板](../../issues/new?template=add-repository.yml) 创建 Issue
2. 选择 "Agent" 作为类别
3. 提供仓库详情

## 潜在候选

- AI 编码助手（CLI 或 IDE）
- 研究 Agent
- 自动化 Agent
- 聊天机器人应用
- 任务特定 Agent（数据分析、写作等）

---

*最后更新：2026-03-04*
