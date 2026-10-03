# 模式一：Caddy → New API

```text
ai-internal.onwalk.net → Caddy TLS → New API
                                  ├→ CPA
                                  └→ LiteLLM 渠道（待配置）
```

适用于单节点排障和不需要额外入口策略的内网部署。New API 保留用户、套餐、额度、模型权限和消费账本。

## 声明

在 GitOps 完整环境声明内设置，以下仅是字段片段，不能独立部署：

```yaml
spec:
  gateway:
    entry_mode: direct-new-api
    client_token_source: new-api
```

New API 必须已健康运行，绑定 localhost。角色只修改 Caddy 入口，不安装数据库、CPA 或 LiteLLM，也不会自动停用旧网关。启用 TLS Vault 运行时配置的主机应通过受控 Ansible 变量配置其证书路径，不能覆盖为另一套证书机制。

## 部署与回滚

1. 使用依赖锁中的干净 playbooks checkout；准备完整 GitOps manifest 和 inventory。
2. 运行 README 中的部署命令，默认 `plan`。
3. 检查 `spec.enabled: true`、New API `/api/status`、现有证书和回滚入口。
4. 增加 `--operation stage --approve-change`，候选文件位于 Caddy import 目录之外。
5. 再增加 `--operation activate --approve-change`。角色核对候选新鲜度，备份现有片段，validate 成功后 reload；失败则恢复原片段。
6. 运行 `scripts/verify.py`，再验证桌面客户端。

主动回滚时使用已保存的上一份完整声明重新 stage/activate；跨模式回滚必须先确认目标网关健康，不能只替换端口。

## 客户端

使用 `Authorization: Bearer <New API 用户 Key>`；Anthropic 原生客户端可使用 `x-api-key`。实测直连 New API 不支持 `apikey` 头。不要在 Caddy 中替换为共享管理员 Token。

2026-10-03：42 个目录模型，GPT/Claude/Gemini 三个代表模型推理通过。当前 Home-Lab 默认仍是这个模式。
