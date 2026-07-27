# GitLab 清理本机 PostgreSQL

这个项目通过 GitLab CI/CD 定期清理本机 PostgreSQL：

```text
database: postgres
schema:   public
table:    audit_logs_test
条件:     created_at 早于 90 天
```

目标表结构：

```sql
uuid        uuid PRIMARY KEY
log_message text NOT NULL
created_at  timestamp without time zone NOT NULL
```

清理目标在脚本中固定为 `public.audit_logs_test`，避免通过 CI 变量传入错误表名。

## 执行架构

```text
GitLab.com
  ├─ lint
  ├─ integration_test
  │    └─ Mac shell Runner + 本地临时 PostgreSQL 数据库
  └─ local_cleanup
       └─ Mac 上的 shell Runner
            └─ postgresql:///postgres
                 └─ public.audit_logs_test
```

不需要在 Mac 上安装完整 GitLab Server，但必须安装 GitLab Runner。
所有 Job 都由 Mac Project Runner 执行，不使用 GitLab Hosted Runner，
因此不需要为了使用免费计算额度而进行手机号或信用卡身份验证。

## 项目结构

```text
.
├── .gitlab-ci.yml
├── README.md
├── scripts
│   ├── maintenance.sh
│   └── run_local_test.sh
└── sql
    ├── indexes.sql
    ├── schema.sql
    └── seed_test_data.sql
```

## 安全清理过程

`scripts/maintenance.sh` 支持：

```text
plan    计算固定截止时间和预计删除数量
apply   使用同一截止时间分批删除
verify  确认截止时间之前的数据已清空
```

默认保护参数：

| 变量 | 默认值 | 作用 |
|---|---:|---|
| `RETENTION_DAYS` | `90` | 保留最近多少天的数据 |
| `BATCH_SIZE` | `5000` | 每批最多删除多少行 |
| `BATCH_SLEEP_SECONDS` | `1` | 两批之间暂停多少秒 |
| `MAX_DELETE_ROWS` | `1000000` | 预计删除数超过该值时停止 |
| `DATABASE_URL` | 无 | PostgreSQL 连接地址，必须配置 |

本地集成测试：

```bash
./scripts/run_local_test.sh
```

测试脚本会创建一个临时数据库，插入 3 条旧记录和 2 条新记录，
验证只删除 3 条旧记录，最后自动删除临时数据库。它不会操作真实的
`postgres` 数据库。

## 真实表需要的索引

第一次运行清理前，在真实数据库中执行：

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_logs_test_cleanup
ON public.audit_logs_test (created_at, uuid);
```

这条索引用于快速查找旧数据，并支持按照 `created_at, uuid` 分批删除。

## 1. 把项目放到 GitLab

在 GitLab.com 创建空项目 `gitlab-pipeline-demo`，然后给本地仓库添加
GitLab remote：

```bash
git remote add gitlab git@gitlab.com:<你的GitLab用户名>/gitlab-pipeline-demo.git
git push -u gitlab main
```

当前 GitHub `origin` 可以继续保留；以后可以分别推送：

```bash
git push origin main
git push gitlab main
```

## 2. 在 Mac 安装并注册 Runner

安装并启动：

```bash
brew install gitlab-runner
brew services start gitlab-runner
```

GitLab 项目页面进入：

```text
Settings
→ CI/CD
→ Runners
→ Create project runner
```

设置：

```text
Operating system: macOS
Tags: db-maintenance
Run untagged jobs: 关闭
```

保存后，按照 GitLab 页面显示的认证命令注册，Executor 选择：

```text
shell
```

确认 Runner：

```bash
gitlab-runner verify
brew services list
```

Runner 必须使用当前 Mac 用户启动，这样 `127.0.0.1` 或本地 Unix socket
才表示安装 PostgreSQL 的这台电脑。`.gitlab-ci.yml` 已把
`/opt/homebrew/bin` 加入 PATH，以便后台 Runner 找到 `psql`。

## 3. 配置数据库连接变量

GitLab 项目进入：

```text
Settings
→ CI/CD
→ Variables
→ Add variable
```

本机开发验证可以先配置：

```text
Key: DATABASE_URL
Value: postgresql:///postgres
Environment scope: local-production
Expand variable reference: 关闭
```

如果以后改成带密码的最小权限账号，可以使用：

```text
postgresql://audit_cleanup:<URL编码后的密码>@127.0.0.1:5432/postgres
```

不要把数据库密码提交到 `.gitlab-ci.yml`。

## 4. 手动验证

GitLab 项目进入：

```text
Build
→ Pipelines
→ New pipeline
```

选择 `main` 后直接创建 Pipeline。`MAINTENANCE_TASK` 已在
`.gitlab-ci.yml` 中固定为 `cleanup_audit_logs_test`，页面不需要再填写。

手动流水线的顺序：

```text
lint
→ integration_test
→ local_plan
→ local_cleanup（需要点击确认）
```

`local_plan` 只显示预计删除数量。`local_cleanup` 会重新生成最新计划，
然后在同一个 Job 中执行 plan、apply 和 verify，防止两个流水线交叉清理。

## 5. 创建定时清理

GitLab 项目进入：

```text
Build
→ Pipeline schedules
→ New schedule
```

示例：

```text
Description: Daily audit_logs_test cleanup
Cron: 30 2 * * *
Timezone: Asia/Shanghai
Target branch: main
```

Schedule 不需要额外变量；`.gitlab-ci.yml` 已提供维护任务默认值。

定时流水线会先在本地临时 PostgreSQL 数据库中运行集成测试；只有测试成功后，
Mac Runner 才会自动执行真实表的 plan、apply 和 verify。

## 运行条件

- Mac 必须开机且不能处于睡眠状态。
- PostgreSQL 和 `gitlab-runner` 后台服务必须运行。
- Runner 必须带 `db-maintenance` tag。
- Runner 的 `Run untagged jobs` 必须关闭，避免接收没有明确 tag 的其他任务。
- GitLab 项目中的 Instance runners 建议关闭，确保所有 Job 只使用本机 Runner。
- shell Runner 只允许默认分支运行；不要让 fork 或未审查的 Merge Request 使用它。
- 本地 PostgreSQL 不需要暴露到公网。
- 首次真实清理建议把 `MAX_DELETE_ROWS` 和 `BATCH_SIZE` 设置得较小。
