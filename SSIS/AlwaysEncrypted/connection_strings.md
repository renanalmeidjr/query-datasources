# Working Connection String Templates (Always Encrypted)

## 1) ODBC Driver 18 (recommended)

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<database>;
Uid=<username>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
Connection Timeout=120;
ConnectRetryCount=3;
ConnectRetryInterval=10;
```

## 2) ODBC Driver 17 (fallback)

```text
Driver={ODBC Driver 17 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<database>;
Uid=<username>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
Connection Timeout=120;
ConnectRetryCount=3;
ConnectRetryInterval=10;
```

## 3) ADO.NET SqlClient (reference only; not preferred for this issue pattern)

```text
Data Source=tcp:<server>.database.windows.net,1433;
Initial Catalog=<database>;
User ID=<username>;
Password=<password>;
Encrypt=True;
TrustServerCertificate=False;
Column Encryption Setting=Enabled;
Connect Timeout=120;
ConnectRetryCount=3;
ConnectRetryInterval=10;
```

> **SSIS IR timeout note:** The default `Connection Timeout=30` is often too low for Azure-SSIS IR due to additional network hops, DNS resolution, and Key Vault access for Always Encrypted. Use `120` (seconds) or higher. Also set `CommandTimeout` on SSIS components. See `solutions/odbc_timeout_troubleshooting.md` for full details.

## 4) Integrated/Managed Identity variants

Authentication style depends on runtime and provider support. Keep the same Always Encrypted keyword:

- ODBC: `ColumnEncryption=Enabled`
- SqlClient: `Column Encryption Setting=Enabled`

Validate auth mode from the actual SSIS runtime host (local SSDT and SSIS IR can differ).
