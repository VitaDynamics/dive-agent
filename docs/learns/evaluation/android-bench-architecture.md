# Android Bench 架构设计分析

## 概述

Android Bench 是一个用于在 Android 开发任务上对大语言模型 (LLM) 进行基准测试的框架。它评估 AI 模型理解移动代码库、生成准确补丁和解决 Android 特有工程问题的能力。

**项目地址**: https://github.com/android-bench/android-bench

## 核心设计理念

### 1. 任务驱动的基准测试
- **真实问题**: 基于真实的 GitHub Issue 构建测试任务
- **可重现环境**: 每次测试使用固定的代码库版本和 Docker 执行环境
- **可靠的测试套件**: 测试必须在基础提交上失败，在应用修复补丁后通过

### 2. 两阶段评估流程
- **推理阶段 (Inference)**: Agent 读取问题描述，生成代码补丁
- **评估阶段 (Verifier)**: 应用补丁并运行测试来评分解决方案

### 3. 隔离的执行环境
- **Docker 沙箱**: 所有评估在隔离的 Docker 容器中运行
- **镜像缓存**: 基于数据集配置构建任务特定的 Docker 镜像
- **可重现性**: 固定的依赖版本和环境配置

### 4. 模块化架构
- **CLI 层**: 命令行工具
- **通用层**: 配置、加载器、日志等基础设施
- ** Harness 层**: 推理和评估引擎
- **数据集层**: 任务定义和测试数据

## 系统架构

```
+---------------------------------------------------------------------+
|                         CLI Layer (cli/)                             |
+---------------------------------------------------------------------+
|  benchmark    run_task    agent    verifier    dataset    results   |
+---------------------------------------------------------------------+
                              |
                              v
+---------------------------------------------------------------------+
|                     Common Layer (common/)                           |
+---------------------------------------------------------------------+
|  config.py    loader.py    logger.py    run_config.py    ui.py     |
|  storage/    models/                                                    |
+---------------------------------------------------------------------+
                              |
              +---------------+---------------+
              v                               v
+-------------------------+     +-------------------------+
|  Inference (harness/)   |     |  Evaluation (harness/)|
+-------------------------+     +-------------------------+
|  androidbench.py       |     |  harness.py            |
|  androidbench_runner.py|     |  benchmark_worker.py   |
|  androidbench.yaml     |     |  main.py               |
+-------------------------+     +-------------------------+
              |                               |
              v                               v
+-------------------------+     +-------------------------+
|  MiniSWE-Agent          |     |  Docker Container       |
|  (LLM Interface)        |     |  - Android SDK          |
|  LiteLLM                |     |  - Gradle               |
|                         |     |  - Test Suite          |
+-------------------------+     +-------------------------+
```

## 核心组件

### 1. CLI 层

**目录**: `cli/`

| 命令 | 功能 |
|------|------|
| `benchmark` | 端到端运行整个流水线 (推理 + 评估) |
| `run_task` | 运行单个任务的完整流水线 |
| `agent` | 仅运行推理阶段 |
| `verifier` | 仅运行评估阶段 |
| `dataset` | 浏览和检查数据集任务 |
| `results` | 可视化结果 |

### 2. Common 层

**目录**: `common/`

#### 配置管理 (`config.py`, `run_config.py`)
```python
# BaseConfig 定义全局配置
class BaseConfig:
    model: str                           # 使用的模型
    dataset_dir: Path                    # 数据集目录
    output_dir: Path                     # 输出目录
    docker_image: str                    # Docker 镜像名称
    max_workers: int                     # 并行工作数
    skip_existing: bool                  # 跳过已存在的任务
```

#### 任务加载 (`loader.py`)
```python
def load_all_tasks(dataset_dir: Path) -> List[Task]:
    """加载所有任务定义"""

def load_task(task_id: str) -> Task:
    """加载单个任务"""

def get_tasks_by_category(category: str) -> List[Task]:
    """按类别筛选任务"""
```

#### 存储层 (`storage/`)
- 管理任务结果和运行历史的持久化

### 3. Harness 层 - 推理 (Inference)

**目录**: `harness/inference/`

#### 核心文件
- `androidbench.py` - 主推理引擎，并行执行多个任务
- `androidbench_runner.py` - 单任务运行器
- `androidbench.yaml` - Agent 配置

#### 推理流程
```python
async def run_inference(task: Task, model: str) -> Patch:
    # 1. 加载任务定义
    issue_description = task.description

    # 2. 准备提示词
    prompt = build_prompt(task)

    # 3. 调用 LLM
    response = await llm.complete(prompt)

    # 4. 解析补丁
    patch = parse_patch(response)

    # 5. 保存补丁
    save_patch(task.id, patch)

    return patch
```

#### LLM 集成
- 基于 **mini-swe-agent** 构建
- 使用 **LiteLLM** 支持多种模型 (OpenAI, Gemini, Anthropic 等)
- 模型名称格式: `provider/model-name` (如 `gemini/gemini-2.5-flash`)

### 4. Harness 层 - 评估 (Evaluation)

**目录**: `harness/evaluation/`

#### 核心文件
- `harness.py` - 评估核心逻辑
- `benchmark_worker.py` - 单任务评估工作器
- `main.py` - 评估命令行入口

#### 评估流程
```python
async def evaluate(patch: Patch, task: Task) -> Score:
    # 1. 构建 Docker 镜像
    image = build_task_image(task)

    # 2. 在容器中运行
    container = await run_container(image, task)

    # 3. 应用补丁
    await container.apply_patch(patch)

    # 4. 运行测试
    test_results = await container.run_tests(task.commands)

    # 5. 评分
    score = calculate_score(test_results, task.acceptance_criteria)

    return score
```

#### 验收标准
```yaml
acceptance_criteria:
  fail_to_pass:           # 基础提交上失败，应用补丁后通过
    - testAnalyticsDebugUnitTest#Test intentsAreParsedCorrectly
  pass_to_pass:           # 基础提交和应用补丁后都应通过
    - testAnalyticsDebugUnitTest#Test should_start_trusted_app
```

### 5. 数据集层

**目录**: `dataset/tasks/{task_id}/`

#### 任务结构
```
task_id/
├── task.yaml          # 任务定义
├── golden.patch      # 黄金修复 (Oracle 解决方案)
├── test.patch        # 测试文件补丁
└── Dockerfile        # 任务特定的 Docker 配置
```

#### task.yaml 规范
```yaml
instance_id: "AlphaWallet__alpha-wallet-android-pr_3329"
repository:
  name: alpha-wallet-android
  owner: AlphaWallet
  url: https://github.com/AlphaWallet/alpha-wallet-android
before_commit:
  sha: eea8b6402b6fa53fa0ed93cf87d2d58e30958fa6
after_commit:
  sha: 5c8712695f4195e6b28dd643e5fd114b96ffaef0
commands:
  build: ["./gradlew assembleDebug"]
  unit_test: ["./gradlew ... testDebugUnitTest"]
  android_test: ["./gradlew ... connectedDebugAndroidTest"]
test_files:
  - app/src/test/java/com/alphawallet/app/IntentTest.java
acceptance_criteria:
  fail_to_pass:
    - testAnalyticsDebugUnitTest#Test intentsAreParsedCorrectly
  pass_to_pass:
    - testAnalyticsDebugUnitTest#Test should_start_trusted_app
```

## 执行流程

### 完整流水线
```
1. 用户执行: run_task --model gemini/gemini-2.5-flash --task <TASK_ID>
   |
   v
2. CLI 解析参数，加载配置
   |
   v
3. 推理阶段 (Inference):
   +-- 加载任务定义
   +-- 克隆代码库 (指定版本)
   +-- 构建提示词 (问题描述 + 上下文)
   +-- 调用 LLM 生成补丁
   +-- 保存补丁到输出目录
   |
   v
4. 评估阶段 (Evaluation):
   +-- 构建/加载 Docker 镜像
   +-- 在容器中克隆代码库
   +-- 应用生成的补丁
   +-- 运行测试命令
   +-- 收集测试结果
   +-- 根据验收标准评分
   |
   v
5. 输出结果:
   +-- scores.json - 评分详情
   +-- logs/ - 执行日志
   +-- patches/ - 生成的补丁
```

### Docker 镜像策略

| 镜像类型 | 说明 | 构建时机 |
|----------|------|----------|
| Base Image | Android SDK + Gradle | 首次 setup |
| Repo Image | 基础代码库 | 按需构建 |
| Task Image | 任务特定环境 | 首次运行任务 |

```bash
# 镜像构建命令
uv run build_images --build --arch linux/amd64
```

## 技术栈

| 组件 | 技术 | 用途 |
|------|------|------|
| 包管理 | uv | Python 依赖管理 |
| Agent 框架 | mini-swe-agent | LLM Agent 执行 |
| 模型抽象 | LiteLLM | 多模型支持 |
| 容器化 | Docker | 隔离执行环境 |
| 测试框架 | pytest | 单元测试 |
| 构建工具 | Gradle | Android 项目构建 |
| 并行执行 | concurrent.futures | 多任务并行 |

## 评分系统

### 评分维度
1. **pass_to_pass**: 基础提交和应用补丁后都应通过的测试
2. **fail_to_pass**: 基础提交上失败，应用补丁后通过的测试

### 评分逻辑
```python
def calculate_score(test_results, acceptance_criteria):
    fail_to_pass_tests = acceptance_criteria.fail_to_pass
    pass_to_pass_tests = acceptance_criteria.pass_to_pass

    # 必须全部通过
    all_fail_to_pass_passed = all(
        t in test_results.passed for t in fail_to_pass_tests
    )
    all_pass_to_pass_passed = all(
        t in test_results.passed for t in pass_to_pass_tests
    )

    if all_fail_to_pass_passed and all_pass_to_pass_passed:
        return Score.PASS
    else:
        return Score.FAIL
```

### 状态码
- `applied_patch_failed_tests`: 补丁应用成功但测试失败
- `build_failed`: 构建失败
- `test_timeout`: 测试超时
- `patch_not_found`: 未找到补丁

## 扩展性

### 添加新任务
1. 在 `dataset/tasks/` 创建任务目录
2. 编写 `task.yaml` 定义问题和验收标准
3. 准备 `golden.patch` (Oracle 解决方案)
4. 编写 `Dockerfile` 定义执行环境
5. 运行 `dataset` 命令验证任务

### 支持新模型
1. 确保模型被 LiteLLM 支持
2. 导出对应的 API Key
3. 使用 `provider/model-name` 格式调用

## 使用示例

```bash
# 浏览数据集
dataset

# 运行单个任务
run_task --model gemini/gemini-2.5-flash --task android_snippets_1

# 运行基准测试
benchmark --model gemini/gemini-2.5-flash --num_runs 5

# 仅运行推理
agent -i <task_id> --model openai/gpt-4o

# 仅运行评估
verifier --run-name <run_name>

# 可视化结果
results --input-dir out
```

## 限制与注意事项

1. **资源密集**: 基础镜像、代码库镜像和任务镜像可能需要 40GB+ 磁盘空间
2. **首次启动慢**: 首次运行任务需要 5-10+ 分钟构建 Docker 镜像
3. **ARM64 限制**: macOS ARM64 无法运行嵌套虚拟化，Android SDK 仅支持 x86_64
4. **API 密钥**: 需要配置相应模型的 API Key

## 参考资料

- [Android Bench GitHub](https://github.com/android-bench/android-bench)
- [User Guide](https://github.com/android-bench/android-bench/blob/main/docs/guide.md)
- [Dataset Documentation](https://github.com/android-bench/android-bench/blob/main/docs/dataset.md)
- [MiniSWE-Agent](https://www.mini-swe-agent.com)
- [LiteLLM](https://github.com/BerriAI/litellm)
