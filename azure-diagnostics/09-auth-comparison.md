# 09 — Mixed Auth: Entra ID vs SQL Authentication

> **Scope:** Azure SQL Hyperscale 128 vCores Premium-series · Private Endpoint · ARO pods (RHBK 26)

---

## Why This Matters

RHBK 26 is configured with **Mixed Auth** (Microsoft Entra ID and SQL authentication enabled simultaneously).  The Agroal JDBC pool can be using either credential type, and the type directly affects how long `getConnection()` takes.

| Auth type | What happens on every NEW physical connection |
|---|---|
| **SQL auth** | TCP → TLS → TDS Login7 → password hash exchange → auth complete |
| **Entra auth (Service Principal / Managed Identity)** | TCP → TLS → TDS Login7 → JDBC driver calls MSAL → MSAL contacts `login.microsoftonline.com` via HTTPS (or uses cached token) → returns token → TDS auth with token → auth complete |

The MSAL call to the Azure AD / Entra endpoint adds **at least one extra HTTPS round-trip** to an endpoint outside the VNet.  If the token is not cached or has expired, this adds 50–200 ms to every new connection.

---

## 1. Determine Which Auth RHBK Is Currently Using

### 1.1 Check the RHBK datasource configuration

In `standalone.xml` / WildFly subsystem / Quarkus properties, look for:

```
# Quarkus (quarkus.properties or env vars):
quarkus.datasource.username=<value>
quarkus.datasource.******

# OR Entra/MSI auth (typically via a custom credential provider):
quarkus.datasource.jdbc.url=jdbc:sqlserver://<server>.database.windows.net:1433;...;authentication=ActiveDirectoryServicePrincipal
```

If `authentication=ActiveDirectoryServicePrincipal`, `authentication=ActiveDirectoryMSI`, or `authentication=ActiveDirectoryDefault` appears in the JDBC URL, Entra auth is in use.

### 1.2 Check the Extended Events login events (script 08)

In the `login_completed` aggregation from Section D of `08-extended-events.sql`, the `username` column will show:
- A regular username string → SQL auth
- An Entra Object ID / service principal name → Entra auth

### 1.3 Check from the database side

```sql
-- Who is connecting and how?
SELECT
    s.session_id,
    s.login_name,
    s.auth_scheme,          -- 'SQL', 'NTLM', 'KERBEROS', 'FEDERATED'
    s.program_name,
    s.host_name,
    s.client_interface_name
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
ORDER BY s.session_id;
```

- `auth_scheme = 'SQL'`       → SQL authentication (password hash)
- `auth_scheme = 'FEDERATED'` → Entra / Azure AD token-based authentication
- `auth_scheme = 'KERBEROS'`  → Kerberos (Entra ID with Kerberos token)

---

## 2. Token Caching Behaviour

### 2.1 How the mssql-jdbc MSAL token cache works

The Microsoft JDBC Driver for SQL Server (mssql-jdbc) uses MSAL4J internally.  By default:

- **Cached token lifetime**: Entra access tokens for Azure SQL are valid for ~1 hour.
- **Cache scope**: The cache is **per connection pool / per JVM**.  Each RHBK pod has its own token cache.
- **Token refresh**: MSAL proactively refreshes tokens before expiry (typically 5 minutes before expiration).
- **New connection after token refresh**: If a pod's token expired and MSAL needs to get a new one, the next `getConnection()` call that creates a new physical connection will block for the MSAL HTTPS call duration.

### 2.2 Signs of token churn (bad caching)

- `avg_login_ms` in the Extended Events Section D is **bimodal**: some logins take < 10 ms (cache hit), others take > 100 ms (cache miss / token refresh).
- The bimodal pattern correlates with the Agroal pool's **connection creation rate** (connections evicted after `max-lifetime` or on error → new physical connection → potentially new token request).

### 2.3 How to verify token cache hits

Enable mssql-jdbc debug logging (temporarily, non-production):

```
# In logback.xml / Quarkus logging config:
<logger name="com.microsoft.aad.msal4j" level="DEBUG"/>
<logger name="com.microsoft.sqlserver.jdbc" level="DEBUG"/>
```

Look for:
- `Cache hit` or `Returning cached token` → token reused, no extra latency.
- `Acquiring token` or `Sending HTTPS request to` → MSAL is calling out → latency visible.

---

## 3. Comparative Benchmark: Entra vs SQL Auth

### 3.1 Test setup

Run two identical load tests against the same Hyperscale database, changing ONLY the authentication method.  Everything else (pool size, queries, workload) must be identical.

**Test A — SQL auth:**
```
quarkus.datasource.jdbc.url=jdbc:sqlserver://<server-placeholder>.database.windows.net:1433;\
  databaseName=<db-placeholder>;\
  encrypt=true;\
  trustServerCertificate=false;\
  loginTimeout=30;\
  applicationName=RHBK26-SQLAuth
quarkus.datasource.username=<sqluser-placeholder>
quarkus.datasource.******
```

**Test B — Entra Service Principal auth:**
```
quarkus.datasource.jdbc.url=jdbc:sqlserver://<server-placeholder>.database.windows.net:1433;\
  databaseName=<db-placeholder>;\
  encrypt=true;\
  trustServerCertificate=false;\
  authentication=ActiveDirectoryServicePrincipal;\
  loginTimeout=30;\
  applicationName=RHBK26-EntraAuth
quarkus.datasource.username=<client-id-placeholder>@<tenant-id-placeholder>
quarkus.datasource.******
```

> **Never commit real credentials.** Use environment variables or a secrets manager (Azure Key Vault) to inject the values at runtime.

### 3.2 Metrics to collect per test

| Metric | How to collect |
|---|---|
| `getConnection()` latency (P50, P95, P99) | Agroal metrics via Quarkus Micrometer or JMX |
| `login_completed` duration (avg, max) | Extended Events Section D (08-extended-events.sql) |
| `auth_scheme` distribution | SQL query above (Section 1.3) |
| Max sustained RPS before saturation | Load generator (Gatling / k6) |
| Idle-in-transaction count at peak | Script 01-transactions-and-sessions.sql Section C |
| WRITELOG wait avg ms | Script 03-commit-latency.sql Section A |

### 3.3 Interpreting the result

| Scenario | Conclusion |
|---|---|
| SQL auth `avg_login_ms` ≪ Entra auth | Entra auth handshake is contributing to `getConnection()` latency |
| SQL auth and Entra auth `avg_login_ms` are equal | Auth type is NOT the differentiator; look elsewhere (network, zone redundancy, app-side) |
| Both are high (> 50 ms) | The connection establishment cost is dominated by network/TLS, not auth type |

---

## 4. Mitigation Options (if Entra auth is the cost)

1. **Maximize pool reuse** — increase Agroal `max-lifetime` and reduce `idle-removal-timeout` so physical connections stay alive longer.  Fewer new connections = fewer MSAL calls.
2. **Use Managed Identity with workload identity** — Managed Identity tokens are obtained locally (from the IMDS endpoint on the node, not an external HTTPS call), which is lower latency than Service Principal + client secret.
3. **Pre-warm the token cache** — ensure at least one connection is established before the load test begins, so the first token is cached before traffic hits.
4. **Fall back to SQL auth for the load test** — use SQL auth to isolate whether Entra is the root cause, then address it separately in production.
5. **Increase connection pool min-size** — keep `min-size` connections always alive so the pool never drops to zero; a warm pool never needs to re-authenticate.

---

## 5. Agroal Pool Metrics Checklist

```
# Quarkus Micrometer / MicroProfile Metrics endpoints to watch:
agroal.datasource.acquire_count          # total getConnection() calls
agroal.datasource.creation_count         # new physical connections created (MSAL triggered on each)
agroal.datasource.leak_detection_count   # connections leaked (potential idle-in-transaction source)
agroal.datasource.destroy_count          # connections destroyed (→ creation_count = churn)
agroal.datasource.flush_count            # forced flushes (eviction storms)
agroal.datasource.reap_count             # connections reaped after idle timeout
agroal.datasource.timeout_count          # acquisition timeouts (= failed getConnection())
```

If `creation_count` is close to `acquire_count`, the pool is essentially stateless — every borrow creates a new physical connection → every borrow triggers a potential MSAL call → ~300 ms per `getConnection()`.

The fix is ensuring `creation_count ≪ acquire_count` (pool reuse is working).
