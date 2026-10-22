# AI Aggregator

AI Aggregator 专用部署入口、模式说明与验收记录。凭据、OAuth 和运行数据不属于本仓库。

## 最终架构

```text
客户端：统一 URL + New API 用户 Token + 标准模型名
  → Caddy：TLS
  → [可选 APISIX / Kong：入口策略、Token 透传]
  → New API：用户、套餐、额度、模型权限、消费记录
      ├→ CPA：订阅账号矩阵
      └→ LiteLLM：官方 API 适配、重试、成本统计
```

Home-Lab 入口为 `https://ai-internal.onwalk.net/v1`。`bootstrap_client_key` 不是 New API 用户 Key，不能替代用户身份或账本。

## 🚀 快速开始

使用单行命令在 Debian 12+ 或 Ubuntu 22.04+ 实例上自动化安装与配置 AI Gateway（Caddy 2.8.4-alpine 自动 HTTPS 反向代理 + New API v0.4.10 权限管理 + LiteLLM v1.51.0 路由统计），部署目录位于 `/opt/ai-gateway`。

> [!NOTE]
> Note that `ai-aggregator` is a private repository and the raw command will be accessible publicly once the repository is made public.
> （当前仓库为私有仓库，公开后可通过上述 raw 链接直接执行；在私有阶段可通过 GitHub Token 授权访问或在克隆仓库后执行 `bash scripts/setup-ai-gateway.sh ...`）。

### 1. 单机模式（Standalone）

适用于单节点开发或测试环境，自动生成初始根凭据，并配置本地 Mock/默认模型：

```bash
curl -fsSL https://raw.githubusercontent.com/ai-workspace-infra/ai-aggregator/main/scripts/setup-ai-gateway.sh | \
  bash -s -- --domain ai.example.com --standalone
```

### 2. 团队模式（Team with MCP）

适用于团队协同与 MCP 协议集成，运行时凭据直接从 HashiCorp Vault 注入环境变量（Fail-Closed 闭环校验）：

```bash
export AI_GATEWAY_DOMAIN="ai.example.com"
export MCP_DOMAIN="mcp.example.com"
export UPSTREAM_API_KEY="<runtime-secret>"
export MCP_SERVICE_TOKEN="<runtime-secret>"
curl -fsSL https://raw.githubusercontent.com/ai-workspace-infra/ai-aggregator/main/scripts/setup-ai-gateway.sh | \
  bash -s -- --domain "$AI_GATEWAY_DOMAIN" --with-mcp
unset UPSTREAM_API_KEY MCP_SERVICE_TOKEN
```

### 3. 卸载与清理

如需停止网关服务并清理容器，可使用 `--uninstall` 参数。卸载过程会自动创建 `/opt/ai-gateway/data` 的时间戳备份：

```bash
curl -fsSL https://raw.githubusercontent.com/ai-workspace-infra/ai-aggregator/main/scripts/setup-ai-gateway.sh | \
  bash -s -- --uninstall
```

或者在已部署节点本地执行：

```bash
bash /opt/ai-gateway/scripts/setup-ai-gateway.sh --uninstall
```

## 三种模式

| 模式 | 操作文档 | 本次运行验证 | 自动部署边界 |
| --- | --- | --- | --- |
| direct-new-api | [直连](docs/modes/01-direct-new-api.zh.md) | 通过 | 已有健康 New API 的入口配置部署，不是全新主机安装 |
| apisix | [APISIX](docs/modes/02-apisix.zh.md) | 通过 | 复用 playbooks Standalone 角色，需完成 artifact、Vault、GitOps 前置条件 |
| kong | [Kong](docs/modes/03-kong.zh.md) | 临时测试路由通过 | 旧角色尚未迁移；本仓库阻止自动 stage/activate |

测试通过不代表全部 42 个模型、官方 API 渠道或重启恢复均已验证。

## 快速入口

### curl 一条 Shell 安装

安装的是部署/验证工具，不是 Caddy、New API、APISIX、Kong 或 CPA 服务。支持 Linux/macOS，无需 sudo，不修改 shell profile；前置为 Python 3.10+、venv/pip 和 GitHub 私有仓库读取权限。先用 `gh auth login` 登录，或将最小只读 Token 放入 `GH_TOKEN` 环境变量，禁止在 URL 或参数中写真实 Token。

以下为 bash/zsh 控制终端命令。`REF` 必须换成已审核的完整 40 位 commit SHA，不使用 `main`、可变分支或短 SHA：

```bash
set +x
set -o pipefail
REF='<完整40位commit SHA>'
{
  printf 'url = "https://raw.githubusercontent.com/ai-workspace-infra/ai-aggregator/%s/scripts/install.sh"\n' "$REF"
  printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN:-$(gh auth token)}"
} | curl --config - --fail --silent --show-error --proto '=https' \
  | sh -s -- --ref "$REF"
```

curl 的认证头通过标准输入传递，不出现在进程命令参数。安装器在内存读取 GitHub Token，下载固定 SHA 的源码并移除跨主机重定向的认证头；不会保存 GitHub Token。`curl | sh` 仍然是执行远程代码，应先审核指定 SHA 的安装脚本；需要更严格审计时先下载、检查，再用 `sh install.sh --ref "$REF"` 执行。

默认安装到 `~/.local/share/ai-aggregator`，支持 `--prefix /path/to/ai-aggregator`。每个 commit 独立 release，已有 release 不覆盖；安装失败的 release 保留供检查。升级使用新 SHA，成功后只更新工具入口。工具回滚可直接运行旧 release 的 `.venv/bin/python scripts/deploy.py` / `scripts/verify.py`，不会自动回滚服务器。

```bash
export PATH="$HOME/.local/share/ai-aggregator/bin:$PATH"
ai-aggregator-deploy --help
ai-aggregator-verify --help
ai-aggregator-bootstrap --help
ai-aggregator-install --help
```

真正部署仍需干净的固定版本 playbooks、inventory、GitOps 声明、Ansible 与 Vault 前置条件。默认 `plan`；`stage/activate` 需显式审批参数，Kong 自动变更仍被阻止。

完整分步操作见 [Bootstrap 与 Install](docs/bootstrap-and-install.zh.md)。`bootstrap` 准备控制机；`install` 调用 canonical stage，默认不切流。现有 role 依赖预装 Runtime/artifact，不是全新裸机的无前置一键安装。

### 从 checkout 使用

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python scripts/deploy.py --mode direct-new-api \
  --playbooks /path/to/clean-playbooks \
  --manifest /path/to/gitops-manifest.yaml --inventory /path/to/inventory.ini
```

默认只执行 `plan`。按模式文档准备声明，先 `stage`，验证后再 `activate`，两者都需显式 `--approve-change`。

部署包装入口要求 playbooks 与锁文件完全一致且工作区干净。请新建独立 checkout，不在现有用户工作区执行清理：

```bash
git clone https://github.com/ai-workspace-infra/playbooks.git /path/to/clean-playbooks
git -C /path/to/clean-playbooks checkout --detach 6c2cf608e19dfcec6de5b5330d89457235977ceb
```

Ansible、角色依赖、SSH 权限和完整 inventory 仍由控制机提供。升级依赖需要检查变更、重新验证并显式修改锁文件。

```bash
# 用交互式输入或现有凭据管理器加载用户 Key，不把真实值写入命令历史。
read -s AI_GATEWAY_CLIENT_KEY
export AI_GATEWAY_CLIENT_KEY
python3 scripts/verify.py --url https://ai-internal.onwalk.net/v1
# 显式增加真实推理：可能消耗账号额度。
python3 scripts/verify.py --url https://ai-internal.onwalk.net/v1 \
  --model gpt-5.6-luna --model claude-sonnet-5 --model gemini-3-flash
unset AI_GATEWAY_CLIENT_KEY
```

使用 zsh 时，静默输入可改为 `read -rs AI_GATEWAY_CLIENT_KEY`。桌面客户端的凭据存储单独使用系统凭据管理器，不依赖交互式 Shell 环境变量。

## 仓库分工

- 本仓库：模式操作文档、部署包装入口、验收脚本、验收记录。
- `gateway`：厂商无关契约和渲染器，不在这里复制。
- `gitops`：环境、节点、域名、模式和生命周期的事实源。
- `playbooks`：安装、systemd、Vault 注入和切流实现。
- `platform-ops-toolkit`：CI/CD 编排；本仓库不会自动创建云资源。
- `knowledge`：架构与选型阅读入口，链接到本仓库操作文档。

依赖版本见 [dependencies.lock.json](dependencies.lock.json)，凭据规则见 [安全边界](docs/security.zh.md)，实测结果见 [Home-Lab 验收](docs/verification/home-lab-2026-10-03.zh.md)。
