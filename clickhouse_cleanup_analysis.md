# `clickhouse_cleanup.sh` 脚本分析文档

## 1. 文档目的

本文档用于系统性说明 [`clickhouse_cleanup.sh`](/root/shell/clickhouse_cleanup.sh) 的用途、执行流程、核心 SQL、运行条件、实际行为、风险点以及改进建议，便于后续维护、审计和交接。

## 2. 脚本定位

脚本是一个面向 Kubernetes 环境的 ClickHouse 运维清理脚本，核心工作方式是：

1. 使用 `kubectl` 连接集群。
2. 找到指定命名空间中运行中的 ClickHouse Pod。
3. 通过 `kubectl exec` 进入 Pod 内部。
4. 调用 `clickhouse-client` 执行统计 SQL、删除 SQL，以及可选的 `OPTIMIZE TABLE`。
5. 将过程日志写入本地日志目录。

脚本头部说明可见 [`clickhouse_cleanup.sh:4`](/root/shell/clickhouse_cleanup.sh#L4) 到 [`clickhouse_cleanup.sh:18`](/root/shell/clickhouse_cleanup.sh#L18)。

## 3. 配置项说明

主要配置位于 [`clickhouse_cleanup.sh:20`](/root/shell/clickhouse_cleanup.sh#L20) 到 [`clickhouse_cleanup.sh:37`](/root/shell/clickhouse_cleanup.sh#L37)。

### 3.1 Kubernetes 与 ClickHouse 连接配置

- `NAMESPACE="deepflow"`
  - 目标命名空间。
- `CLICKHOUSE_POD_PREFIX="master-deepflow-clickhouse"`
  - Pod 名称前缀，脚本会用此前缀匹配运行中的 Pod。
- `CLICKHOUSE_CONTAINER="clickhouse"`
  - Pod 内的容器名。
- `CLICKHOUSE_USER="default"`
  - ClickHouse 用户名。
- `CLICKHOUSE_PASSWORD="YSDeepFlow@3q302"`
  - ClickHouse 密码。

### 3.2 日志与保留策略

- `LOG_DIR="/mnt/clickhouse_clean/log"`
  - 日志目录。
- `RETENTION_DAYS=1`
  - 配置说明为“保留数据天数”。

### 3.3 OPTIMIZE 策略配置

- `OPTIMIZE_INTERVAL_DAYS=7`
  - 两次 `OPTIMIZE` 之间的最小间隔。
- `OPTIMIZE_MIN_PARTS=10`
  - 触发 `OPTIMIZE` 的最小 active parts 数。
- `OPTIMIZE_ON_WEEKDAY=0`
  - 仅允许在周日执行，`0` 表示周日，`-1` 表示不限制。
- `ENABLE_SMART_OPTIMIZE=true`
  - 是否启用智能判断。

### 3.4 运行参数

- `FORCE_OPTIMIZE=false`
- `SKIP_OPTIMIZE=false`

这两个值由命令行参数覆盖，解析逻辑见 [`clickhouse_cleanup.sh:51`](/root/shell/clickhouse_cleanup.sh#L51) 到 [`clickhouse_cleanup.sh:87`](/root/shell/clickhouse_cleanup.sh#L87)。

## 4. 命令行参数行为

支持以下参数：

- `--force-optimize`
  - 强制执行 `OPTIMIZE`，跳过智能判断。
- `--skip-optimize`
  - 完全跳过 `OPTIMIZE`。
- `--help` / `-h`
  - 显示帮助。

参数优先级体现在 [`clickhouse_cleanup.sh:245`](/root/shell/clickhouse_cleanup.sh#L245) 到 [`clickhouse_cleanup.sh:254`](/root/shell/clickhouse_cleanup.sh#L254)：

1. `--skip-optimize` 优先跳过。
2. `--force-optimize` 优先强制执行。
3. 其余情况再走智能判断。

## 5. 日志机制

日志逻辑见 [`clickhouse_cleanup.sh:89`](/root/shell/clickhouse_cleanup.sh#L89) 到 [`clickhouse_cleanup.sh:100`](/root/shell/clickhouse_cleanup.sh#L100)。

- 日志文件命名格式：
  - `cleanup_YYYYMMDD.log`
- 所有日志同时输出到标准输出和日志文件：
  - 使用 `tee -a`
- 错误日志会额外带 `[ERROR]` 标记。

## 6. 主流程分析

主流程位于 [`clickhouse_cleanup.sh:417`](/root/shell/clickhouse_cleanup.sh#L417) 到 [`clickhouse_cleanup.sh:469`](/root/shell/clickhouse_cleanup.sh#L469)。

实际执行顺序如下：

1. 记录任务开始和运行模式。
2. 检查 `kubectl` 是否安装且能连通集群。
3. 获取所有运行中的 ClickHouse Pod。
4. 逐个 Pod 执行清理。
5. 清理 7 天前日志文件。
6. 记录任务结束。

需要特别注意：

- `cleanup_data "${pod}"` 会执行。
- `optimize_tables "${pod}"` 当前被注释，不会执行。
- `generate_summary_report "${pod}"` 当前也被注释，不会执行。

对应位置：

- [`clickhouse_cleanup.sh:445`](/root/shell/clickhouse_cleanup.sh#L445)
- [`clickhouse_cleanup.sh:453`](/root/shell/clickhouse_cleanup.sh#L453)
- [`clickhouse_cleanup.sh:456`](/root/shell/clickhouse_cleanup.sh#L456)

这意味着脚本的“实际行为”与注释描述存在偏差：当前版本只做删除，不做表优化，也不输出摘要报告。

## 7. 环境检查逻辑

`check_kubectl()` 位于 [`clickhouse_cleanup.sh:102`](/root/shell/clickhouse_cleanup.sh#L102) 到 [`clickhouse_cleanup.sh:116`](/root/shell/clickhouse_cleanup.sh#L116)。

检查内容：

1. 本机是否存在 `kubectl` 命令。
2. `kubectl cluster-info` 是否可用。

失败则直接 `exit 1`。

这是合理的前置校验，但它只能证明集群连通，不保证：

- 命名空间存在。
- Pod 前缀匹配正确。
- 容器名正确。
- Pod 内部存在 `clickhouse-client`。
- ClickHouse 认证成功。

这些问题要等后续阶段才会暴露。

## 8. Pod 发现逻辑

`get_clickhouse_pods()` 位于 [`clickhouse_cleanup.sh:118`](/root/shell/clickhouse_cleanup.sh#L118) 到 [`clickhouse_cleanup.sh:132`](/root/shell/clickhouse_cleanup.sh#L132)。

处理方式：

1. 读取 `deepflow` 命名空间中 `Running` 状态的 Pod。
2. 提取 Pod 名称。
3. 用 `grep "^${CLICKHOUSE_POD_PREFIX}"` 按前缀过滤。

优点：

- 不依赖固定 Pod 名称。
- 能适配 StatefulSet 一类带序号的 Pod。

风险：

- 只靠名称前缀匹配，不够稳健。
- 如果有多个副本，会对每个 Pod 都执行一次相同删除逻辑。

如果底层表是本地表 `l7_flow_log_local`，逐 Pod 执行是合理的；如果实际访问的是共享逻辑对象，就可能产生重复操作或额外负载，需要结合集群拓扑确认。

## 9. SQL 执行封装

`execute_sql_on_pod()` 位于 [`clickhouse_cleanup.sh:134`](/root/shell/clickhouse_cleanup.sh#L134) 到 [`clickhouse_cleanup.sh:174`](/root/shell/clickhouse_cleanup.sh#L174)。

它做了三件事：

1. 动态拼接 `clickhouse-client` 命令。
2. 通过 `kubectl exec` 在目标容器中执行。
3. 按返回码记录成功或失败日志。

大致命令结构：

```bash
kubectl exec -n "${NAMESPACE}" "${pod_name}" \
  -c "${CLICKHOUSE_CONTAINER}" \
  -- bash -c "clickhouse-client --user=... --password=... --query=\"SQL\""
```

### 9.1 优点

- 复用了统一入口，后续 SQL 执行一致。
- 能把 ClickHouse 返回内容写入日志。

### 9.2 风险

- 用户名、密码直接拼进命令行。
- SQL 通过双引号嵌套拼接，包含特殊字符时容易出现转义问题。
- 成功日志会打印 SQL 结果，若结果过大，日志可能迅速膨胀。

## 10. 数据清理逻辑

`cleanup_data()` 位于 [`clickhouse_cleanup.sh:176`](/root/shell/clickhouse_cleanup.sh#L176) 到 [`clickhouse_cleanup.sh:238`](/root/shell/clickhouse_cleanup.sh#L238)。

这是脚本当前唯一实际执行的数据库操作。

### 10.1 目标表

只处理一张表：

- `flow_log.l7_flow_log_local`

### 10.2 清理前统计

第一段 SQL 查询 `system.parts`：

```sql
SELECT
    count(*) as will_delete_count,
    formatReadableSize(sum(data_uncompressed_bytes)) as will_delete_size
FROM system.parts
WHERE database = 'flow_log' AND table = 'l7_flow_log_local' AND active
```

这段 SQL 实际统计的是整张表的 active parts 数和未压缩大小，不是“将要删除的数据量”。

因此日志文案“统计待删除的数据量”并不准确。

第二段 SQL 才是在统计符合删除条件的记录数：

```sql
SELECT count(*) as matching_rows
FROM flow_log.l7_flow_log_local
WHERE time < now() - INTERVAL 1 DAY
  AND l7_protocol_str IN ('DNS', 'HTTP', 'MySQL', 'Redis', 'gRPC')
  AND (response_code = 200 OR response_code = 0 OR response_code IS NULL)
```

### 10.3 删除条件

实际删除语句：

```sql
ALTER TABLE flow_log.l7_flow_log_local
DELETE WHERE
    time < now() - INTERVAL 1 DAY
    AND l7_protocol_str IN ('DNS', 'HTTP', 'MySQL', 'Redis', 'gRPC')
    AND (
        response_code = 200
        OR response_code = 0
        OR response_code IS NULL
    )
```

业务含义如下：

1. 只删除 1 天前的数据。
2. 只删除以下协议：
   - `DNS`
   - `HTTP`
   - `MySQL`
   - `Redis`
   - `gRPC`
3. 只删除“正常响应”数据：
   - `response_code = 200`
   - `response_code = 0`
   - `response_code IS NULL`
4. 异常响应数据保留，用于排障分析。

### 10.4 删除方式

该语句是 ClickHouse `ALTER TABLE ... DELETE WHERE ...` 形式，属于 mutation 异步删除。

脚本本身也明确承认这一点：

- 提交删除后等待 5 秒。
- 然后查询 `system.mutations` 查看状态。

对应代码见：

- [`clickhouse_cleanup.sh:221`](/root/shell/clickhouse_cleanup.sh#L221)
- [`clickhouse_cleanup.sh:224`](/root/shell/clickhouse_cleanup.sh#L224)

### 10.5 删除状态查询

查询语句：

```sql
SELECT
    command,
    create_time,
    is_done,
    parts_to_do
FROM system.mutations
WHERE database = 'flow_log' AND table = 'l7_flow_log_local'
ORDER BY create_time DESC
LIMIT 5
```

这能看到 mutation 是否完成、还有多少 part 待处理。

## 11. OPTIMIZE 逻辑分析

`should_run_optimize()` 位于 [`clickhouse_cleanup.sh:240`](/root/shell/clickhouse_cleanup.sh#L240) 到 [`clickhouse_cleanup.sh:314`](/root/shell/clickhouse_cleanup.sh#L314)。

`optimize_tables()` 位于 [`clickhouse_cleanup.sh:316`](/root/shell/clickhouse_cleanup.sh#L316) 到 [`clickhouse_cleanup.sh:362`](/root/shell/clickhouse_cleanup.sh#L362)。

### 11.1 设计目标

从注释看，作者希望：

- 清理任务每天执行。
- `OPTIMIZE TABLE ... FINAL` 不每天执行。
- 只在必要时做重操作，减少资源消耗。

### 11.2 智能判断条件

智能判断顺序如下：

1. 如果 `--skip-optimize`，直接跳过。
2. 如果 `--force-optimize`，直接执行。
3. 如果 `ENABLE_SMART_OPTIMIZE != true`，跳过。
4. 如果当天不是 `OPTIMIZE_ON_WEEKDAY` 指定星期，跳过。
5. 如果距离上次执行未达到 `OPTIMIZE_INTERVAL_DAYS`，跳过。
6. 查询 `system.parts`，若 active parts 数小于 `OPTIMIZE_MIN_PARTS`，跳过。
7. 查询 `system.mutations`，若存在未完成 mutation，跳过。
8. 全部满足才执行。

### 11.3 `OPTIMIZE` 执行语句

```sql
OPTIMIZE TABLE flow_log.l7_flow_log_local FINAL
```

这是重量级操作，通常用于强制合并 parts、清理删除残留并释放空间。

### 11.4 执行完成后的处理

如果成功：

1. 记录耗时。
2. 将 Unix 时间戳写入 `${LOG_DIR}/.last_optimize`。
3. 再查询一次 `system.parts` 输出表状态。

### 11.5 当前实际状态

尽管逻辑完整，主流程中调用被注释：

```bash
#optimize_tables "${pod}"
```

因此当前版本不会实际执行 `OPTIMIZE`，即使传入 `--force-optimize` 也不会生效，因为主流程根本没有调用该函数。

这是脚本注释与运行行为不一致的最关键问题之一。

## 12. 摘要报告逻辑

`generate_summary_report()` 位于 [`clickhouse_cleanup.sh:364`](/root/shell/clickhouse_cleanup.sh#L364) 到 [`clickhouse_cleanup.sh:408`](/root/shell/clickhouse_cleanup.sh#L408)。

设计上它会输出三类信息：

1. 当前表状态。
2. 最近 mutation 状态。
3. 磁盘使用情况。

但主流程中的调用同样被注释，因此默认不会输出。

## 13. 日志清理逻辑

`cleanup_old_logs()` 位于 [`clickhouse_cleanup.sh:410`](/root/shell/clickhouse_cleanup.sh#L410) 到 [`clickhouse_cleanup.sh:415`](/root/shell/clickhouse_cleanup.sh#L415)。

逻辑很简单：

```bash
find "${LOG_DIR}" -name "cleanup_*.log" -mtime +7 -delete
```

即删除 7 天前的历史日志。

## 14. 当前脚本的实际行为总结

结合主流程，当前脚本运行时的真实行为是：

1. 检查 `kubectl`。
2. 找出运行中的 ClickHouse Pod。
3. 对每个匹配 Pod：
   - 统计全表 active parts 和容量。
   - 统计满足条件的历史行数。
   - 提交一次异步 `ALTER TABLE ... DELETE WHERE ...`。
   - 等待 5 秒后查询 mutation 状态。
4. 不执行 `OPTIMIZE`。
5. 不生成摘要报告。
6. 清理 7 天前日志。

## 15. 发现的问题与风险

以下问题是阅读脚本后确认存在的，建议优先关注。

### 15.1 明文密码硬编码

位置：[`clickhouse_cleanup.sh:25`](/root/shell/clickhouse_cleanup.sh#L25)

风险：

- 凭据暴露在脚本文件中。
- 任何能读取脚本的人都能直接获得数据库密码。
- 凭据还会出现在进程命令行拼接中，存在二次泄露风险。

建议：

- 改为环境变量、Kubernetes Secret、挂载配置文件或 `clickhouse-client` 配置文件。

### 15.2 `RETENTION_DAYS` 配置未真正生效

位置：

- 配置定义见 [`clickhouse_cleanup.sh:27`](/root/shell/clickhouse_cleanup.sh#L27)
- 实际删除条件见 [`clickhouse_cleanup.sh:197`](/root/shell/clickhouse_cleanup.sh#L197) 和 [`clickhouse_cleanup.sh:206`](/root/shell/clickhouse_cleanup.sh#L206)

问题：

- 脚本定义了 `RETENTION_DAYS=1`。
- 也计算了 `cutoff_date`。
- 但 SQL 中并没有使用 `${RETENTION_DAYS}` 或 `cutoff_date`。
- 删除条件被写死为 `INTERVAL 1 DAY`。

影响：

- 运维人员即使修改 `RETENTION_DAYS`，实际删除范围仍然是 1 天前数据。
- 配置与行为不一致，容易引发误操作。

### 15.3 `cutoff_date` 变量只计算未使用

位置：[`clickhouse_cleanup.sh:179`](/root/shell/clickhouse_cleanup.sh#L179)

问题：

- 变量只用于日志文案。
- 实际 SQL 完全没引用。

这说明脚本可能经历过中途修改，存在“配置未完全接线”的情况。

### 15.4 `OPTIMIZE` 功能当前失效

位置：[`clickhouse_cleanup.sh:453`](/root/shell/clickhouse_cleanup.sh#L453)

问题：

- `optimize_tables` 调用被注释。
- 所有 `--force-optimize`、`--skip-optimize`、智能判断逻辑实际上都不会影响运行结果。

影响：

- 用户以为脚本支持条件性优化，实际不支持。
- 删除 mutation 完成后不会自动释放空间或合并 parts。

### 15.5 摘要报告功能当前失效

位置：[`clickhouse_cleanup.sh:456`](/root/shell/clickhouse_cleanup.sh#L456)

问题：

- `generate_summary_report` 调用也被注释。

影响：

- 脚本虽然定义了摘要报告，但默认日志里拿不到收尾状态。

### 15.6 “待删除数据量”统计文案不准确

位置：[`clickhouse_cleanup.sh:185`](/root/shell/clickhouse_cleanup.sh#L185) 到 [`clickhouse_cleanup.sh:193`](/root/shell/clickhouse_cleanup.sh#L193)

问题：

- SQL 查的是 `system.parts` 中整张表 active parts 的总量和总大小。
- 这不是待删除数据量。

影响：

- 日志容易误导读者，以为已经算出要删多少空间。

### 15.7 多 Pod 场景下操作范围需要确认

位置：[`clickhouse_cleanup.sh:441`](/root/shell/clickhouse_cleanup.sh#L441) 到 [`clickhouse_cleanup.sh:459`](/root/shell/clickhouse_cleanup.sh#L459)

问题：

- 脚本会对每个匹配 Pod 执行一次删除。
- 是否应全量遍历每个 Pod，取决于 `l7_flow_log_local` 在集群中的分布方式。

如果这是每个副本节点的本地表，这样做是合理的。
如果不是，则可能带来重复 mutation 或不必要的执行开销。

### 15.8 缺少更严格的失败控制

问题：

- 脚本没有启用 `set -euo pipefail`。
- 某个 Pod 的清理失败后，主流程不会立即停止，而是继续处理后续 Pod。

这未必是错误，但属于“失败容忍策略未显式说明”。

运维上需要明确：

- 是希望“单 Pod 失败不影响其他 Pod”。
- 还是希望“任何失败都立即退出并告警”。

### 15.9 参数与注释存在行为偏差

头部注释说明：

- 普通执行会“智能判断是否 `OPTIMIZE`”。
- `--force-optimize` 会强制执行 `OPTIMIZE`。
- `--skip-optimize` 会跳过 `OPTIMIZE`。

但当前真实行为不是这样，因为主流程不调用 `optimize_tables()`。

这是文档和代码不一致问题。

## 16. 适用场景判断

该脚本适合以下场景：

- Kubernetes 中运行 ClickHouse。
- 需要定时删除 `flow_log.l7_flow_log_local` 中较老且“正常响应”的 L7 日志。
- 希望保留异常响应数据用于问题排查。
- 希望通过外部 crontab 调度，而不是依赖集群内 Job。

不适合或需谨慎使用的场景：

- 不能接受明文凭据。
- 需要严格参数化保留天数。
- 需要强一致的失败控制。
- 需要真正启用自动 `OPTIMIZE`。

## 17. 改进建议

按优先级排序如下。

### 17.1 高优先级

1. 移除明文密码。
2. 将删除 SQL 改为真正使用 `RETENTION_DAYS`。
3. 明确主流程是否应该启用 `optimize_tables`。
4. 明确主流程是否应该启用 `generate_summary_report`。
5. 修正文案，区分“全表状态统计”和“待删除数据统计”。

### 17.2 中优先级

1. 使用 label selector 替代 Pod 名前缀匹配。
2. 对 ClickHouse 连通性做显式检查，例如执行 `SELECT 1`。
3. 统一错误处理策略，明确失败后是否中断。
4. 对 SQL 执行进行更稳妥的转义处理。

### 17.3 低优先级

1. 输出更结构化的执行摘要。
2. 将日志目录、日志保留天数也参数化。
3. 增加 dry-run 模式，只统计不删除。

## 18. 结论

`clickhouse_cleanup.sh` 是一个结构上相对清晰的 ClickHouse 清理脚本，核心目标明确：删除 `flow_log.l7_flow_log_local` 中 1 天前、特定协议、正常响应的历史数据，并为后续 `OPTIMIZE` 预留了完整逻辑。

但从当前版本的真实执行情况看，它存在几个重要偏差：

1. `RETENTION_DAYS` 配置并未真正作用到删除 SQL。
2. `OPTIMIZE` 逻辑虽然写好了，但实际上没有执行。
3. 摘要报告逻辑也没有执行。
4. 存在明文密码这一明显安全问题。

如果只是短期应急清理，这个脚本可以工作。
如果要作为长期生产运维脚本，建议至少先修复上述四点，再投入持续使用。
