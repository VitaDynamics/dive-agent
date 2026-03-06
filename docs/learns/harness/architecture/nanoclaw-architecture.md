---
tags: architecture, nanoclaw, container-isolation, multi-channel, skill-system
---

# NanoClaw 架构深度分析

> **Related topics**: [[container-sandbox]], [[message-queue]], [[channel-registration]], [[skill-pattern]], [[agent-swarm]]

## 概述

NanoClaw 是一个轻量级的个人 AI 助手，运行在安全的容器中。它连接到 WhatsApp、Telegram、Slack、Discord、Gmail 等消息应用，具有记忆功能、定时任务，并直接运行在 Anthropic 的 Claude Agent SDK 上。

其核心设计哲学是 **"足够小以理解"** — 一个进程，少量源文件，无微服务，通过 Linux 容器实现真正的安全隔离。

---

## 1. 整体架构设计

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
│  │  (polls SQLite)  │    │  (checks tasks)  │    │  (file-based) │   │
│  └────────┬─────────┘    └────────┬─────────┘    └───────────────┘   │
│           │                       │                                   │
│           └───────────┬───────────┘                                   │
│                       │ spawns container                              │
│                       ▼                                               │
├──────────────────────────────────────────────────────────────────────┤
│                     CONTAINER (Linux VM)                               │
├──────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │                    AGENT RUNNER                               │    │
│  │                                                                │    │
│  │  Working directory: /workspace/group (mounted from host)      │    │
│  │  Volume mounts:                                                │    │
│  │    • groups/{name}/ → /workspace/group                         │    │
│  │    • groups/global/ → /workspace/global/ (non-main only)       │    │
│  │    • data/sessions/{group}/.claude/ → /home/node/.claude/     │    │
│  │                                                                │    │
│  │  Tools (all groups):                                           │    │
│  │    • Bash (safe - sandboxed in container!)                     │    │
│  │    • Read, Write, Edit, Glob, Grep (file operations)          │    │
│  │    • WebSearch, WebFetch (internet access)                    │    │
│  │    • agent-browser (browser automation)                       │    │
│  │    • mcp__nanoclaw__* (scheduler tools via IPC)              │    │
│  │                                                                │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

### 核心消息流

```
1. 用户通过任意渠道发送消息
   │
   ▼
2. Channel 接收消息 (Baileys for WhatsApp, Bot API for Telegram)
   │
   ▼
3. 消息存储到 SQLite (store/messages.db)
   │
   ▼
4. Message Loop 轮询 SQLite (每 2 秒)
   │
   ▼
5. Router 检查:
   ├── 聊天 JID 是否在已注册群组中? → 否: 忽略
   └── 消息是否匹配触发词? → 否: 存储但不处理
   │
   ▼
6. Router 追赶对话历史:
   ├── 获取上次 Agent 交互后的所有消息
   ├── 格式化时间戳和发送者名称
   └── 构建包含完整上下文的 prompt
   │
   ▼
7. Router 调用 Claude Agent SDK:
   ├── cwd: groups/{group-name}/
   ├── prompt: 对话历史 + 当前消息
   ├── resume: session_id (用于连续性)
   └── mcpServers: nanoclaw (调度器)
   │
   ▼
8. Claude 处理消息:
   ├── 读取 CLAUDE.md 文件获取上下文
   └── 使用工具 (搜索、邮件等)
   │
   ▼
9. Router 添加助手名称前缀并通过所属渠道发送响应
   │
   ▼
10. Router 更新上次 Agent 时间戳并保存 session ID
```

---

## 2. 核心模块解析

### 2.1 Orchestrator (`src/index.ts`)

Orchestrator 是 NanoClaw 的大脑，负责：
- 状态管理 (sessions, registeredGroups, lastAgentTimestamp)
- 消息循环 (polling SQLite, 消息路由)
- Agent 调用 (容器启动, 流式输出处理)
- 定时任务调度
- IPC 监视

```typescript
// 核心循环
async function startMessageLoop(): Promise<void> {
  while (true) {
    const { messages, newTimestamp } = getNewMessages(jids, lastTimestamp);
    // 按群组去重
    const messagesByGroup = new Map<string, NewMessage[]>();
    // 触发词检查
    if (needsTrigger && !hasTrigger) continue;
    // 消息队列或直接处理
    if (queue.sendMessage(chatJid, formatted)) {
      // 管道消息到活跃容器
    } else {
      // 入队等待新容器处理
      queue.enqueueMessageCheck(chatJid);
    }
  }
}
```

### 2.2 Channel Registry (`src/channels/registry.ts`)

渠道系统采用**自注册模式**，核心代码：

```typescript
export type ChannelFactory = (opts: ChannelOpts) => Channel | null;
const registry = new Map<string, ChannelFactory>();

export function registerChannel(name: string, factory: ChannelFactory): void {
  registry.set(name, factory);
}

// 渠道安装时添加
registerChannel('whatsapp', (opts: ChannelOpts) => {
  if (!existsSync(authPath)) return null; // 凭据缺失时返回 null
  return new WhatsAppChannel(opts);
});
```

**自注册流程**：
1. 每个渠道 skill 添加 `src/channels/{name}.ts`，模块加载时调用 `registerChannel()`
2. `src/channels/index.ts` 使用 barrel import 触发所有渠道注册
3. 启动时 orchestrator 遍历已注册渠道，实例化有凭据的渠道

### 2.3 Container Runner (`src/container-runner.ts`)

容器运行器是 NanoClaw 安全隔离的核心：

```typescript
function buildVolumeMounts(group: RegisteredGroup, isMain: boolean): VolumeMount[] {
  const mounts: VolumeMount[] = [];

  if (isMain) {
    // 主群组：项目根目录只读挂载（防止修改源代码绕过沙箱）
    mounts.push({
      hostPath: projectRoot,
      containerPath: '/workspace/project',
      readonly: true,
    });
    // 阴影 .env 防止读取 secrets
    mounts.push({
      hostPath: '/dev/null',
      containerPath: '/workspace/project/.env',
      readonly: true,
    });
  }

  // 群组工作目录（可写）
  mounts.push({
    hostPath: groupDir,
    containerPath: '/workspace/group',
    readonly: false,
  });

  // 全局内存目录（只读，非主群组）
  const globalDir = path.join(GROUPS_DIR, 'global');
  if (fs.existsSync(globalDir)) {
    mounts.push({
      hostPath: globalDir,
      containerPath: '/workspace/global',
      readonly: true,
    });
  }

  // Per-group Claude sessions 目录（隔离）
  const groupSessionsDir = path.join(DATA_DIR, 'sessions', group.folder, '.claude');
}
```

### 2.4 Group Queue (`src/group-queue.ts`)

群组消息队列实现全局并发控制：

```typescript
export class GroupQueue {
  private enqueued: Set<string> = new Set();
  private active: Map<string, ChildProcess> = new Map();
  private maxConcurrent = MAX_CONCURRENT_CONTAINERS;

  // 入队消息检查
  enqueueMessageCheck(chatJid: string): void {
    if (this.active.size < this.maxConcurrent) {
      // 有空闲槽，立即处理
      this.processGroup(chatJid);
    } else {
      // 加入待处理队列
      this.enqueued.add(chatJid);
    }
  }

  // 消息管道化（已有活跃容器时）
  sendMessage(chatJid: string, formatted: string): boolean {
    const proc = this.active.get(chatJid);
    if (proc) {
      proc.stdin.write(formatted + '\n');
      return true;
    }
    return false;
  }
}
```

---

## 3. 内存系统设计

NanoClaw 使用基于 CLAUDE.md 文件的**分层内存系统**：

| 层级 | 位置 | 读取者 | 写入者 | 用途 |
|------|------|--------|--------|------|
| **全局** | `groups/CLAUDE.md` | 所有群组 | 仅主群组 | 跨对话的偏好、事实、上下文 |
| **群组** | `groups/{name}/CLAUDE.md` | 该群组 | 该群组 | 群组特定的上下文、对话记忆 |
| **文件** | `groups/{name}/*.md` | 该群组 | 该群组 | 对话期间创建的笔记、研究 |

### 内存加载机制

Claude Agent SDK 的 `settingSources: ['project']` 自动加载：
- `../CLAUDE.md` (父目录 = 全局内存)
- `./CLAUDE.md` (当前目录 = 群组内存)

---

## 4. 技能系统 (Skills over Features)

NanoClaw 的核心哲学是 **"不添加功能，添加技能"**。

### 技能模式

当你想要添加 Telegram 支持时：
- **不要**：提交一个 PR 把 Telegram 和 WhatsApp 一起加到代码库
- **要**：提交一个 skill 文件 (`.claude/skills/add-telegram/SKILL.md`)，教会 Claude Code 如何转换 NanoClaw 安装来使用 Telegram

### 技能触发

用户运行 `/add-telegram`，Claude Code 动态修改代码，得到干净的、只做他们需要的事情的代码，而不是一个试图支持所有用例的膨胀系统。

### 内置技能

- `/setup` - 初始设置
- `/customize` - 添加能力
- `/add-whatsapp` - WhatsApp 渠道
- `/add-telegram` - Telegram 渠道
- `/add-slack` - Slack 渠道
- `/add-gmail` - Gmail 集成
- `/convert-to-apple-container` - 切换到 Apple Container
- `/schedule` - 定时任务

---

## 5. 定时任务系统

NanoClaw 内置调度器，以完整 Agent 身份运行定时任务：

### 调度类型

| 类型 | 值格式 | 示例 |
|------|--------|------|
| `cron` | Cron 表达式 | `0 9 * * 1` (每周一 9am) |
| `interval` | 毫秒 | `3600000` (每小时) |
| `once` | ISO 时间戳 | `2024-12-25T09:00:00Z` |

### 创建任务

```
用户: @Andy remind me every Monday at 9am to review the weekly metrics

Claude: [调用 mcp__nanoclaw__schedule_task]
        {
          "prompt": "Send a reminder to review weekly metrics. Be encouraging!",
          "schedule_type": "cron",
          "schedule_value": "0 9 * * 1"
        }
```

### MCP 工具

内置的 `nanoclaw` MCP 服务器提供：
- `schedule_task` - 创建定时/循环任务
- `list_tasks` - 显示任务
- `get_task` - 获取任务详情
- `update_task` - 修改任务
- `pause_task` / `resume_task` / `cancel_task` - 任务控制
- `send_message` - 发送消息到群组

---

## 6. 安全模型

### 容器隔离

所有 Agent 运行在容器中（轻量级 Linux VM），提供：
- **文件系统隔离**：Agent 只能访问明确挂载的目录
- **安全的 Bash 访问**：命令在容器内运行，不在你的 Mac 上
- **网络隔离**：可按容器配置
- **进程隔离**：容器进程无法影响主机
- **非 root 用户**：容器以非特权 `node` 用户运行 (uid 1000)

### 挂载安全

```typescript
// 验证额外挂载目录
function validateAdditionalMounts(mounts: AdditionalMount[]): void {
  const allowedPaths = [
    process.cwd(),
    STORE_DIR,
    GROUPS_DIR,
    DATA_DIR,
  ];

  for (const mount of mounts) {
    const resolved = path.resolve(mount.hostPath);
    const isAllowed = allowedPaths.some(allowed => resolved.startsWith(allowed));
    if (!isAllowed) {
      throw new Error(`Mount path not allowed: ${resolved}`);
    }
  }
}
```

### 提示注入风险

**缓解措施**：
- 容器隔离限制爆炸半径
- 只处理已注册群组
- 需要触发词（减少意外处理）
- Agent 只能访问其群组的挂载目录
- Claude 内置安全训练

---

## 7. 关键设计决策

### 为什么一个进程？

- 简单性：一个代码库，少量文件
- 可理解性：用户可以理解整个系统
- 调试友好：无需追踪跨服务请求

### 为什么容器隔离？

- 真正的 OS 级隔离，不是应用程序级权限检查
- Bash 访问是安全的，因为命令在容器内运行
- 泄露的 Agent 只能访问它被给予的

### 为什么无配置文件？

- 避免配置蔓延
- 每个用户应该定制代码来做他们确切想要的
- 而不是配置一个通用系统

### 为什么技能优先于功能？

- 保持基础系统最小化
- 让每个用户自定义安装而不继承不需要的功能
- 用户得到干净的、精确的代码

---

## 8. 核心文件清单

| 文件 | 目的 |
|------|------|
| `src/index.ts` | Orchestrator：状态、消息循环、Agent 调用 |
| `src/channels/registry.ts` | 渠道工厂注册表 |
| `src/channels/index.ts` | Barrel imports 触发渠道自注册 |
| `src/ipc.ts` | IPC 监视器和任务处理 |
| `src/router.ts` | 消息格式化和出站路由 |
| `src/group-queue.ts` | 群组队列，全局并发限制 |
| `src/container-runner.ts` | 生成流式 Agent 容器 |
| `src/task-scheduler.ts` | 运行定时任务 |
| `src/db.ts` | SQLite 操作 |
| `groups/*/CLAUDE.md` | 群组级记忆 |

---

## 9. 与其他框架的对比

| 特性 | NanoClaw | OpenClaw | Kimi-CLI |
|------|----------|----------|----------|
| 代码规模 | ~2000 行 | ~500,000 行 | ~数万行 |
| 进程模型 | 单进程 | 单进程 | 多层架构 |
| 隔离方式 | Linux 容器 | 应用级权限 | 进程隔离 |
| 配置方式 | 代码修改 | 53 个配置文件 | YAML 配置 |
| 扩展方式 | Skills | PR | Agent Spec |
| 消息渠道 | 可插拔 | 内置 | 内置 |

---

## 10. 总结

NanoClaw 代表了一种独特的 AI Agent 架构理念：

1. **极简主义** — 代码量足够小，一个人可以完全理解
2. **安全优先** — 真正的容器隔离，不是应用程序级防护
3. **用户定制** — 定制 = 代码修改，不是配置
4. **技能驱动** — 通过 Claude Code 技能动态扩展
5. **AI 原生** — 无安装向导，Claude 指导一切

这种设计非常适合个人用户，他们想要一个完全在自己控制之下、可以根据自己精确需求定制的 AI 助手。
