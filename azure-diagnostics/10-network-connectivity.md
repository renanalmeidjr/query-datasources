# 10 — Network & Connectivity Checks: Redirect + Private Endpoint

> **Scope:** ARO (Azure Red Hat OpenShift) pods → Azure SQL Hyperscale via Private Endpoint · Redirect connection policy · Same VNet

---

## Overview

The path from an RHBK pod to Azure SQL Hyperscale is:

```
RHBK Pod (ARO Node)
    │
    ▼  (TCP :1433 — initial connection / Proxy policy or first hop)
Azure SQL Gateway (Public IP, even for Private Endpoint — only for TCP :1433 redirect)
    │
    ▼  (TCP :11000-11999 — Redirect; direct to SQL compute node)
Azure SQL Hyperscale Compute Node
    │  (via Private Endpoint NIC, same VNet as ARO)
    ▼
Private DNS Zone resolves → Private Endpoint NIC IP (10.x.x.x)
```

**Key subtlety with Redirect + Private Endpoint:**
- The initial TCP connection goes to `:1433` to the Private Endpoint IP.
- The SQL gateway returns a **redirect** pointing to a port in `11000-11999` on the SQL compute node's IP.
- The JDBC driver then opens a **second TCP connection** directly to that port.
- If NSG or firewall rules block `11000-11999`, the second connection fails and the driver falls back to Proxy mode (all traffic through `:1433` via the gateway) — adding a gateway hop and latency.

---

## 1. Confirm Connection Policy Is Redirect

### 1.1 From Azure Portal
Navigate to: **Azure SQL Database → Settings → Connection strings → Connection policy**
Should show: **Redirect**

### 1.2 From T-SQL (inside the database)
```sql
-- This shows the connection policy for the current database.
-- 'Redirect' is the recommended policy for lowest latency.
SELECT
    CONNECTIONPROPERTY('local_net_address')  AS sql_node_ip,
    CONNECTIONPROPERTY('local_tcp_port')     AS sql_node_port,
    CONNECTIONPROPERTY('client_net_address') AS client_ip
;
```

If `local_tcp_port` is in the range **11000–11999**, the Redirect is working correctly.
If `local_tcp_port` is **1433**, the connection fell back to Proxy mode.

### 1.3 Test Redirect ports from ARO pod
```bash
# Run from inside an RHBK pod or a test pod on ARO.
# Replace <private-endpoint-ip> with the actual IP from Private DNS Zone.
# Test a sample of Redirect ports:
for port in 11000 11001 11100 11500 11999; do
    echo -n "Port $port: "
    timeout 3 bash -c "echo '' > /dev/tcp/<private-endpoint-ip>/$port" 2>&1 \
        && echo "OPEN" || echo "BLOCKED"
done
```

If ANY port in 11000–11999 is BLOCKED, the JDBC driver cannot maintain Redirect mode for that SQL compute node assignment and will silently degrade to Proxy.  **Open 11000–11999 in the NSG from ARO node pool subnet to the Private Endpoint subnet.**

---

## 2. Measure Round-Trip Latency to the Database

### 2.1 Baseline `SELECT 1` loop (from RHBK pod or a test pod)
```bash
# Install sqlcmd in a test container, or use a simple JDBC timing script.
# Replace placeholders with actual values.
for i in $(seq 1 100); do
    START=$(date +%s%N)
    sqlcmd -S <private-endpoint-ip>,1433 \
           -d <db-placeholder> \
           -U <sqluser-placeholder> \
           -P '<password-placeholder>' \
           -Q "SELECT 1" \
           -b -q > /dev/null 2>&1
    END=$(date +%s%N)
    echo "$(( (END - START) / 1000000 )) ms"
done | awk '{sum+=$1; n++} END {printf "avg=%.1f ms  n=%d\n", sum/n, n}'
```

**Expected results:**
- IaaS (VM in same VNet, Proxy): 0.5–2 ms
- Azure SQL PaaS, Private Endpoint, Redirect, same VNet: 1–5 ms
- Azure SQL PaaS, Private Endpoint, Proxy (port 11000 blocked): 3–10 ms (gateway hop)

If you see > 5 ms on a Private Endpoint in the same VNet, investigate NVA/firewall in the path (see Section 4).

### 2.2 T-SQL timing test — measure from inside SQL
```sql
-- Run from SSMS or sqlcmd connected via Redirect to measure pure SQL round-trip.
-- This tests the log commit path specifically (INSERT + COMMIT).
DECLARE @i    INT = 0;
DECLARE @start DATETIME2 = SYSDATETIME();

-- Create a temp table to avoid modifying real tables
CREATE TABLE #ping_test (id INT IDENTITY, val CHAR(1));

WHILE @i < 1000
BEGIN
    INSERT INTO #ping_test (val) VALUES ('x');
    SET @i += 1;
END;
COMMIT;

SELECT
    DATEDIFF(MICROSECOND, @start, SYSDATETIME()) / 1000.0 / 1000 AS total_sec,
    DATEDIFF(MICROSECOND, @start, SYSDATETIME()) / 1000.0 / 1000 AS per_insert_ms_avg;

DROP TABLE #ping_test;
```

---

## 3. Validate Private Endpoint DNS Resolution

### 3.1 Expected DNS flow
```
<server-placeholder>.database.windows.net
    → CNAME → <server-placeholder>.privatelink.database.windows.net
    → A record → 10.x.x.x (Private Endpoint NIC IP)
```

### 3.2 Verify from ARO pod
```bash
# Run from inside an ARO pod
nslookup <server-placeholder>.database.windows.net
# Must resolve to a 10.x.x.x (private IP), NOT to a 40.x / 13.x / 52.x (public IP).

# Also verify that the CNAME chain goes through privatelink:
dig <server-placeholder>.database.windows.net +norecurse
```

If the DNS resolves to a PUBLIC IP, the Private DNS Zone is not linked to the ARO VNet, and traffic is going over the public internet (bypassing Private Endpoint entirely).  Fix: link the `privatelink.database.windows.net` Private DNS Zone to the ARO VNet.

### 3.3 DNS latency
```bash
# Measure DNS resolution time (should be < 1 ms for Private DNS Zone in same VNet):
for i in $(seq 1 20); do
    time nslookup <server-placeholder>.database.windows.net > /dev/null 2>&1
done
```

High DNS latency (> 5 ms) can add to every NEW TCP connection.  For persistent connections (pool reuse), this is a one-time cost per physical connection lifetime.

---

## 4. Verify No NVA / Firewall Hop in the Path

### 4.1 Trace route from ARO pod to Private Endpoint
```bash
traceroute -T -p 1433 <private-endpoint-ip>
# -T = use TCP (not ICMP), -p = destination port
```

**Expected:** 1 hop (direct to Private Endpoint NIC).
**Suspicious:** 2+ hops, especially if one hop is an NVA (Azure Firewall, Palo Alto, etc.) in a Hub VNet.

If there is a Hub-and-Spoke topology with a Hub Firewall:
- All SQL traffic goes ARO VNet → Hub Firewall → Spoke VNet with Private Endpoint.
- This adds 2 hops and potentially adds the Firewall's TLS inspection latency.
- This alone can explain 5–15 ms additional latency vs expectations.
- **Action:** Check UDR (User Defined Route) tables on the ARO subnet.  If `0.0.0.0/0` points to the Hub Firewall IP, ALL outbound traffic (including Private Endpoint traffic) traverses the firewall.  Add a specific UDR for `<private-endpoint-ip>/32 → VirtualNetworkGateway (or Internet, depending on topology)` to bypass the firewall for the SQL path.

---

## 5. Decompose the 300 ms `getConnection()` Cost

The observed ~300 ms `getConnection()` in Agroal could come from:

| Phase | Typical cost | How to isolate |
|---|---|---|
| **Wait in Agroal queue** (pool full) | 0 ms – ∞ | Agroal `timeout_count` metric; log pool queue depth |
| **TCP connect** to Private Endpoint | 0.5–3 ms | `traceroute` + `time bash -c "echo > /dev/tcp/<ip>/1433"` |
| **TLS handshake** | 1–5 ms | OpenSSL s_client timing |
| **TDS Login7 exchange** (SQL auth) | 1–3 ms | Extended Events `login_completed` with SQL auth |
| **Entra auth token** (MSAL call) | 50–200 ms per cache miss | MSAL debug logs + Extended Events `login_completed` diff |
| **`sp_reset_connection`** (pool reuse) | 0.5–2 ms | Extended Events `sql_statement_completed` for reset |

### 5.1 TLS timing from ARO pod
```bash
# Measure TLS handshake time (excludes TCP connect, measures TLS overhead):
time openssl s_client \
    -connect <private-endpoint-ip>:1433 \
    -starttls mssql \
    -quiet < /dev/null 2>&1 | head -5
```

### 5.2 SNAT / ephemeral port exhaustion check
```bash
# On ARO nodes, check SNAT port usage if there is outbound NAT in the path.
# High SNAT port usage can cause connection establishment delays.
# This is only relevant if traffic egresses through a NAT Gateway or Load Balancer.

# From ARO node (not pod):
ss -s                              # TCP connection summary
cat /proc/net/ip_conntrack | wc -l # conntrack table size
netstat -an | grep TIME_WAIT | wc -l  # TIME_WAIT sockets (port churn)
```

If `TIME_WAIT` count is high (tens of thousands), ephemeral port exhaustion may be causing new `getConnection()` calls to delay while waiting for a port to free up.  This is an ARO/node-level issue, not a SQL issue.

---

## 6. NSG Rules Checklist

| Source | Destination | Port | Protocol | Required for |
|---|---|---|---|---|
| ARO node pool subnet | Private Endpoint subnet | **1433** | TCP | Initial connection / Proxy fallback |
| ARO node pool subnet | Private Endpoint subnet | **11000–11999** | TCP | Redirect mode (direct to SQL compute) |
| ARO node pool subnet | Azure AD endpoints | **443** | TCP | Entra auth MSAL HTTPS (if Entra auth) |
| Private Endpoint subnet | ARO node pool subnet | ephemeral | TCP | Return traffic (typically stateful NSG) |

> **Verify:** If 11000–11999 is blocked, RHBK silently uses Proxy mode, adding a gateway hop to every query.  This alone can explain 2–5 ms additional latency per round-trip, which at 15K RPS accumulates to measurable throughput loss.
