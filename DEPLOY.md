# GitHub Actions Runner Controller (ARC) 在 k3s 上部署指南

> 环境：k3s 单机集群，网络只能通过 HTTP 代理 `http://172.16.1.1:7890` 出网
> 版本：ARC controller `0.14.2`，scale-set chart `gha-rs-0.14.2`

---

## 1. 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│ k3s 集群                                                      │
│                                                             │
│  namespace: arc-systems                                      │
│   └─ gha-runner-scale-set-controller (Deployment)            │
│        └─ 管理 AutoscalingListener (pod)                     │
│                                                             │
│  namespace: arc-runners                                      │
│   ├─ AutoscalingRunnerSet  (arc-runner-set)                  │
│   ├─ EphemeralRunnerSet   (arc-runner-set-xxxxx)             │
│   └─ runner pods (init: dind-externals + dind, main: runner) │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ HTTPS (走代理)
                          ▼
              GitHub App (app_id + 私钥 + installation_id)
                          │
                          ▼
                 GitHub Actions (repo: minesunny/dialect)
```

组件职责：

- **gha-runner-scale-set-controller**：监听 `AutoscalingRunnerSet` 资源，创建监听器和 ephemeral runner。
- **AutoscalingListener**：向 GitHub 注册 scale set，按负载决定 runner 副本数（min/max）。
- **runner pod**：真正执行 CI job 的容器。本方案用了 `docker-in-docker`（dind）以便 job 里能用 docker。

---

## 2. 前置条件

1. k3s 集群（`kubectl` 可用）
2. helm 3
3. 一个 **GitHub App**（在 GitHub → Settings → Developer settings → GitHub Apps 创建），并安装到目标仓库，记录：
   - **App ID**（例如 `5116138`）
   - **Installation ID**（安装后 URL 末尾数字，例如 `165990848`）
   - **私钥 .pem**（点 "Generate a private key" 下载）
4. 出网方式（直连或 HTTP 代理）

---

## 3. 部署步骤

### 3.1 创建命名空间

```bash
kubectl create namespace arc-systems
kubectl create namespace arc-runners
```

### 3.2 安装 ARC Controller

```bash
helm install arc \
  --namespace arc-systems \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.14.2
```

验证：

```bash
kubectl get pods -n arc-systems
# 期望: gha-runner-scale-set-controller-xxx  1/1  Running
```

### 3.3 创建 GitHub App Secret

私钥文件（如 `arc.pem`）与 App ID / Installation ID 一起写入 secret：

```bash
kubectl create secret generic arc-github-app-secret \
  --namespace arc-runners \
  --from-literal=github_app_id=5116138 \
  --from-literal=github_app_installation_id=165990848 \
  --from-file=github_app_private_key=./arc.pem
```

> secret 必须包含这三个 key：`github_app_id`、`github_app_installation_id`、`github_app_private_key`。

### 3.4 创建共享缓存 PVC（可选）

用于跨 job 复用 npm / gradle / cargo / maven / pip / go 缓存。

```yaml
# cache-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gha-shared-cache
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: gha-shared-cache
  hostPath:
    path: /var/lib/github-actions-cache
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gha-shared-cache
  namespace: arc-runners
spec:
  storageClassName: gha-shared-cache
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 20Gi
```

```bash
kubectl apply -f cache-pv.yaml
```

### 3.5 部署 Runner Scale Set

创建 `values.yaml`（见下一节），然后：

```bash
helm install arc-runner-set \
  --namespace arc-runners \
  -f values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.2
```

### 3.6 验证上线

```bash
# 监听器运行中
kubectl get pods -n arc-systems

# runner 上线（在 GitHub 上）
gh api /repos/<owner>/<repo>/actions/runners | jq '.runners[] | {name, status}'
# 期望 status: "online"
```

---

## 4. values.yaml 说明

```yaml
githubConfigUrl: "https://github.com/minesunny/dialect"   # 仓库地址
githubConfigSecret: arc-github-app-secret                 # 上一步创建的 secret 名

scaleSetLabels:                                          # runner 标签（workflow 里 runs-on 匹配）
  - self-hosted
  - linux
  - x64

proxy:                                                   # 出网代理（没有代理可整段删除）
  http:
    url: http://172.16.1.1:7890
  https:
    url: http://172.16.1.1:7890
  noProxy:
    - localhost
    - 127.0.0.1
    - .svc
    - .cluster.local
    - 10.0.0.0/8

maxRunners: 4                                            # 最大并发 runner 数
minRunners: 1                                            # 常驻最小 runner 数

runnerScaleSetName: "arc-runner-set"

template:
  spec:
    initContainers:
      - name: init-dind-externals                        # 复制 dind 需要的外部文件
        image: ghcr.io/actions/actions-runner:2.337.0
        command: ["cp", "-r", "/home/runner/externals/.", "/home/runner/tmpDir/"]
        volumeMounts:
          - name: dind-externals
            mountPath: /home/runner/tmpDir
      - name: dind                                       # docker-in-docker
        image: docker:29-dind
        args:
          - dockerd
          - --host=unix:///var/run/docker.sock
          - --group=123
        env:
          - name: HTTP_PROXY
            value: http://172.16.1.1:7890
          - name: HTTPS_PROXY
            value: http://172.16.1.1:7890
          - name: NO_PROXY
            value: localhost,127.0.0.1,.svc,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
        securityContext:
          privileged: true                               # dind 需要特权模式
        restartPolicy: Always
        startupProbe:
          exec:
            command: ["docker", "info"]
          initialDelaySeconds: 0
          failureThreshold: 24
          periodSeconds: 5
        volumeMounts:
          - name: work
            mountPath: /home/runner/_work
          - name: dind-sock
            mountPath: /var/run
          - name: dind-externals
            mountPath: /home/runner/externals
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:2.337.0
        command: ["/home/runner/run.sh"]
        resources:
          requests: { cpu: "2", memory: "4Gi" }
          limits:   { cpu: "3", memory: "8Gi" }
        env:
          - name: ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT
            value: "true"
          - name: DOCKER_HOST
            value: unix:///var/run/docker.sock
          - name: RUNNER_WAIT_FOR_DOCKER_IN_SECONDS
            value: "120"
        volumeMounts:
          - name: dind-sock
            mountPath: /var/run
          - name: work
            mountPath: /home/runner/_work
          - name: gha-shared-cache
            mountPath: /home/runner/.npm
            subPath: npm
          # ... 其他语言缓存同理挂载
    volumes:
      - name: dind-sock
        emptyDir: {}
      - name: dind-externals
        emptyDir: {}
      - name: work
        emptyDir: {}
      - name: gha-shared-cache
        persistentVolumeClaim:
          claimName: gha-shared-cache
```

workflow 里使用：

```yaml
runs-on: [self-hosted, linux, x64]
```

---

## 5. 常见问题与解决

### 5.1 监听器日志报 `401 Bad credentials`，runner 一直不上线（本次核心问题）

**现象**

```
failed to fetch access token: request POST https://api.github.com/app/installations/165990848/access_tokens
failed (status="401 Unauthorized" ...): Bad credentials
```

监听器 crash loop，`kubectl get pods -n arc-systems` 里 listener 不断重启。

**根因：主机时钟偏差**

ARC 每次向 GitHub 认证时，用「当前时间」签名 JWT（`iat` 字段）。如果主机时钟**快于** GitHub 服务器时钟，GitHub 收到「未来时间戳」，直接判 `Bad credentials`。

> 看起来像私钥错了，其实 App ID / Installation ID / 私钥都对，是时钟错。

**诊断**

```bash
# 对比主机时间与 GitHub 服务器时间
host_epoch=$(date -u +%s)
gh_date=$(curl -sS -m 15 -D - -o /dev/null https://api.github.com/ \
  | grep -i '^date:' | sed 's/^[Dd]ate: //' | tr -d '\r')
gh_epoch=$(date -u -d "$gh_date" +%s)
echo "skew = $((host_epoch - gh_epoch)) 秒"   # 偏差超过 ~60 秒就会触发
```

**修复**

```bash
# 1) 关闭自动同步、手动对齐时间（set-time 按“本地时区”解释，注意换算）
sudo timedatectl set-ntp false
gh_date=$(curl -sS -m 15 -D - -o /dev/null https://api.github.com/ \
  | grep -i '^date:' | sed 's/^[Dd]ate: //' | tr -d '\r')
local_target=$(TZ=Asia/Shanghai date -u -d "$gh_date +3 seconds" +"%Y-%m-%d %H:%M:%S")
sudo timedatectl set-time "$local_target"

# 2) RTC 改为 UTC，避免开机 8 小时偏差
sudo timedatectl set-local-rtc 0
```

### 5.2 NTP 无法同步（代理网络）

**现象**

`timedatectl` 显示 `System clock synchronized: no`，`NTP service: active` 但 `Packet count: 0`。

**根因**

这台机器只能通过 HTTP 代理出网，直连 DNS 和 NTP（UDP/123）都被封：

```bash
systemd-timesyncd 日志: Server: n/a (ntp.ubuntu.com), Packet count: 0
udp 123 到公网 NTP: 全部超时
```

**解决（用 HTTPS 校时替代 NTP）**

创建 `/usr/local/bin/sync-clock-http.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
PROXY="http://172.16.1.1:7890"
GH_DATE=$(curl -sS -m 15 -x "$PROXY" -D - -o /dev/null https://api.github.com/ \
  | grep -i '^date:' | sed 's/^[Dd]ate: //' | tr -d '\r')
[ -z "$GH_DATE" ] && { echo "fetch failed" >&2; exit 1; }

LOCAL_TARGET=$(TZ=Asia/Shanghai date -d "${GH_DATE} +2 seconds" +"%Y-%m-%d %H:%M:%S")
SKEW=$(( $(date -u +%s) - $(date -u -d "$GH_DATE" +%s) ))
SKEW_ABS=${SKEW#-}
if [ "$SKEW_ABS" -le 2 ]; then
  echo "already in sync (${SKEW}s)"; exit 0
fi
timedatectl set-ntp false 2>/dev/null || true
timedatectl set-time "$LOCAL_TARGET"
echo "corrected clock (was ${SKEW}s)"
```

```bash
sudo chmod +x /usr/local/bin/sync-clock-http.sh
```

加 systemd timer（开机 + 每 30 分钟同步）：

```bash
# /etc/systemd/system/sync-clock-http.service
[Unit]
Description=Sync system clock from GitHub API over HTTP proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-clock-http.sh

# /etc/systemd/system/sync-clock-http.timer
[Unit]
Description=Periodically sync system clock from GitHub API

[Timer]
OnBootSec=30s
OnUnitActiveSec=30min
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now sync-clock-http.timer
```

### 5.3 私钥 / App ID / Installation ID 真的不匹配

如果时钟没问题还报 `Bad credentials`，用本地脚本验证 JWT（需要 Python3 + PyJWT）：

```bash
python3 - << 'EOF'
import jwt, time
key = open('./arc.pem','rb').read()
now = int(time.time())
token = jwt.encode({'iat': now-120, 'exp': now+300, 'iss': '5116138'}, key, algorithm='RS256')
print(token)
EOF
```

```bash
# 用返回的 token 验证（注意：iat 必须比当前时间早 ~2 分钟，避开时钟偏差干扰）
curl -sS -H "Authorization: Bearer <TOKEN>" https://api.github.com/app
# 返回 {"id":5116138,...} = key/app_id 正确
# 返回 {"message":"Bad credentials"} = key 与 app_id 不匹配（去 GitHub App 重新生成 key）
```

### 5.4 监听器 crash loop / 日志无 401

先看监听器日志定位：

```bash
kubectl logs -n arc-systems -l actions.github.com/scale-set-name=arc-runner-set --tail=50
```

常见报错：

- `ephemeralrunnerset ... not found`：listener 引用的 EphemeralRunnerSet 名字已变（见 5.5）。
- 一直 `ContainerCreating`：listener-config secret 缺失，删掉 listener 让 controller 重建。

### 5.5 EphemeralRunnerSet 名字不一致

**现象**

```
could not patch ephemeral runner set arc-runner-set-nf42t, error: ... "arc-runner-set-nf42t" not found
```

**根因**

EphemeralRunnerSet 的名字是 `arc-runner-set-<随机后缀>`（controller 用 `generateName` 生成），listener 的 config 里 `ephemeral_runner_set_name` 引用旧名字。当 ERS 被手动删除后重建，新名字变了，但 listener 没跟着更新。

**修复（让 listener 重新引用当前 ERS）**

```bash
# 删除 AutoscalingListener（保留 ERS），controller 会用当前 ERS 名字重建 listener
kubectl delete autoscalinglistener -n arc-systems --all
# 观察是否恢复
kubectl get pods -n arc-systems
```

> 教训：**不要手动删 EphemeralRunnerSet**，它名字是随机的，删了会造成 listener 引用失效。要重置就删 listener。

### 5.6 runner 启动后报 "registration was not found"

**现象**

runner pod 日志：

```
Registration xxx was not found. Runner registrations are automatically deleted
for runners that have not connected recently.
```

**根因**

ephemeral runner 用的是 JIT 注册 token（约 1 小时有效），机器长时间停机后旧 runner 的注册已过期。

**解决**

正常情况 controller 会自动重建 runner。若卡住，删除对应 runner pod 让它重新注册：

```bash
kubectl delete pod -n arc-runners -l actions-ephemeral-runner=true
```

---

## 6. 常用运维命令

```bash
# 查看 controller / listener / runner
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl get autoscalingrunnerset -n arc-runners
kubectl get ephemeralrunnerset -n arc-runners

# 监听器日志
kubectl logs -n arc-systems -l actions.github.com/scale-set-name=arc-runner-set -f

# 单个 runner 日志
kubectl logs -n arc-runners <runner-pod> -c runner -f

# GitHub 上的 runner 状态
gh api /repos/<owner>/<repo>/actions/runners | jq '.runners[] | {name,status,busy}'

# 重启监听器（改动 values.yaml 后需要重新部署）
kubectl delete pod -n arc-systems -l actions.github.com/scale-set-name=arc-runner-set

# 升级配置
helm upgrade arc-runner-set -n arc-runners -f values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set --version 0.14.2

# 时钟偏差排查
curl -sS -D - -o /dev/null https://api.github.com/ | grep -i '^date:'
date -u
```
