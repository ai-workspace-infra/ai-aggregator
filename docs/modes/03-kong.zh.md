# 模式三：Caddy → Kong → New API

```text
ai-internal.onwalk.net → Caddy TLS → Kong :8000 → New API :3000
                                                  ├→ CPA
                                                  └→ LiteLLM 渠道（待配置）
```

Kong Traditional 使用 PostgreSQL，不使用 etcd。配置由契约渲染为 YAML/JSON，再通过受控 Admin API/decK 同步；禁止 SQL 直接修改 Kong 内部表。

## 运行验证与自动部署不是同一状态

2026-10-03 在 Home-Lab 启动 `ai-aggregator-kong`，proxy/admin 均绑定 localhost。通过 Admin API 建立独立临时 service、route 和插件，路由保留 `/v1`，Token 原样传给 New API。

无/错误 Token 返回 401，三种认证头均返回 42 个模型；GPT、Claude、Gemini 的最小推理均通过。随后删除临时实体，恢复直连 Caddy 并停用 Kong。该验证没有将旧 Kong 配置永久迁移为最终方案。

现有 `legacy-kong.yml` 仍要求 CPA Vault 凭据，并包含直接 LiteLLM 旁路；与本项目最新契约不一致。本仓库因此允许 Kong plan，但阻止 stage/activate。

## 自动部署解锁任务

1. 移除旧 bootstrap Consumer Key 到共享上游 Key 的替换逻辑。
2. 所有用户 API 请求仅转 New API；LiteLLM 作为 New API Channel，而不是公网旁路。
3. 移除 CPA OAuth Vault 引用，保留节点本地认证。
4. Gateway DSN 使用 `kv/<env>/ai-aggregator/gateway/kong#database_dsn`。
5. 将 renderer 配置通过受控 Admin API/decK 幂等同步，并实现失败回滚。
6. 验证 systemd 生命周期、PostgreSQL migration、重启恢复、反复切换和 dashboard 路由。
7. 发布新的固定 playbooks revision，更新依赖锁和包装脚本，才能解锁自动部署。

不要复制本次临时路由并把它标为可重复全量部署。Kong 管理端口不能公开；配额和模型权限仍由 New API 按真实用户身份执行。
