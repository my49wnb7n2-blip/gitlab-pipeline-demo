# GitLab PostgreSQL Cleanup Pipeline Demo

这个示例项目演示如何使用 GitLab CI/CD 安全地清理 PostgreSQL
`audit_logs` 表中超过 90 天的数据。

主要保护措施：

- Merge Request 中启动临时 PostgreSQL 做集成测试。
- dev 和 staging 依次执行 plan、分批清理和验证。
- production 先使用只读账号生成计划，再等待人工批准。
- 使用固定截止时间，避免各 Job 对“90 天前”产生不同理解。
- 每批独立删除，降低大事务和长时间锁表的风险。
- 使用 `MAX_DELETE_ROWS` 限制单次最大删除量。
- 使用 `resource_group` 防止同一环境并发清理。
- UUID 主键由 PostgreSQL 的 `gen_random_uuid()` 自动生成。

## 项目结构

```text
.
├── .gitlab-ci.yml
├── .gitignore
├── README.md
├── scripts
│   ├── maintenance.sh
│   └── run_local_test.sh
└── sql
    ├── indexes.sql
    ├── schema.sql
    └── seed_test_data.sql
```

## 本地测试

要求：

- PostgreSQL 正在本地运行。
- 当前系统用户可以创建测试数据库。
- 已安装 `createdb`、`dropdb`、`pg_isready` 和 `psql`。

执行：

```bash
./scripts/run_local_test.sh
```

脚本只会创建名称类似下面的临时数据库：

```text
gitlab_pipeline_demo_test_12345
```

测试完成或失败退出时都会删除该临时数据库，不会操作现有业务数据库。

测试过程会：

1. 建立 `audit_logs` 表。
2. 插入 3 条超过 90 天和 2 条近期数据。
3. 确认 UUID 默认值自动生成。
4. 以每批 2 条的方式删除 3 条旧数据。
5. 验证最终只保留 2 条近期数据。

## 清理脚本接口

生成清理计划：

```bash
DATABASE_URL="postgresql:///your_database" \
  ./scripts/maintenance.sh plan
```

计划会生成忽略提交的 `plan.env`：

```text
CUTOFF_AT=2026-04-25T02:30:00.000000Z
ELIGIBLE_ROWS=1234
```

执行清理：

```bash
DATABASE_URL="postgresql:///your_database" \
  ./scripts/maintenance.sh apply
```

验证：

```bash
DATABASE_URL="postgresql:///your_database" \
  ./scripts/maintenance.sh verify
```

支持的变量：

| 变量 | 默认值 | 作用 |
|---|---:|---|
| `RETENTION_DAYS` | `90` | 数据保留天数 |
| `BATCH_SIZE` | `5000` | 单批删除行数 |
| `BATCH_SLEEP_SECONDS` | `1` | 批次间隔秒数 |
| `MAX_DELETE_ROWS` | `1000000` | 单次允许删除的最大行数 |
| `DATABASE_URL` | 无 | PostgreSQL 连接地址，必须提供 |

## GitLab 流程

代码提交或 Merge Request：

```text
lint
  → integration_test
```

定时或网页手动维护：

```text
dev_plan
  → dev_apply
  → dev_verify
  → staging_plan
  → staging_apply
  → staging_verify
  → production_plan
  → production_apply（人工确认）
  → production_verify
```

## 从 GitHub 导入 GitLab

GitHub 不会执行 `.gitlab-ci.yml`。需要在 GitLab 中创建项目并导入这个仓库：

```text
GitLab
→ New project
→ Import project
→ GitHub 或 Repository by URL
→ 选择 gitlab-pipeline-demo
```

导入后在 GitLab 的 Pipeline Editor 中验证：

```text
Build
→ Pipeline editor
→ Validate
```

如果希望 GitHub 后续提交自动同步到 GitLab，需要配置 repository
mirroring，或者把 GitLab 作为另一个 Git remote 并同时推送。

## Runner

真实数据库 Job 使用：

```yaml
tags:
  - db-maintenance
```

因此需要一个带 `db-maintenance` tag、能够访问各环境数据库的
self-hosted GitLab Runner。Runner 不应为了方便而获得整个内网权限。

如果只是学习 Pipeline，可以临时移除 `.maintenance_job` 中的 `tags`；
但 production 数据库不建议使用公共共享 Runner。

## GitLab CI/CD Variables

进入：

```text
Settings
→ CI/CD
→ Variables
```

添加以下同名、不同 Environment scope 的变量：

| Key | Environment scope | 数据库权限 |
|---|---|---|
| `DATABASE_URL` | `dev` | `SELECT, DELETE` |
| `DATABASE_URL` | `staging` | `SELECT, DELETE` |
| `DATABASE_URL` | `production-plan` | 仅 `SELECT` |
| `DATABASE_URL` | `production` | `SELECT, DELETE` |

production 相关变量应设置为：

- Masked and hidden
- Protected
- Expand variable reference 关闭

不要把数据库密码写进 `.gitlab-ci.yml`。

## 创建定时任务

进入：

```text
Build
→ Pipeline schedules
→ New schedule
```

建议配置：

```text
Description: Daily audit_logs cleanup
Cron: 30 2 * * *
Timezone: Asia/Shanghai
Target branch: main
```

添加变量：

```text
MAINTENANCE_TASK=cleanup_audit_logs
```

## 生产上线前检查

- 确认 `(created_at, id)` 索引已提前创建。
- 确认外键不存在意外级联删除。
- 确认数据库备份和恢复演练有效。
- 先观察 production plan 的 `ELIGIBLE_ROWS`。
- 检查数据库 CPU、锁等待、WAL 和复制延迟。
- 使用最小权限数据库账号。
- 将 `production` 配置为 Protected environment。
