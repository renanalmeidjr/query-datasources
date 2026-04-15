# ODBC Timeout in SSIS IR — Troubleshooting Guide

## Problem

ODBC connections time out after approximately 40–50 seconds when running SSIS packages in Azure-SSIS Integration Runtime (SSIS IR), even though the same packages execute successfully in Visual Studio (SSDT) on an Azure VM.

---

## Why this happens

Running in SSIS IR introduces factors that are not present in a local Visual Studio / Azure VM environment:

| Factor | Visual Studio on Azure VM | SSIS IR |
|---|---|---|
| Network path | Direct from VM to SQL endpoint | Through Azure IR infrastructure, potentially across VNets, private endpoints, and firewalls |
| DNS resolution | Uses VM-local resolver | Uses IR node resolver; may add latency for private DNS zones |
| Always Encrypted CMK access | Certificate in local store; instant | Azure Key Vault call over network; adds seconds per connection |
| Node cold-start | N/A | First execution on a new node may be slower (driver load, credential fetch) |
| Connection pooling | Visual Studio / dtexec reuses pools | IR worker process may establish new pools per execution |

These cumulative delays can push total connection + command setup time past the configured timeout thresholds.

---

## Timeout types to configure

ODBC connections in SSIS have **two independent timeout values**:

### 1. Connection Timeout (`Connection Timeout`)

Controls how long the driver waits to establish the TCP connection and complete the login handshake with SQL Server.

- Default: **30 seconds** (in most ODBC drivers)
- Symptom when exceeded: error during connection open, before any query runs

### 2. Command / Query Timeout (`CommandTimeout`)

Controls how long a query or statement can run before the driver cancels it.

- Default: **30 seconds** in SSIS ODBC components
- Symptom when exceeded: error during data flow execution, after connection is established
- Set via ODBC Destination / Source component property in SSIS, **not** in the connection string

> **Note:** A timeout at 40–50 seconds typically indicates the connection timeout is borderline (succeeds on fast networks, fails on slower IR paths) or a combination of connection establishment + initial command exceeds the limit.

---

## Recommended fixes

### Fix 1 — Increase Connection Timeout in connection string

Change `Connection Timeout=30;` to a higher value. For SSIS IR, **120 seconds** is a safe starting point:

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<db>;
Uid=<user>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
Connection Timeout=120;
```

### Fix 2 — Increase Command Timeout on SSIS components

In the SSIS package Data Flow:

1. Select the **ODBC Source** or **ODBC Destination** component
2. In Properties, find `CommandTimeout`
3. Set it to **120** (seconds) or higher

For ADO.NET Destination with ODBC provider, set the `CommandTimeout` property on the ADO.NET Connection Manager:

1. Right-click the connection manager → **Properties**
2. Set `CommandTimeout` to `120`

### Fix 3 — Enable connection retry / resilience

Add the `ConnectRetryCount` and `ConnectRetryInterval` keywords to the ODBC connection string to handle transient network issues in SSIS IR:

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<db>;
Uid=<user>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
Connection Timeout=120;
ConnectRetryCount=3;
ConnectRetryInterval=10;
```

### Fix 4 — Validate network path from SSIS IR

Run a test from the SSIS IR node to confirm connectivity:

1. Add a custom setup script or an **Execute Process Task** that runs:
   ```cmd
   sqlcmd -S tcp:<server>.database.windows.net,1433 -U <user> -P <password> -Q "SELECT 1" -l 120
   ```
2. Check the Azure-SSIS IR diagnostic logs for network latency indicators
3. If using Private Endpoints or VNet injection, verify DNS resolution returns the private IP (not the public endpoint)

### Fix 5 — Pre-warm Key Vault access (Always Encrypted)

When using Azure Key Vault for CMK, the first connection must fetch the key. This adds latency that does not occur with local certificate store access.

Mitigations:
- Ensure the SSIS IR managed identity (or service principal) has **direct** Key Vault access (no additional proxy/firewall hops)
- If using VNet-integrated IR, add a Key Vault **private endpoint** in the same VNet
- Consider a pre-execution **Execute SQL Task** with a simple query (e.g., `SELECT 1`) using the same ODBC connection manager to warm the connection pool before the Data Flow task runs

---

## Quick checklist

- [ ] `Connection Timeout=120;` (or higher) in ODBC connection string
- [ ] `CommandTimeout` set to 120+ on ODBC Source / Destination components
- [ ] `ConnectRetryCount=3; ConnectRetryInterval=10;` in connection string
- [ ] DNS resolves to correct (private) endpoint from IR node
- [ ] Key Vault is reachable from IR node with low latency
- [ ] ODBC Driver 18 (or 17) is installed on all IR nodes via custom setup
- [ ] Pre-warm connection pool with Execute SQL Task before Data Flow (optional)

---

## Related files

- Connection string templates: `../connection_strings.md`
- ODBC approach guide: `odbc_approach.md`
- ADO.NET approach guide: `ado_net_approach.md`
- Custom setup script: `../custom_setup/main.cmd`
