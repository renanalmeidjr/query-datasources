# 11 — Azure SQL Hyperscale & Zone Redundancy: Architecture and Impact

> **Scope:** Azure SQL Hyperscale 128 vCores Premium-series · Zone Redundancy enabled · RHBK 26 persistent-user-sessions

---

## 1. Hyperscale Architecture Overview

Azure SQL Hyperscale is fundamentally different from General Purpose or Business Critical:

```
┌────────────────────────────────────────────────────────────┐
│                  HYPERSCALE ARCHITECTURE                    │
│                                                             │
│  Primary Compute Node (128 vCores Premium-series)           │
│  ├── Local SSD buffer pool (RBPEX — Resilient Buffer Pool)  │
│  │   Cache: pages from page servers, hot working set        │
│  └── Log Service connection (writes go here first)          │
│                                                             │
│  Log Service (Shared, zone-aware)                           │
│  ├── Zone 1: Primary log replica ◄─── ALL commits go here  │
│  └── Zone 2/3: Secondary log replicas (zone redundancy)     │
│      Synchronous ack required before COMMIT returns  ←────  │
│                                                             │
│  Page Servers (separate from compute)                       │
│  ├── Page Server 1 (stores shard of database pages)         │
│  └── Page Server N (more shards)                            │
│      Reads for pages not in RBPEX go here (network I/O)     │
│                                                             │
│  Secondary Compute Replicas (optional, for read scale)      │
│  └── Each has own RBPEX; reads from page servers            │
└────────────────────────────────────────────────────────────┘
```

### Key differences from General Purpose / IaaS SQL Server

| Aspect | IaaS SQL Server / General Purpose | Hyperscale |
|---|---|---|
| Write path | Write to local disk | Write to Log Service (network) |
| Commit durability | Local SSD flush | Log Service write + zone-redundant ack |
| Page reads | Local buffer pool or disk | Local RBPEX or page server (network) |
| Storage limit | Predefined | Virtually unlimited (page servers scale) |
| Backup | Full/diff/log backups | Instant snapshot (no I/O impact) |
| WRITELOG wait | Disk flush latency | Log Service network latency |

---

## 2. Zone Redundancy and Its Impact on Commits

### 2.1 How zone redundancy works in Hyperscale

With zone redundancy **disabled** (default):
```
COMMIT → Log Service (single zone) → acknowledge → return to app
         ↑
         ~0.1-0.5 ms
```

With zone redundancy **enabled** (your configuration):
```
COMMIT → Log Service Zone 1 → replicate to Zone 2/3 → wait for ack → return to app
         ↑                     ↑
         ~0.1 ms               + 1-3 ms (cross-AZ network RTT on Azure)
```

**Total commit latency with zone redundancy**: approximately **1–5 ms per commit**.

### 2.2 How this interacts with RHBK 26 persistent-user-sessions

RHBK 26 with `persistent-user-sessions` enabled performs a **synchronous write to the database** for every session event:

| Operation | DB writes | Commits |
|---|---|---|
| User login | INSERT user session + INSERT offline session + INSERT tokens | 1–3 COMMITs |
| Token refresh | UPDATE session + UPDATE tokens | 1–2 COMMITs |
| User logout | DELETE session + DELETE tokens | 1 COMMIT |

At **15,000 RPS** (mostly logins + refreshes), the database receives **15,000–45,000 COMMITs per second**.

With zone redundancy at **3 ms per commit**:
- A single thread can issue at most **1000 ms / 3 ms = 333 commits/sec**.
- To achieve 15,000 commits/sec, you need at minimum **45 concurrent committing threads**.
- Each thread consumes one worker thread AND holds its SQL connection open during the commit wait.
- At 128 vCores, the worker limit is well above 45 — but the JDBC connection pool may run out of connections before the worker limit is reached.

**This is the mechanism behind the 6K RPS plateau:**
- At 6K RPS: ~18,000 commits/sec × 3 ms = ~54 concurrent connections just for commits.
- Adding more VUs doesn't help because the connections are stalled in WRITELOG, not in CPU or I/O — and the pool has a maximum.

### 2.3 Diagnostic query: measure commit latency under load

See `03-commit-latency.sql` — specifically Sections A (WRITELOG), B (HADR), and C (RBIO*).

**Interpretation:**
- `avg_wait_ms` on `WRITELOG` during load = per-commit zone-redundant replication latency.
- Compare to idle baseline. If it jumps from 0.1 ms (idle) to 3-5 ms (load), zone redundancy is the cost.

---

## 3. Hyperscale-Specific DMVs and Wait Types

### 3.1 RBIO* wait types (Hyperscale Log Service)

| Wait type | Meaning |
|---|---|
| `RBIO_RG_STORAGE` | Waiting for the Log Service storage layer to accept the log write |
| `RBIO_RG_DESTAGE` | Log destage to page servers from the Log Service |
| `RBIO_RG_FLUSH` | Log flush wait (similar to WRITELOG but at RBIO layer) |
| `RBIO_RG_REPLICATION` | Zone-redundant replication within the Log Service |

These are **not present** in General Purpose, Business Critical, or on-prem SQL Server.  Their presence confirms you are measuring Hyperscale-specific behavior.

### 3.2 PAGEIOLATCH* in Hyperscale context

In Hyperscale, `PAGEIOLATCH_*` waits are for **pages not in the local RBPEX cache** being fetched from a **page server** over the network.  Unlike on-prem where this means disk I/O, in Hyperscale it means a network round-trip to a page server (typically in the same Azure region, < 1 ms).

High `PAGEIOLATCH_*` under this workload suggests:
- The RHBK working set (session tables) is larger than the RBPEX cache.
- This is unlikely for 128 vCores Premium-series (RBPEX is large) for a pure OLTP session store.
- If it is high, it may indicate table bloat from idle-in-transaction connections that never clean up.

### 3.3 Useful DMVs in Hyperscale

```sql
-- 1. Check if page server reads are significant
SELECT
    page_server_reads,
    page_server_read_in_progress_count
FROM sys.dm_user_db_resource_governance;

-- 2. Check RBPEX (local SSD cache) hit rate
-- (If available in your version)
SELECT *
FROM sys.dm_db_page_buffer_distribution;

-- 3. Log write throughput (should show log service writes, not disk)
SELECT
    DB_NAME(database_id)    AS db_name,
    num_of_writes,
    num_of_bytes_written,
    io_stall_write_ms,
    io_stall_write_ms * 1.0 / NULLIF(num_of_writes, 0) AS avg_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL)
WHERE database_id = DB_ID();
```

### 3.4 Resource governance DMV (Hyperscale-specific)

```sql
-- Shows resource limits for this Hyperscale database.
-- Useful to understand vCore limits, worker limits, and log rate limits.
SELECT *
FROM sys.dm_user_db_resource_governance;
```

Key columns to check:
- `log_rate_kb_s`: Maximum log write rate in KB/s. If you are near this limit, log writes are being throttled.
- `max_session_percent`: Max sessions as % of limit. Cross-reference with `sys.dm_exec_sessions`.
- `max_workers_percent`: Max workers as % of limit. Cross-reference with `05-workers.sql`.

---

## 4. Azure Monitor Metrics for This Scenario

Navigate to: **Azure Portal → Azure SQL Database → Monitoring → Metrics**

### Critical metrics to track during load test

| Metric name | What it shows | Alert threshold for this scenario |
|---|---|---|
| **CPU percentage** | Compute utilization | If < 30% at 6K RPS → CPU is NOT the bottleneck |
| **Workers percentage** | Worker threads used / max | If climbing → thread pool pressure |
| **Sessions percentage** | Active sessions / max | If climbing → connection saturation |
| **Log write percentage** | Log write throughput / limit | If > 80% → log rate throttling |
| **Log write** (bytes/s) | Raw log throughput | Correlate with WRITELOG wait in T-SQL |
| **Data IO percentage** | Storage I/O usage | Should be low for OLTP session writes |
| **DTU percentage** (if DTU model) | N/A for vCore | Not applicable here |
| **Connection successful** | New connections per second | Spike = pool churn = Entra auth cost |
| **Connection failed** | Failed connection attempts | Any value > 0 needs investigation |
| **Deadlocks** | Deadlock count | Deadlocks = app not handling serialization correctly |
| **In-Memory OLTP storage %** | Only if In-Memory tables used | N/A for standard Keycloak schema |

### Setting up a monitoring dashboard

1. In Azure Portal, go to the SQL Database resource.
2. Click **Monitoring → Metrics**.
3. Add each metric above to a chart.
4. Set the time range to match the load test window (e.g., last 30 minutes).
5. Export to **Azure Monitor Workbook** for a shareable view.

---

## 5. Assessing the Zone Redundancy Trade-off

### 5.1 Test: disable zone redundancy temporarily

> **IMPORTANT:** Disabling zone redundancy on an existing Hyperscale database requires a **scale operation** (a short maintenance window, usually < 30 seconds for Hyperscale). It reduces the durability guarantee (single-zone instead of multi-zone).  Do this ONLY in a non-production / test environment.

If you can run the same load test against:
- **Zone redundancy ON** → current result (6K RPS plateau)
- **Zone redundancy OFF** → compare

A significant RPS improvement with zone redundancy OFF confirms the cross-AZ WRITELOG latency is the throughput ceiling.

### 5.2 Alternative: async session persistence

If zone redundancy is mandatory in production, consider:
1. **Batching commits** — accumulate multiple session writes and commit them together (reduces commit count per second).
2. **Async session persistence** — RHBK (Infinispan) can cache sessions in memory and flush asynchronously to the database. This decouples commit latency from user-facing response time.  Trade-off: potential session loss on pod crash.
3. **RHBK sticky sessions** — route each user to the same pod consistently, reducing cross-pod Infinispan sync and concentrating writes.
4. **Azure Postgres PaaS** — if zone redundancy commit latency is acceptable on Postgres PaaS (Postgres uses WAL with a different commit path), and the Keycloak Postgres driver is leaner than mssql-jdbc, the same workload may sustain higher throughput on Postgres PaaS with zone redundancy.

---

## 6. Summary: Zone Redundancy vs Throughput

```
                    Zone Redundancy OFF     Zone Redundancy ON
                    ────────────────────    ──────────────────
Commit latency      ~0.1-0.5 ms             ~2-5 ms  (cross-AZ ack)
Max commits/thread  ~2000/s                 ~200-500/s
Threads needed      ~8 for 15K commits/s   ~30-75 for 15K commits/s
Durability          Single zone             Multi-zone (survives AZ failure)
```

At 15K logins/second, each generating 1 commit, with zone redundancy ON at 3 ms per commit:
- You need **45 concurrent threads** doing nothing but committing.
- Agroal's pool must have ≥ 45 connections **available** at the moment of commit.
- If pool max-size is < 45, the pool becomes the ceiling before the DB does.
- If pool max-size is ≥ 45, the DB absorbs it — but WRITELOG avg_wait_ms will show 3 ms, and worker count will reflect the sustained load.
