# Bootstrap → Install → OAuth → Validate → Activate

这五步独立执行，不能把“工具安装成功”当作“服务已经可用”。本入口不执行 Terraform、不创建或销毁云资源、不自动写入 Vault，也不复用其他用户工作区。

## 1. 安装工具

使用 README 的 curl 命令，固定完整 commit SHA。私有仓库要求最小只读 GitHub 权限；认证值通过 curl 标准输入和安装器内存传递，不保存到仓库或 Git remote。

默认位置：`~/.local/share/ai-aggregator/releases/<sha>`。安装后添加 `~/.local/share/ai-aggregator/bin` 到当前会话 PATH。

| 命令 | 用途 |
| --- | --- |
| ai-aggregator-bootstrap | 获取固定版本依赖和控制机 Ansible Collections |
| ai-aggregator-install | 执行 canonical stage，写入服务配置；不会自动 activate |
| ai-aggregator-deploy | 显式 plan / stage / activate |
| ai-aggregator-verify | 模型目录和显式选择模型的真实推理 |

## 2. Bootstrap 控制机

Git/gh 必须已安装并具备仓库读取权限。选用专属目录，不指向当前多仓库用户工作区：

```bash
ai-aggregator-bootstrap --workspace "$HOME/.local/share/ai-aggregator-controller"
```

已有可用 Ansible 时，上述命令复用它；否则在工具 Python venv 中增加 `--install-ansible`。该选项安装 ansible-core 2.19.x，要求 Python 3.11–3.13；Python 3.14 控制机需提供支持该版本的独立 Ansible，不能强行套用 2.19。[官方支持矩阵](https://docs.ansible.com/projects/ansible-core/2.19/reference_appendices/release_and_maintenance.html)

Bootstrap 逐一 checkout `dependencies.lock.json` 的 playbooks、gateway、gitops、toolkit commit；已有目录只有干净且版本一致才复用。Collections 版本来自 `controller-collections.yml`，安装在 workspace 内，部署入口自动使用对应路径。不会修改全局 Git credential helper。

源码 commit 和 Collections 固定；可选 Ansible 2.19.x 是版本范围，不宣称完整 Python 供应链已实现哈希锁定。

## 3. Install / Stage 服务

先完成节点与安全前置条件：

- Linux systemd 节点、可用 SSH/sudo、inventory 的 gateway/CPA 分组。
- 完整 GitOps 声明，选择环境、拓扑与入口模式；真实变更需 `enabled: true`。
- 新节点需已具备 Caddy、APISIX Runtime（若选择 APISIX）、固定 SHA 的 New API/CPA artifact、LiteLLM Runtime 和 PostgreSQL；当前 canonical 角色不是完整裸机引导程序。
- Gateway 运行时 Vault 权限和 TLS 证书机制；不在命令行传 `VAULT_TOKEN`。
- CPA 独立用户和节点本地认证；新实例人工 OAuth。
- 不与 Home-Lab 旧路径假定混用。角色 binary/home 路径必须与目标安装布局一致。

### 直连：只暂存已有健康 New API 的入口

```bash
ai-aggregator-deploy --mode direct-new-api \
  --playbooks /path/to/controller/playbooks \
  --manifest /path/to/direct-manifest.yaml --inventory /path/to/inventory.ini

ai-aggregator-install --mode direct-new-api \
  --playbooks /path/to/controller/playbooks \
  --manifest /path/to/direct-manifest.yaml --inventory /path/to/inventory.ini \
  --approve-change
```

直连没有安装 New API/CPA/LiteLLM 的效果；这是入口配置部署。使用节点现有 Vault TLS contract 时增加 `--vault-tls-runtime`。

### APISIX：暂存 gateway/CPA 角色配置

先准备专门的 gateway 契约：只声明 New API 上游，Host 与环境一致，至少一个租户 enabled，auth 为 `new-api-token`。不要直接把完整 GitOps 环境声明当作 gateway 公共契约。

```bash
python3 -m gatewayctl render /path/to/gateway-contract.yaml \
  --adapter apisix --output-dir /path/to/rendered-apisix
# 上述命令在 controller/gateway checkout 下执行，先 validate 契约。

ai-aggregator-install --mode apisix \
  --playbooks /path/to/controller/playbooks \
  --manifest /path/to/apisix-manifest.yaml --inventory /path/to/inventory.ini \
  --apisix-bundle-dir /path/to/rendered-apisix --approve-change
```

Stage 会写入配置、systemd 和受限 tmpfs 凭据，不是 dry-run。预装 APISIX、artifact、数据库等未就绪会失败，安装器不会猜测版本或从任意 URL 下载二进制。

Kong 仍只允许 plan。旧角色的用户 Token 与 LiteLLM 路由尚未完成迁移，不能通过改脚本参数强制绕过。

## 4. OAuth / Validate

使用 CPA 自己的 OAuth 流程逐实例登录，先切换到实例用户有权访问的工作目录。不要复制本机 `.codex/`、`.claude/`、`.gemini/` 到仓库。

首次 stage 后，目标 gateway 未必已经启动，也未切入新路径。先核对候选文件、systemd、后端健康与安全策略；不能把仍指向旧入口的 HTTPS 200 当成候选链路通过。

## 5. Activate 与验收

```bash
ai-aggregator-deploy --mode apisix --operation activate \
  --playbooks /path/to/controller/playbooks \
  --manifest /path/to/apisix-manifest.yaml --inventory /path/to/inventory.ini \
  --approve-change
```

按 [模式文档](modes/02-apisix.zh.md)先确认后端可用和上一份配置可回滚。对于原有直连 Home-Lab，本脚本不会自动选择现有证书/binary 的特殊路径，也不会自动覆盖运行时修正。

使用 New API 用户 Key，通过受限运行时变量或 Keychain 加载，再运行：

```bash
ai-aggregator-verify --url https://ai-internal.onwalk.net/v1 \
  --model gpt-5.6-luna --model claude-sonnet-5 --model gemini-3-flash
```

这会消耗真实上游账号额度。验证未授权请求 401、有效请求、推理与 New API 消费日志后，才记录上线成功；官方 API 分支须另行配置 New API → LiteLLM Channel 并验证。
