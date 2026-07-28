# Azure SQL Hyperscale Diagnostic Toolkit for RHBK 26 @ 15K RPS

> **Target scenario:** RHBK 26 (Keycloak) under 15K RPS load test on OpenShift (ARO)  
> **Database:** Azure SQL Hyperscale · 128 vCores · Premium-series hardware  
> **Connectivity:** Private Endpoint in the ARO VNet · Redirect policy · Ports 11000–11999 required  
> **HA:** Zone redundancy enabled (multi-AZ synchronous commit)  
> **Auth:** Mixed auth — Microsoft Entra ID (Azure AD) and SQL authentication  
> **Symptom:** Throughput plateaus at ~6K RPS; Oracle and Postgres IaaS reach 15K ✅

---

## 1. Context and the 2×2 Matrix

The performance investigation covers four test scenarios differing on two axes:

| | **Fast path** (IaaS VM) | **Managed path** (Azure PaaS) |
|---|---|---|
| **Oracle** | **15K ✅** | — |
| **PostgreSQL** | **15K ✅** | **⬜ Missing — highest-priority control test** |
| **SQL Server** | **~11.5K** | **6K ❌ — this scenario** |

The missing cell (Azure PostgreSQL PaaS) is the single most important experiment because it isolates **engine vs path**:
- PostgreSQL PaaS near 15K → the bottleneck is SQL Server / mssql-jdbc specific.
- PostgreSQL PaaS also plateaus at 6K → the bottleneck is the PaaS network path triggering an app-side amplification effect.

### Additional variables in the Azure SQL PaaS scenario

| Variable | Value | Why it matters |
|---|---|---|
| Hyperscale architecture | 128 vCores Premium-series | Log writes go to a remote Log Service (not local disk); WRITELOG wait includes network latency |
| Zone redundancy | Enabled | Every COMMIT waits for synchronous acknowledgement from a replica in a different Availability Zone (+1–5 ms/commit) |
| Connection policy | Redirect | JDBC driver connects to SQL gateway on :1433, then redirects to compute node on :11000–11999; if those ports are blocked, falls back to slower Proxy mode |
| Private Endpoint | Same VNet as ARO | Ideal path (no public internet); DNS must resolve via Private DNS Zone |
| Mixed auth | Entra ID + SQL auth | Entra auth adds MSAL token acquisition to connection establishment (~50–200 ms on cache miss) |

---

## 2. Observed Symptoms

| Symptom | Observed value | Significance |
|---|---|---|
| Max sustained RPS | ~6,000 | Plateau, not gradual degradation |
| Active SQL transactions | ~40 | Impossibly low for 6K RPS workload |
| Idle-in-transaction sessions | ~3,109 | Connections hold open transactions while doing nothing |
| `getConnection()` latency | ~300 ms | Something is very slow in connection acquisition or establishment |
| CPU on the database | Low | Database is NOT saturated; bottleneck is elsewhere |
| Blocking / lock waits | Unknown | To determine — run `04-lock-contention.sql` |
| WRITELOG wait avg | Unknown | To determine — run `03-commit-latency.sql` |

The combination of **low CPU + low active transactions + high idle-in-transaction + high getConnection latency** points to either:
1. **Connection pool exhaustion** — pool is full, app threads queue waiting for a connection.
2. **Zone-redundant commit latency** — each commit takes 3–5 ms, saturating the pool's worth of connections at a fraction of the target RPS.
3. **App-side feedback loop** — retry spiral or in-memory lock contention amplified by PaaS latency.

See `09-auth-comparison.md` and `12-control-tests.md` for how to isolate which one.

---

## 3. Files in This Toolkit

| File | What it does |
|---|---|
| `01-transactions-and-sessions.sql` | Active vs idle-in-transaction sessions; identify RHBK connections |
| `02-wait-stats.sql` | Global and per-session wait statistics (Hyperscale-specific + zone-redundancy waits) |
| `03-commit-latency.sql` | WRITELOG, HADR*, RBIO* waits — measures the zone-redundancy commit tax |
| `04-lock-contention.sql` | Blocking chains, LCK* waits, row-level lock hotspots |
| `05-workers.sql` | Worker thread utilization vs the 128-vCore limit |
| `06-transaction-age.sql` | Transaction age distribution, ADR persistent version store |
| `07-top-queries.sql` | Top queries from plan cache + Query Store with wait types per query |
| `08-extended-events.sql` | Round-trip counter, login cost measurement, `sp_reset_connection` timing |
| `09-auth-comparison.md` | Entra vs SQL auth comparison guide and test methodology |
| `10-network-connectivity.md` | Redirect + Private Endpoint checks, NSG rules, latency decomposition |
| `11-hyperscale-zone-redundancy.md` | Hyperscale architecture, zone-redundancy mechanics, monitoring guidance |
| `12-control-tests.md` | Control test matrix (PostgreSQL PaaS, zone redundancy OFF, HammerDB, auth) |

---

## 4. Priority Execution Order (Diagnostic Window)

Run these steps in order.  Each result either **confirms** a hypothesis (stop and fix) or **eliminates** it (continue to next).

### Step 1 — Establish the connection breakdown (5 minutes)
**Run:** `08-extended-events.sql` Section A (create + start) **before** the load test.  
**Read:** Section D (login events) immediately after a burst of logins.  
**Determines:** How long does connection establishment take? Is it TCP+TLS (fast) or MSAL (slow)?  
**If avg_login_ms > 50 ms** → Entra auth is likely the `getConnection()` cost. See `09-auth-comparison.md`.  
**If avg_login_ms < 10 ms** → Auth is not the issue; getConnection delay is pool queue wait.

### Step 2 — Snapshot wait stats at peak (2 minutes)
**Run:** `02-wait-stats.sql` Section A at idle (baseline), then again at peak load.  
**Determines:** What is the database waiting on?  
**If WRITELOG dominates** → zone-redundant commit latency is the ceiling. Run `03-commit-latency.sql`.  
**If LCK_M_X dominates** → row-level lock contention on session tables. Run `04-lock-contention.sql`.  
**If THREADPOOL non-zero** → worker threads exhausted. Run `05-workers.sql`.  
**If all waits are low** → bottleneck is NOT in the database; diagnose the app side (thread dump).

### Step 3 — Measure commit latency (2 minutes)
**Run:** `03-commit-latency.sql` at peak load.  
**Determines:** What is the WRITELOG avg_wait_ms?  
**If avg WRITELOG > 2 ms** → zone-redundancy is the commit tax. Compare against a zone-redundancy-OFF instance (see `12-control-tests.md`).  
**If avg WRITELOG < 1 ms** → zone redundancy is not the bottleneck; look at Redirect policy and NSG.

### Step 4 — Check Redirect policy (1 minute)
**Run:** `10-network-connectivity.md` Section 1.2 (query local_tcp_port).  
**Determines:** Is Redirect working?  
**If port is NOT in 11000–11999** → Proxy mode is in use; check NSG allows 11000–11999. Fix the NSG.  
**If port is in 11000–11999** → Redirect is working. The network path is not the issue.

### Step 5 — Count idle-in-transaction and active sessions (1 minute, repeat every 30s)
**Run:** `01-transactions-and-sessions.sql` Section C.  
**Determines:** Is the idle-in-transaction count growing or stable?  
**If growing** → the app is opening transactions faster than it is committing them (pool exhaustion or commit latency is worse than thought).  
**If stable** → the system has found a steady state, even if suboptimal.

### Step 6 — Check lock contention (2 minutes)
**Run:** `04-lock-contention.sql` Sections A and E.  
**Determines:** Are blocked sessions present?  
**If blocking chain with WRITELOG on head-blocker** → a committing session is holding a lock, backed up by zone-redundant commit latency. Confirms Steps 2 + 3 finding.  
**If LCK_M_X is the head wait and no WRITELOG** → pure row-level lock serialization on Keycloak session table.

### Step 7 — Round-trip count per transaction (5 minutes, targeted trace)
**Run:** `08-extended-events.sql` Sections B and C during a targeted single-login test.  
**Determines:** How many SQL round-trips does one RHBK login generate?  
**If round-trip count is high (> 10 per login)** → N+1 query problem in Keycloak SQL layer. Each round-trip at 3 ms × N = compounded latency.  
**If round-trip count is low (< 5 per login)** → the per-round-trip latency is the dominant cost, not the count.

### Step 8 — Run control tests to isolate variables
**Run:** `12-control-tests.md` in priority order (PostgreSQL PaaS first, then zone redundancy OFF).

---

## 5. Symptom → Action → Conclusion Table

| Symptom | What to run | What it proves |
|---|---|---|
| `getConnection()` ~300 ms | `08-extended-events.sql` login events | If avg_login_ms > 50 ms → Entra auth handshake; if < 10 ms → pool queue wait |
| Idle-in-transaction ~3,000+ | `01-transactions-and-sessions.sql` Section B | Confirms transactions are open but not progressing — app is stalled before commit |
| Active transactions ~40 | `01-transactions-and-sessions.sql` Section C | Pool or commit bottleneck — max concurrent commits = pool_size × (1000/commit_latency_ms) |
| Low DB CPU | `05-workers.sql` + Azure Monitor CPU | Confirms DB is not saturated; bottleneck is connectivity/latency/lock, not computation |
| WRITELOG wait high | `03-commit-latency.sql` Section A | Zone-redundant commit is the throughput ceiling |
| WRITELOG avg > 2 ms | `03-commit-latency.sql` + `12-control-tests.md` Test 2 | Test zone redundancy OFF; if RPS improves → cross-AZ sync commit is the ceiling |
| RBIO* waits present | `03-commit-latency.sql` Section C | Hyperscale log service backpressure (log rate throttling) |
| Blocking chain present | `04-lock-contention.sql` Section A | Lock contention — identify head-blocker and whether it is waiting on WRITELOG |
| LCK_M_X dominates | `04-lock-contention.sql` Sections B+C | Row-level lock serialization on Keycloak session table |
| THREADPOOL non-zero | `05-workers.sql` Section D | Worker threads exhausted — reduce connection count or commit latency |
| Workers % > 80 | `05-workers.sql` Section B + Azure Monitor | Worker saturation — DB is the bottleneck |
| local_tcp_port = 1433 (not 11000+) | `10-network-connectivity.md` Section 1.2 | Redirect failed; NSG blocks 11000–11999; fix NSG to restore Redirect mode |
| DNS resolves to public IP | `10-network-connectivity.md` Section 3.2 | Private DNS Zone not linked to ARO VNet; SQL traffic bypasses Private Endpoint |
| Round-trips per login > 10 | `08-extended-events.sql` Section C | N+1 query pattern — each login generates too many SQL round-trips |
| Login_completed bimodal | `08-extended-events.sql` Section D | Entra token cache misses — MSAL calling out for new token intermittently |
| PostgreSQL PaaS also plateaus at 6K | `12-control-tests.md` Test 1 | PaaS path + app-side amplification; engine swap alone will not fix it |
| PostgreSQL PaaS hits ~15K | `12-control-tests.md` Test 1 | SQL Server engine / mssql-jdbc specific — migrate to PostgreSQL PaaS |
| Zone redundancy OFF improves RPS | `12-control-tests.md` Test 2 | Cross-AZ commit latency is the ceiling; accept trade-off or use batched/async commits |
| SQL auth shows same 300 ms | `09-auth-comparison.md` Test A vs B | Auth type is not the `getConnection()` cost; look at pool queue / TCP |
| SQL auth shows < 10 ms | `09-auth-comparison.md` Test A vs B | Entra auth is the `getConnection()` dominant cost; fix token caching or use Managed Identity |
| HammerDB achieves > 15K | `12-control-tests.md` Test 4 | DB itself is capable; bottleneck is in RHBK application interaction pattern |
| HammerDB also plateaus at 6K | `12-control-tests.md` Test 4 | DB or path IS the ceiling; focus on DB-side (log rate, NSG, zone redundancy) |

---

## 6. The "Application is Blind" Problem

Since Oracle and Postgres IaaS both reach 15K, the test harness and application configuration are known-good.  The failure is specific to **Azure SQL PaaS**.  This means:

1. **Application-side amplification effects** (retry spirals, in-memory lock contention, thread pool exhaustion) are being triggered by PaaS latency that did not exist on IaaS.
2. The database can be idle and the application can still plateau — **idle-in-transaction is the signal** that the app is stalled before reaching the commit, not after it.
3. Thread dumps from RHBK pods at peak (3–5 dumps, 10 seconds apart, 2–3 pods) are the complement to these SQL diagnostics.  They reveal WHERE the JVM is stalled:
   - `socketRead` / JDBC → waiting for the DB (latency / commit time)
   - `ReentrantLock` / Infinispan lock → in-memory lock held while waiting for slow DB round-trip
   - `park` in thread pool queue → worker pool exhausted
   - Infinispan JGroups RPC → cross-pod Infinispan sync under latency

**SQL diagnostics (this toolkit) + JVM thread dumps = complete diagnosis**.

---

## 7. Security Notes

- **No credentials are committed in this repository.** All connection strings use `<placeholder>` values.
- Store database credentials in Azure Key Vault; inject them into pods via Azure Workload Identity or ARO Secrets Store CSI Driver.
- The Extended Events session (08) captures SQL text and usernames; ensure the captured data complies with your data classification policies before storing to file target.
- Run diagnostic queries with a **read-only monitoring account** where possible; only the Extended Events CREATE/ALTER requires `ALTER ANY EVENT SESSION` privilege.

---

## 8. Glossary

| Term | Meaning |
|---|---|
| RHBK | Red Hat Build of Keycloak (= Keycloak) |
| ARO | Azure Red Hat OpenShift |
| Hyperscale | Azure SQL Hyperscale tier (remote log service + page servers architecture) |
| RBPEX | Resilient Buffer Pool Extension — local SSD cache on Hyperscale compute node |
| RBIO | Resilient Buffer I/O — Hyperscale log service interface; RBIO_* waits are Hyperscale-specific |
| WRITELOG | SQL Server wait type for transaction log flush (includes zone-redundant ack in Hyperscale) |
| Redirect | Azure SQL connection policy where JDBC connects directly to SQL compute node after initial handshake |
| Proxy | Azure SQL connection policy where all traffic routes through the Azure SQL gateway (higher latency) |
| Private Endpoint | Azure resource that exposes a PaaS service on a private IP in your VNet (no public internet) |
| Agroal | JDBC connection pool used by Quarkus (and RHBK) |
| MSAL | Microsoft Authentication Library — used by mssql-jdbc for Entra auth token acquisition |
| persistent-user-sessions | RHBK 26 feature that persists sessions synchronously to DB on every session event |
| idle-in-transaction | A database session in `sleeping` state with `open_transaction_count > 0` — transaction open, no command running |
| Zone redundancy | Hyperscale feature that replicates the log to multiple Azure Availability Zones; each commit waits for multi-zone ack |
