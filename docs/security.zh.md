# 凭据、配置与备份边界

## Vault

逻辑路径与 KV v2 HTTP API 路径区分：逻辑 `kv/<env>/...`，API `/v1/kv/data/<env>/...`。

```text
kv/<env>/ai-aggregator/database/new-api
kv/<env>/ai-aggregator/database/litellm
kv/<env>/ai-aggregator/gateway/caddy
kv/<env>/ai-aggregator/gateway/new-api
kv/<env>/ai-aggregator/gateway/litellm
kv/<env>/ai-aggregator/gateway/kong     # 仅 Kong 模式 DB DSN 等部署凭据
kv/<env>/ai-aggregator/litellm/providers/*
```

APISIX 用户 Token 透传模式不需要 bootstrap client key。历史 bootstrap key 不能作为 New API 用户 Key；旧记录不自动删除。

## 归属

- GitOps：节点、环境、模式、端口、模型映射和 secret_ref，不含凭据值。
- New API：用户、套餐、额度、模型权限、消费记录、客户端 Token 的业务管理。
- Vault：DB、session/crypto、网关部署凭据和 Provider API Key。
- CPA：实例独立 Unix 用户与节点本地 auth；OAuth 不上传本仓库、Vault、DB 或 CI artifact。
- 客户端：系统 Keychain/凭据管理器或受限运行时输入。不要把用户 Key 写入示例、命令行参数或 Git。

验证脚本支持环境变量和 `--key-file`（只传文件路径，值不进入参数）。文件必须当前用户所有、无组/其他用户权限。推荐 Keychain/Vault 临时读取，不长期明文保存。环境变量也不是完全隔离的秘密容器，应缩短生命周期。

## 升级、回滚和备份

升级前锁定依赖 commit、校验 artifact sha256，并保存 GitOps 声明、运行配置及数据库备份。New API、LiteLLM、Kong 各自数据库；迁移前验证恢复，不假设降版本一定可逆。

配置回滚使用上一份已验证声明重新 stage/activate；跨模式须先验证目标网关健康。备份凭据沿用数据库基础设施 contract，不新建 `ai-aggregator/database/backup`。

CPA 备份如有需要必须加密、限制账号权限并单独审批；本仓库无 OAuth 导入、导出或集中备份脚本。未验证磁盘加密状态时，不应宣称本地 OAuth 已满足加密存储要求。
