# NanoClaw 架构设计分析

## 概述

NanoClaw 是一个运行在安全容器中的 AI 助手，代码量小、易于理解、完全可定制。

**项目地址**: https://github.com/qwibitai/nanoclaw

## 核心设计理念

### 1. 小到可以理解
- **单一进程**: 一个 Node.js 进程处理所有逻辑
- **少量文件**: 核心代码约 10 个 TypeScript 文件
- **无微服务**: 所有功能集成在主应用中

### 2. 通过隔离保证安全
- **容器隔离**: Agent 运行在 Linux 容器中 (Docker 或 Apple Container)
- **文件系统隔离**: 只能访问明确挂载的目录
- **安全的 Bash**: 命令在容器内执行，不影响主机

### 3. 代码即配置
- **无配置文件**: 不使用 JSON/YAML 配置文件
- **定制即代码修改**: 需要什么功能直接改代码
- **用户定制**: 每个用户 fork 后让 Claude Code 定制自己的版本

### 4. Skill 机制
- **功能通过 Skill 添加**: 不直接在代码库中添加功能
- **Skill 转换代码**: 运行 `/add-telegram` 等命令来安装频道
- **保持核心简洁**: 基础系统最小化，按需添加功能

## 系统架构

```
┌──────────────────────────────────────────────────────────────────────┐
│                        HOST (macOS / Linux)                           │
│                     (Main Node.js Process)                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌──────────────────┐                  ┌────────────────────┐        │
│  │ Channels         │─────────────────▶│   SQLite Database  │        │
│  │ (self-register   │◀────────────────│   (messages.db)    │        │
│  │  at startup)     │  store/send      └─────────┬──────────┘        │
│  └──────────────────┘                            │                   │
│                                                   │                   │
│         ┌─────────────────────────────────────────┘                   │
│         ▼                                                             │
│  ┌──────────────────┐    ┌──────────────────┐    ┌───────────────┐   │
│  │  Message Loop    │    │  Scheduler Loop  │    │  IPC Watcher  │   │
│  │  (polls SQLite) │    │  (checks tasks) │    │  (file-based) │   │
│  └────────┬─────────┘    └────────┬─────────┘    └───────────────┘   │
│           │                       │                                   │
│           └───────────┬───────────┘                                   │
│                       │ spawns container                              │
│                       ▼                                               │
├──────────────────────────────────────────────────────────────────────┤
│                     CONTAINER (Linux VM)                               │
├──────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │                    AGENT RUNNER                                 │    │
│  │                                                                 │    │
│  │  Working directory: /workspace/group (mounted from host)         │    │
│  │  Volume mounts:                                                │    │
│  │    • groups/{name}/ → /workspace/group                         │    │
│  │    • groups/global/ → /workspace/global/ (non-main only)       │    │
│  │    • data/sessions/{group}/.claude/ → /home/node/.claude/      │    │
│  │                                                                 │    │
│  │  Tools:                                                        │    │
│  │    • Bash (sandboxed in container)                             │    │
│  │    • Read, Write, Edit, Glob, Grep                            │    │
│  │    • WebSearch, WebFetch                                      │    │
│  │    • agent-browser                                            │    │
│  │    • mcp__nanoclaw__* (scheduler tools via IPC)               │    │
│  └──────────────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────────┘
```

## 核心组件

### 1. 编排器 (Orchestrator)

**文件**: `src/index.ts`

- **消息轮询循环**: 每 2 秒轮询一次 SQLite 数据库
- **状态管理**: 维护 registeredGroups、sessions、lastAgentTimestamp
- **Channel 管理**: 初始化、自注册、连接已配置的频道
- **消息处理**: 触发词检查、发送者白名单、格式化对话

```typescript
// 消息处理流程
async function processGroupMessages(chatJid: string) {
  // 1. 获取该组自上次交互后的所有消息
  const missedMessages = getMessagesSince(chatJid, lastAgentTimestamp);

  // 2. 检查触发词
  if (!isMainGroup && group.requiresTrigger) {
    const hasTrigger = missedMessages.some(m => TRIGGER_PATTERN.test(m.content));
    if (!hasTrigger) return;
  }

  // 3. 格式化对话上下文
  const prompt = formatMessages(missedMessages);

  // 4. 在容器中运行 Agent
  await runAgent(group, prompt, chatJid, async (result) => {
    // 5. 流式返回结果
    await channel.sendMessage(chatJid, result);
  });
}
```

### 2. 频道系统 (Channel System)

**文件**:
- `src/channels/registry.ts` - 频道工厂注册表
- `src/channels/index.ts` - 桶导入，触发自注册
- `src/types.ts` - Channel 接口定义

#### 自注册模式

1. 每个频道模块在加载时调用 `registerChannel()`:
```typescript
// src/channels/whatsapp.ts
import { registerChannel } from './registry.js';

registerChannel('whatsapp', (opts: ChannelOpts) => {
  if (!existsSync(authPath)) return null; // 无凭证时返回 null
  return new WhatsAppChannel(opts);
});
```

2. 桶文件导入所有频道，触发注册:
```typescript
// src/channels/index.ts
import './whatsapp.js';
import './telegram.js';
import './slack.js';
// ...
```

3. 编排器启动时连接有效的频道:
```typescript
for (const name of getRegisteredChannelNames()) {
  const channel = getChannelFactory(name)(channelOpts);
  if (channel) {
    await channel.connect();
    channels.push(channel);
  }
}
```

#### Channel 接口

```typescript
interface Channel {
  name: string;
  connect(): Promise<void>;
  sendMessage(jid: string, text: string): Promise<void>;
  isConnected(): boolean;
  ownsJid(jid: string): boolean;
  disconnect(): Promise<void>;
  setTyping?(jid: string, isTyping: boolean): Promise<void>;
  syncGroups?(force: boolean): Promise<void>;
}
```

### 3. 容器运行器 (Container Runner)

**文件**: `src/container-runner.ts`

#### 卷挂载策略

| 组类型 | 挂载内容 | 访问权限 |
|--------|----------|----------|
| Main | 项目根目录 | 只读 |
| Main | groups/{main}/ | 读写 |
| Main | data/sessions/main/.claude/ | 读写 |
| 其他组 | groups/{name}/ | 读写 |
| 其他组 | groups/global/ | 只读 |
| 其他组 | data/sessions/{name}/.claude/ | 读写 |

#### 容器启动流程

```typescript
async function runContainerAgent(group, input, onOutput) {
  // 1. 构建卷挂载
  const mounts = buildVolumeMounts(group, isMain);

  // 2. 准备环境变量
  const env = buildContainerEnv(group);

  // 3. 启动容器
  const proc = spawn('docker', [
    'run', '-i', '--rm',
    ...mountArgs,
    '--name', containerName,
    CONTAINER_IMAGE,
    'node', 'src/index.js'
  ]);

  // 4. 发送初始提示
  proc.stdin.write(JSON.stringify(input));

  // 5. 流式处理输出
  proc.stdout.on('data', (data) => {
    const output = parseOutput(data);
    onOutput(output);
  });
}
```

### 4. 组队列 (Group Queue)

**文件**: `src/group-queue.ts`

- **全局并发限制**: 默认最多 5 个并发容器
- **每组消息队列**: 按组排队，避免单个组占用所有资源
- **管道机制**: 将新消息发送到已运行的容器，实现对话连续性

```typescript
class GroupQueue {
  private globalConcurrency = 5;
  private perGroupQueues = new Map<string, Message[]>();
  private activeContainers = new Map<string, ChildProcess>();

  sendMessage(chatJid: string, message: string): boolean {
    const active = this.activeContainers.get(chatJid);
    if (active) {
      // 管道发送到已有容器
      active.stdin.write(message);
      return true;
    }
    // 加入队列等待处理
    this.enqueueMessageCheck(chatJid);
    return false;
  }
}
```

### 5. IPC 机制

**文件**: `src/ipc.ts`

基于文件系统的进程间通信:

```
data/ipc/
├── messages/          # 容器 → 主机 (任务结果、消息)
│   └── {group}/
│       └── *.json
└── tasks/            # 主机 → 容器 (任务快照)
    └── {group}/
        └── snapshot.json
```

#### MCP 服务器

Agent 通过 `nanocclaw` MCP 服务器访问调度工具:

| 工具 | 用途 |
|------|------|
| schedule_task | 创建定时/循环任务 |
| list_tasks | 列出任务 |
| pause_task | 暂停任务 |
| resume_task | 恢复任务 |
| cancel_task | 取消任务 |
| send_message | 发送消息到组 |

### 6. 任务调度器 (Task Scheduler)

**文件**: `src/task-scheduler.ts`

- **调度类型**: cron 表达式、间隔 (毫秒)、单次
- **完整 Agent 能力**: 定时任务以完整 Agent 身份运行
- **可选消息**: 可以发送消息或静默完成

```typescript
// 创建定时任务
{
  "prompt": "Send a reminder to review weekly metrics",
  "schedule_type": "cron",
  "schedule_value": "0 9 * * 1"  // 每周一 9:00
}
```

### 7. 内存系统

**层级结构**:

| 级别 | 位置 | 读取者 | 写入者 | 用途 |
|------|------|--------|--------|------|
| 全局 | groups/CLAUDE.md | 所有组 | 仅 Main | 跨对话偏好、事实 |
| 组 | groups/{name}/CLAUDE.md | 该组 | 该组 | 组特定的上下文 |
| 文件 | groups/{name}/*.md | 该组 | 该组 | 会话中创建的笔记 |

**工作原理**:
1. Agent 工作目录设置为 `groups/{group-name}/`
2. Claude Agent SDK 自动加载 `../CLAUDE.md` (全局) 和 `./CLAUDE.md` (组)
3. Agent 可以创建任意文件记录信息

### 8. 数据库 (SQLite)

**文件**: `src/db.ts`

存储内容:
- `messages` - 消息历史
- `chats` - 聊天元数据
- `registered_groups` - 注册的组
- `sessions` - 会话 ID
- `scheduled_tasks` - 定时任务
- `task_run_logs` - 任务运行日志
- `router_state` - 路由器状态

## 消息流程

```
1. 用户通过任意渠道发送消息
   │
   ▼
2. 频道接收消息 (Baileys/Telegram Bot/Slack API/...)
   │
   ▼
3. 消息存储到 SQLite
   │
   ▼
4. 消息循环轮询 SQLite (每 2 秒)
   │
   ▼
5. 路由器检查:
   ├── 聊天 JID 是否在已注册组中 → 否: 忽略
   └── 消息是否匹配触发词 → 否: 存储但不处理
   │
   ▼
6. 路由器捕获对话:
   ├── 获取自上次 Agent 交互后的所有消息
   ├── 添加时间戳和发送者名称
   └── 构建包含完整上下文的提示
   │
   ▼
7. 调用 Claude Agent SDK:
   ├── cwd: groups/{group-name}/
   ├── prompt: 对话历史 + 当前消息
   ├── resume: session_id (连续性)
   └── mcpServers: nanoclaw (调度工具)
   │
   ▼
8. Claude 处理消息:
   ├── 读取 CLAUDE.md 文件获取上下文
   └── 使用工具 (搜索、邮箱等)
   │
   ▼
9. 路由器添加助手名称前缀，通过所属渠道发送响应
   │
   ▼
10. 更新最后 Agent 时间戳，保存会话 ID
```

## 安全模型

### 容器隔离

- **文件系统隔离**: Agent 只能访问挂载的目录
- **安全的 Bash**: 命令在容器内执行，不影响主机
- **非 root 用户**: 容器以 unprivileged `node` 用户运行
- **网络隔离**: 可按需配置

### 提示注入风险缓解

- 容器隔离限制爆炸半径
- 仅处理已注册的组
- 需要触发词
- Agent 只能访问自己组的挂载目录
- Main 可以配置额外的目录挂载

## 技术栈

| 组件 | 技术 | 用途 |
|------|------|------|
| 频道系统 | Channel Registry | 启动时自注册 |
| 消息存储 | SQLite (better-sqlite3) | 轮询存储 |
| 容器运行时 | Docker / Apple Container | Agent 隔离环境 |
| Agent | @anthropic-ai/claude-agent-sdk | 运行 Claude |
| 浏览器自动化 | agent-browser + Chromium | 网页交互 |
| 运行时 | Node.js 20+ | 主机进程路由和调度 |

## 扩展性

### 添加新频道

贡献一个 Skill:
1. 创建 `src/channels/{name}.ts` 实现 Channel 接口
2. 调用 `registerChannel(name, factory)`
3. 工厂函数在凭证缺失时返回 null
4. 在 `src/channels/index.ts` 添加导入

### 添加新功能

1. 不直接修改代码库
2. 创建 Skill 文件 (`.claude/skills/add-{feature}/SKILL.md`)
3. 用户运行 `/add-{feature}` 安装
4. 保持基础系统最小化

## 参考资料

- [NanoClaw GitHub](https://github.com/qwibitai/nanoclaw)
- [官方文档](https://nanoclaw.dev)
- [Claude Code Skills](https://code.claude.com/docs/en/skills)
