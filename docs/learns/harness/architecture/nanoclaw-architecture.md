---
tags: architecture, container-isolation, multi-channel-messaging, personal-assistant
---

# NanoClaw 架构设计分析

> **Related topics**: [[session-history-management]], [[context-management-dual-mode]]

## 概述

NanoClaw 是一个运行在安全容器中的 AI 助手，代码量小、易于理解、完全可定制。

**项目地址**: https://github.com/qwibitai/nanoclaw

---

## 1. 核心设计理念

### 1.1 小到可以理解
- **单一进程**: 一个 Node.js 进程处理所有逻辑
- **少量文件**: 核心代码约 10 个 TypeScript 文件
- **无微服务**: 所有功能集成在主应用中

### 1.2 通过隔离保证安全
- **容器隔离**: Agent 运行在 Linux 容器中 (Docker 或 Apple Container)
- **文件系统隔离**: 只能访问明确挂载的目录
- **安全的 Bash**: 命令在容器内执行，不影响主机

### 1.3 代码即配置
- **无配置文件**: 不使用 JSON
- **定制/YAML 配置即代码修改**: 需要什么功能直接改代码

### 1.4 Skill 机制
- **功能通过 Skill 添加**: 不直接在代码库中添加功能
- **Skill 转换代码**: 运行 `/add-telegram` 等命令来安装频道

---

## 2. 系统架构

```
+---------------------------------------------------------------------+
|                         HOST (macOS / Linux)                           |
|                      (Main Node.js Process)                            |
+---------------------------------------------------------------------+
|                                                                      |
|  +------------------+                  +------------------+            |
|  | Channels         |----------------->|  SQLite DB      |            |
|  | (self-register   |<----------------|  (messages.db)  |            |
|  |  at startup)     |  store/send      +---------+------+            |
|  +------------------+                            |                    |
|                                                 |                    |
|        +----------------------------------------+                    |
|        v                                                         |
|  +------------------+    +------------------+    +-----------+       |
|  |  Message Loop    |    |  Scheduler Loop |    | IPC Watch |       |
|  |  (polls SQLite) |    |  (checks tasks) |    |(file-based)|       |
|  +--------+---------+    +--------+---------+    +-----------+       |
|           |                       |                                  |
|           +-----------+-----------+                                  |
|                       | spawns container                             |
|                       v                                               |
+---------------------------------------------------------------------+
|                     CONTAINER (Linux VM)                              |
+---------------------------------------------------------------------+
|  +----------------------------------------------------------+       |
|  |                    AGENT RUNNER                          |       |
|  |  Working directory: /workspace/group (mounted)           |       |
|  |  Volume mounts:                                          |       |
|  |    - groups/{name}/ -> /workspace/group                  |       |
|  |    - data/sessions/{group}/.claude/ -> /home/node/     |       |
|  |                                                          |       |
|  |  Tools:                                                   |       |
|  |    - Bash (sandboxed in container)                      |       |
|  |    - Read, Write, Edit, Glob, Grep                       |       |
|  |    - WebSearch, WebFetch                                 |       |
|  |    - mcp__nanoclaw__* (scheduler tools)                 |       |
|  +----------------------------------------------------------+       |
+---------------------------------------------------------------------+
```

---

## 3. 核心组件

### 3.1 Orchestrator (编排器)

**文件**: `src/index.ts`

- **消息轮询循环**: 每 2 秒轮询一次 SQLite
- **Channel 管理**: 自注册、连接已配置的频道
- **消息处理**: 触发词检查、发送者白名单

```typescript
// 核心消息处理流程
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
  await runAgent(group, prompt, chatJid);
}
```

### 3.2 Channel System (频道系统)

**自注册模式**:
```typescript
// src/channels/whatsapp.ts
registerChannel('whatsapp', (opts) => {
  if (!existsSync(authPath)) return null;
  return new WhatsAppChannel(opts);
});
```

### 3.3 Container Runner (容器运行器)

**卷挂载策略**:

| 组类型 | 挂载内容 | 权限 |
|--------|----------|------|
| Main | 项目根目录 | 只读 |
| Main | groups/{main}/ | 读写 |
| 其他组 | groups/{name}/ | 读写 |
| 其他组 | groups/global/ | 只读 |

### 3.4 Group Queue (组队列)

- **全局并发限制**: 默认最多 5 个并发容器
- **管道机制**: 将新消息发送到已运行的容器

### 3.5 IPC 机制

基于文件系统的进程间通信:
```
data/ipc/
├── messages/  # 容器 -> 主机
└── tasks/    # 主机 -> 容器
```

### 3.6 内存系统

| 级别 | 位置 | 读取者 | 写入者 |
|------|------|--------|--------|
| 全局 | groups/CLAUDE.md | 所有组 | 仅 Main |
| 组 | groups/{name}/CLAUDE.md | 该组 | 该组 |

---

## 4. 消息流程

```
1. 用户发送消息 (WhatsApp/Telegram/...)
   |
   v
2. Channel 接收消息，存入 SQLite
   |
   v
3. 消息循环轮询 SQLite (每 2 秒)
   |
   v
4. 检查触发词 (@Andy)
   |
   v
5. 获取上次交互后的所有消息
   |
   v
6. 调用 Claude Agent SDK
   |
   v
7. 流式返回结果
```

---

## 5. 与其他方案的对比

### vs OpenClaw

| 特性 | OpenClaw | NanoClaw |
|------|----------|----------|
| 代码量 | ~50 万行 | ~10 个文件 |
| 隔离 | 应用层 | 容器层 (OS) |
| 进程 | 多进程共享 | 单一进程 |

### vs Vector DB + RAG

| 特性 | Vector DB + RAG | NanoClaw |
|------|-----------------|-----------|
| 存储 | 向量嵌入 | SQLite + 文件 |
| 上下文 | 检索获取 | 会话连续 |
| 记忆 | 被动 | 主动写入 |

---

## 6. 关键洞察

1. **简单可靠**: 轮询数据库虽然不优雅，但是简单
2. **安全优先**: 容器隔离是核心，不是白名单
3. **定制化**: 代码即配置，用户自己 fork 定制
4. **技能优于功能**: 通过 skill 添加新功能

---

## 参考资料

- [NanoClaw GitHub](https://github.com/qwibitai/nanoclaw)
- [官方文档](https://nanoclaw.dev)
- [Claude Code Skills](https://code.claude.com/docs/en/skills)
