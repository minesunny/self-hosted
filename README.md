# Self-Hosted CI Demo

本仓库用于测试 GitHub Actions 的 Self-Hosted Runner CI 流水线。

## CI 工作流

仓库内包含以下三个基于 Self-Hosted Linux Runner 的 CI 演示工作流（均存放于 `.github/workflows/` 目录下，文件必须带 `.yml` 或 `.yaml` 后缀）：

1. **Node.js CI** (`.github/workflows/nodejs-ci.yml`)
   - 依赖标签: `[self-hosted, linux]`
   - 测试模式:
     - **Benchmark 模式 (Fastify)**: 克隆 Fastify 仓库，执行 `npm install`、TypeScript 类型推导 (`test:types`) 以及全量单元测试 (`unit`)，压测异步 I/O 与 CPU 性能。
     - **Demo 模式**: 快速验证基础 Node.js 运行环境。
2. **Docker Build CI** (`.github/workflows/docker-build-ci.yml`)
   - 依赖标签: `[self-hosted, linux]`
   - 测试内容: 检查 Docker Daemon 状态，构建镜像并进行冒烟测试（需 ARC 开启 DinD 或挂载 socket）。
3. **Gradle Java CI** (`.github/workflows/gradle-java-ci.yml`)
   - 依赖标签: `[self-hosted, linux]`
   - 测试模式:
     - **Benchmark 模式 (Spring PetClinic)**: 克隆 Spring 官方企业级示范项目，执行 Gradle 全量编译、注解处理、Spring 上下文集成测试以及 Spring Boot Fat JAR 打包。
     - **Demo 模式**: 快速验证 JDK 与 Gradle 编译链路。

## 触发机制

工作流支持以下触发方式：
- **PR 触发**: 提交向 `main` 分支的 Pull Request 时自动触发。
- **Push 触发**: 直接推送至 `main` 分支时自动触发。
- **手动触发 (`workflow_dispatch`)**:
  - **Web 界面**: 在仓库 Actions 标签页中选择工作流，点击右侧 **"Run workflow"** 按钮，可输入自定义参数（如 JDK / Node.js 版本、Docker Tag、是否 Clean 构建等）运行。
  - **GitHub CLI 命令行**:
    ```bash
    # 手动触发 Node.js CI (可选参数 -f node_version=20)
    gh workflow run nodejs-ci.yml --ref main -f node_version=22

    # 手动触发 Docker Build CI (可选参数 -f image_tag=v1.0.0 -f skip_test=false)
    gh workflow run docker-build-ci.yml --ref main -f image_tag=latest

    # 手动触发 Gradle Java CI (可选参数 -f java_version=21 -f clean_build=true)
    gh workflow run gradle-java-ci.yml --ref main -f java_version=21
    ```
- **外部事件触发 (`repository_dispatch`)**:
  - 支持通过 GitHub API 发送外部事件进行手动触发（如 `manual-node-build`、`manual-docker-build`、`manual-gradle-build`）。

## 如何接入 Self-Hosted Runner (Linux)

当前工作流配置的运行环境为 `runs-on: [self-hosted, linux]`。若要执行 CI 任务，需在目标 Linux 服务器或容器上注册并启动 GitHub Actions Runner：

1. 前往 GitHub 仓库页面：**Settings -> Actions -> Runners -> New runner**（选择 Linux 架构）。
2. 在目标 Linux 机器上执行：
   ```bash
   # 创建目录
   mkdir -p actions-runner && cd actions-runner

   # 下载并解压 Runner 安装包（版本号根据 GitHub 页面提示）
   curl -o actions-runner-linux-x64-2.321.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz
   tar xzf ./actions-runner-linux-x64-2.321.0.tar.gz

   # 配置 Runner 并关联仓库
   ./config.sh --url https://github.com/minesunny/self-hosted --token <REGISTRATION_TOKEN>

   # 启动 Runner
   ./run.sh
   ```
   *注：也可以使用 `sudo ./svc.sh install` 和 `sudo ./svc.sh start` 作为系统服务持久运行。*
3. Runner 启动并上线后，处于 Queued 状态的流水线任务将自动被拾取并执行。
