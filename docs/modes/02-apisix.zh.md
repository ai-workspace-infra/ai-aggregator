# 模式二：Caddy → APISIX → New API

```text
ai-internal.onwalk.net → Caddy TLS → APISIX :9080 → New API :3000
                                                      ├→ CPA
                                                      └→ LiteLLM 渠道（待配置）
```

APISIX 为 Standalone 文件配置，无 etcd；GitOps 是声明来源，不使用 PostgreSQL 作为 APISIX 原生配置后端。APISIX 做入口策略，New API 做最终用户鉴权和唯一额度账本。此链路不启用 `ai-proxy-multi` 绕过账本。

## 声明与前置条件

在完整环境声明内配置：

```yaml
spec:
  gateway:
    entry_mode: gateway
    adapter: apisix
    client_token_source: new-api
  apisix:
    auth_mode: new-api-token-pass-through
    runtime_secret_refs: {}
```

补齐完整 schema 所要求的 Standalone、loopback、GitOps bundle、节点和 artifact 字段。包装脚本不是完整 schema 校验器，仍需先运行 toolkit manifest 校验和 gateway 渲染测试。

1. 先 plan；校验渲染文件、插件列表和运行版本。
2. 确认 `enabled: true`、固定 artifact revision/sha256、Vault Gateway 权限和 PostgreSQL 可达性。
3. 用部署包装入口执行 stage；CPA OAuth 仍由人工完成。
4. 检查 APISIX loopback 健康、有效/无效 Token、模型目录，再 activate 切 Caddy。
5. 验证推理及 New API 消费日志；失败则切回已验证直连声明。

## Home-Lab 本次修正

- 删除 systemd 中已不被 staging 脚本支持的 `--client-key-file`、`--litellm-environment` 参数。
- forward-auth 预检地址使用 `/api/usage/token/`，避免尾斜杠重定向导致 301。
- 保留 VPN 白名单 `10.79.0.7/32`、`10.79.0.9/32`。回环测试需要模拟可信 Caddy 的实际来源转发；不能据此向公网信任任意 `X-Forwarded-For`。
- `Authorization`、`x-api-key`、`apikey` 归一化为用户 Bearer Token，不注入 bootstrap/shared Key。

这些修正已在 Home-Lab 运行时完成；尚未全部纳入 canonical playbooks 的自动部署实现，下一次部署前需检查差异。

2026-10-03：经 Caddy 实际切入 APISIX，42 个模型目录、三个代表模型推理通过，完成后恢复直连。APISIX 保持 active，但不是当前 Caddy 路径。
