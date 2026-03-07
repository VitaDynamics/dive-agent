---
tags: context-management, memory-agent, persistent-memory, active-consolidation, google-adk
---

# Always-On Memory Agent - 持续记忆 Agent 设计

> **Related topics**: [[session-history-management]], [[context-management-dual-mode]]

## 概述

本文分析 Google 的 Always-On Memory Agent，这是一个解决 AI Agent "失忆症" 问题的持久记忆系统。

**项目地址**: https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent

---

## 1. 核心问题：Agent 的 "失忆症"

| 方案 | 局限性 |
|------|--------|
| Vector DB + RAG | 被动 - 一次性嵌入，之后检索，无主动处理 |
| 对话摘要 | 随时间丢失细节，无交叉引用 |
| 知识图谱 | 构建和维护成本高 |

**核心差距**: 没有系统像人脑一样主动整合信息。睡眠时，大脑会重播、连接和压缩信息。这个 Agent 正是做这件事。

---

## 2. 架构设计

### 三个专用 Agent

| Agent | 职责 | 触发方式 |
|-------|------|----------|
| **IngestAgent** | 从文件提取结构化信息 | 文件放入 inbox / HTTP API / Dashboard |
| **ConsolidateAgent** | 查找记忆间的连接，生成跨域洞察 | 定时器 (默认30分钟) |
| **QueryAgent** | 读取所有记忆，综合答案并带引用 | 查询请求 |

---

## 3. 核心机制

### 3.1 Ingest (摄取)

支持 27 种文件类型：
- **文本**: .txt, .md, .json, .csv, .log, .xml, .yaml, .yml
- **图片**: .png, .jpg, .jpeg, .gif, .webp, .bmp, .svg
- **音频**: .mp3, .wav, .ogg, .flac, .m4a, .aac
- **视频**: .mp4, .webm, .mov, .avi, .mkv
- **文档**: .pdf

三种摄取方式：
1. **文件监控**: 将文件放入 `./inbox` 文件夹
2. **Dashboard 上传**: Streamlit 界面上传
3. **HTTP API**: `POST /ingest`

### 3.2 Consolidate (整合)

ConsolidateAgent 每 30 分钟运行一次，像人脑睡眠时一样：
- 回顾未整合的记忆
- 查找它们之间的联系
- 生成跨域洞察
- 压缩相关信息

### 3.3 Query (查询)

QueryAgent 读取所有记忆和整合洞察，综合答案并带源引用

---

## 4. API 参考

| 端点 | 方法 | 描述 |
|------|------|------|
| `/status` | GET | 记忆统计 |
| `/memories` | GET | 列出所有存储的记忆 |
| `/ingest` | POST | 摄取新文本 |
| `/query?q=...` | GET | 用问题查询记忆 |
| `/consolidate` | POST | 手动触发整合 |

---

## 5. 关键洞察

1. **主动记忆 > 被动检索**: 持续学习、整合，而非等问问题才 RAG
2. **像人脑一样**: 睡眠时整合记忆，定期 "复习"
3. **轻量级模型足够**: 速度和成本比原始智能更重要

---

## 参考资料

- [Always-On Memory Agent GitHub](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent)
- [Google ADK](https://google.github.io/adk-docs/)
