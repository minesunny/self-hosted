# Self-Hosted CI Demo

本仓库用于测试 GitHub Actions 的 Self-Hosted Runner CI 流水线。

## CI 工作流

仓库内包含以下三个基于 Self-Hosted Linux Runner 的 CI 演示工作流（均存放于 `.github/workflows/` 目录下，文件必须带 `.yml` 或 `.yaml` 后缀）：

1. **Node.js CI** (`.github/workflows/nodejs-ci.yml`)
   - 依赖标签: `[self-hosted, linux]`
   - 测试内容: 创建 Node.js 示例项目、安装依赖并运行测试，上传构建产物。
2. **Docker Build CI** (`.github/workflows/docker-build-ci.yml`)
   - 依赖标签: `[self-hosted, linux]`
   - 测试内容: 构建 Python Demo 镜像、容器冒烟测试并导出 tar 产物。
3. **Gradle Java CI** (`.github/workflows/gradle-java-ci.yml`)
   - 依赖标签: `[self-hosted, linux]`
   - 测试内容: 配置 JDK 21、安装 Gradle、构建 Java 项目并运行测试与产物验证。

## 触发机制

工作流支持以下触发方式：
- **PR 触发**: 提交向 `main` 分支的 Pull Request 时自动触发。
- **Push 触发**: 直接推送至 `main` 分支时自动触发。
- **手动触发**: 支持在 GitHub 仓库 `Actions` 界面或通过 GitHub CLI (`gh workflow run <workflow-name>`) 手动触发 `workflow_dispatch`。

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
