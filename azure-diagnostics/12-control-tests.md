# 12 — Control Tests: Isolating Engine × Path × Auth × HA

> **Scope:** Complete test matrix to separate the four variables contributing to the 6K RPS plateau

---

## The 2×2 Matrix: Engine × Path

| | **Fast path** (IaaS VM, co-located VNet) | **Managed path** (PaaS, Private Endpoint) |
|---|---|---|
| **Oracle** | 15K ✅ (known) | — (not tested) |
| **PostgreSQL** | 15K ✅ (known) | **⬜ MISSING — highest priority to fill** |
| **SQL Server** | ~11.5K (known) | **6K ❌ (the problem)** |

Filling the PostgreSQL PaaS cell isolates whether the ceiling is:
- **Engine-specific** (SQL Server + mssql-jdbc characteristics), or
- **Path-specific** (PaaS managed service network/commit overhead), or
- **Both**

---

## Control Test 1: Azure PostgreSQL PaaS via RHBK

### Why this is the highest-priority control test

- PostgreSQL already hit 15K on IaaS → the engine and Keycloak Postgres driver are validated.
- Running it on Azure Database for PostgreSQL (Flexible Server) changes ONLY the path variable.
- If PostgreSQL PaaS hits near 15K, the bottleneck is **SQL Server + mssql-jdbc specific**.
- If PostgreSQL PaaS also plateaus at 6–8K, the bottleneck is the **PaaS managed path** (commit latency, network hop, or app-side amplification above a latency threshold).

### Setup

1. Provision **Azure Database for PostgreSQL - Flexible Server**:
   - SKU: comparable vCores to your Hyperscale (e.g., 64 vCores Business Critical)
   - Region: same region as ARO
   - **Zone redundancy**: enable for a fair comparison (same HA level as SQL Hyperscale)
   - Private Endpoint: same VNet as ARO
   - Auth: PostgreSQL password auth (default)

2. Configure RHBK to use the PostgreSQL datasource:
   ```
   quarkus.datasource.jdbc.url=jdbc:postgresql://<pgserver-placeholder>.postgres.database.azure.com:5432/<db-placeholder>?sslmode=require
   quarkus.datasource.username=<pguser-placeholder>@<pgserver-placeholder>
   quarkus.datasource.******
   ```

3. Run the identical load test (same VUs, same RPS target, same duration).

### Metrics to compare (identical set to SQL PaaS run)

| Metric | SQL PaaS result | PostgreSQL PaaS result | Conclusion |
|---|---|---|---|
| Max sustained RPS | 6K | ? | |
| `getConnection()` latency P99 | ~300 ms | ? | |
| Active transactions at peak | ~40 | ? | |
| Idle-in-transaction count | ~3,109 | ? | |
| Commit latency (WAL flush) | WRITELOG ~3 ms | pg_stat_bgwriter / latency | |
| Exponential degradation? | Yes | ? | |

If PostgreSQL PaaS shows the same exponential degradation and idle-in-transaction accumulation, the root cause is the **app-side feedback loop under PaaS latency** (retry spiral, in-memory lock contention, thread pool exhaustion), not the SQL Server engine specifically.

---

## Control Test 2: Zone Redundancy ON vs OFF

### Purpose
Isolate the cost of the cross-AZ synchronous commit acknowledgement.

### Setup
1. Create a **second Azure SQL Hyperscale** database (same SKU, same region):
   - Zone redundancy: **DISABLED**
   - Everything else identical: Private Endpoint, same VNet, Redirect, same schema.
2. Point RHBK at the non-zone-redundant instance.
3. Run the identical load test.

### What to measure

| | Zone Redundancy ON | Zone Redundancy OFF |
|---|---|---|
| Max sustained RPS | 6K | ? |
| WRITELOG avg_wait_ms | ~3 ms | ? (expect < 0.5 ms) |
| Idle-in-transaction count | ~3,109 | ? |
| Active transactions at peak | ~40 | ? |

**Expected outcome if zone redundancy is the bottleneck:**
- Zone redundancy OFF shows significantly higher throughput (approaches SQL IaaS result of 11.5K).
- WRITELOG avg_wait_ms drops to < 0.5 ms.

**Expected outcome if zone redundancy is NOT the bottleneck:**
- Similar plateau at 6K with zone redundancy OFF.
- Root cause is elsewhere (Entra auth, NSG blocking Redirect ports, app-side amplification).

### Note on production implications
If zone redundancy is mandatory for business continuity, this test still provides the data needed to **quantify the trade-off** and potentially justify batched commits, async session persistence, or a Postgres migration.

---

## Control Test 3: SQL Auth vs Entra Auth Comparison

### Purpose
Isolate the cost of Entra ID authentication on connection establishment.

See `09-auth-comparison.md` for full details.  Summary:

| | SQL Auth | Entra Auth |
|---|---|---|
| New connection latency | TCP + TLS + TDS = ~5-10 ms | TCP + TLS + TDS + MSAL = ~50-200 ms (cache miss) |
| Pool reuse latency | `sp_reset_connection` ~1 ms | Same (token already cached) |
| Getconnection P99 | ? | ~300 ms observed |

**Test:** configure RHBK datasource with SQL auth credentials, run the same load test.
- If P99 `getConnection()` drops from 300 ms to < 10 ms → Entra auth is the dominant cost.
- If P99 stays near 300 ms → the cost is not auth; it is pool queue wait or connection establishment.

---

## Control Test 4: Direct Database Benchmark (HammerDB / pgbench)

### Purpose
Establish the **raw database throughput ceiling** without any application in the middle.  This answers: "Is the database itself capable of 15K TPS if given clean OLTP workload?"

### Why this matters
If the database cannot sustain 15K TPS even with a direct benchmark, the ceiling is the database. If it CAN sustain 15K TPS directly, the bottleneck is in the application layer or the app→DB interaction pattern.

### HammerDB setup for Azure SQL Hyperscale

1. Deploy a test VM in the **same VNet as ARO** (to use the same Private Endpoint path).
2. Install HammerDB (download from [HammerDB GitHub](https://github.com/TPC-Council/HammerDB)):
   ```bash
   # Example on RHEL/Rocky:
   wget https://github.com/TPC-Council/HammerDB/releases/download/v4.x/HammerDB-4.x-Linux.tar.gz
   tar xzf HammerDB-4.x-Linux.tar.gz
   cd HammerDB-4.x
   ```
3. Configure TPC-C against your Hyperscale database:
   - Warehouses: 100 (adjust to get ~15K TPS)
   - Virtual users: 50 (scale up as needed)
   - Database: SQL Server / Azure SQL target
   - Connection: same Private Endpoint, SQL auth (to isolate from Entra)

4. Record:
   - **NOPM** (New Orders Per Minute): divide by 60 for TPS
   - **TPM** (Transactions Per Minute): the broader throughput
   - WRITELOG avg_wait_ms from the SQL DMVs during the HammerDB run

### Expected outcome
- If HammerDB achieves >> 15K TPS → database is NOT the bottleneck; the application interaction pattern is.
- If HammerDB also plateaus at 6K TPS → the database (or path) IS the ceiling; investigate WRITELOG, page server reads, NSG ports.

---

## Control Test 5: IaaS SQL Server Direct Comparison (Parity Check)

### Purpose
The IaaS SQL Server reached 11.5K (not 15K).  This gap between SQL IaaS (11.5K) and Oracle/Postgres IaaS (15K) suggests SQL Server / mssql-jdbc has inherent overhead even on the fast path.  Quantify this overhead before attributing all of the 6K vs 15K delta to PaaS.

### Variables to check on IaaS SQL Server

1. **`sp_reset_connection` on every pool borrow** — mssql-jdbc calls this on every connection reuse; verify with Extended Events.  PostgreSQL driver does not have an equivalent.
2. **Unicode/nvarchar conversion** — if RHBK sends `sendStringParametersAsUnicode=true` (default) to a database with `varchar` columns, every string comparison causes an implicit conversion (no index use).  Check execution plans for `CONVERT_IMPLICIT`.
3. **SET options mismatch** — mssql-jdbc sets ANSI_NULLS, QUOTED_IDENTIFIER, etc. on connection; if these differ from the table's index creation settings, index seeks may degrade to scans.
4. **Cursor-based operations** — some ORM patterns on SQL Server open server-side cursors; each cursor operation is multiple round-trips vs a single round-trip on Postgres.

### Query to detect implicit conversions (IaaS or PaaS)

```sql
-- Find queries with CONVERT_IMPLICIT in execution plan (index seek bypass)
SELECT TOP 20
    qt.query_sql_text,
    qp.query_plan,
    qrs.count_executions,
    qrs.avg_duration / 1000.0 AS avg_duration_ms
FROM sys.query_store_query       AS q
JOIN sys.query_store_query_text  AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan        AS qp ON q.query_id      = qp.query_id
JOIN sys.query_store_runtime_stats AS qrs ON qp.plan_id   = qrs.plan_id
JOIN sys.query_store_runtime_stats_interval AS rsi
     ON qrs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE '%CONVERT_IMPLICIT%'
  AND rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())
ORDER BY qrs.count_executions DESC;
```

---

## Test Matrix Summary

| Control Test | Variable Isolated | Expected insight |
|---|---|---|
| **Azure PostgreSQL PaaS** | Engine vs Path | If ~15K: SQL Server specific. If ~6K: PaaS path/app spiral |
| **Zone redundancy OFF** | HA replication latency | If improves significantly: zone redundancy is the commit tax |
| **SQL auth vs Entra auth** | Auth handshake latency | If improves significantly: MSAL token cost in `getConnection()` |
| **HammerDB direct** | App vs database ceiling | If DB handles >> 15K: bottleneck is app interaction pattern |
| **IaaS SQL Server parity** | SQL Server engine overhead | Quantifies the 11.5K vs 15K gap (engine vs Oracle/Postgres) |

Run these tests in the order listed — each result narrows the hypothesis space before you run the next.
