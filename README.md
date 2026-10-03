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

## 三种模式

| 模式 | 操作文档 | 本次运行验证 | 自动部署边界 |
| --- | --- | --- | --- |
| direct-new-api | [直连](docs/modes/01-direct-new-api.zh.md) | 通过 | 已有健康 New API 的入口配置部署，不是全新主机安装 |
| apisix | [APISIX](docs/modes/02-apisix.zh.md) | 通过 | 复用 playbooks Standalone 角色，需完成 artifact、Vault、GitOps 前置条件 |
| kong | [Kong](docs/modes/03-kong.zh.md) | 临时测试路由通过 | 旧角色尚未迁移；本仓库阻止自动 stage/activate |

测试通过不代表全部 42 个模型、官方 API 渠道或重启恢复均已验证。

## 快速入口

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
