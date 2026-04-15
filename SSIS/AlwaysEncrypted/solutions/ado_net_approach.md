# ADO.NET Approach for Always Encrypted in SSIS

This document describes the ADO.NET path that can work for this issue pattern.

## Executive summary

- **Works when** ADO.NET Destination is backed by **ODBC provider/driver** (article pattern)
- **Does not reliably work** with default ADO.NET SQL client destination for this table pattern

---

## 1) Connection manager configuration

Create an **ADO.NET Connection Manager** and choose:

- Provider: **.NET Providers\\Odbc Data Provider**
- Connection string (example using ODBC Driver 18):

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<db>;
Uid=<user>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
Connection Timeout=30;
```

Important:
- `ColumnEncryption=Enabled` is required for Always Encrypted client-side encryption/decryption

---

## 2) Data Flow component settings

1. Source: read from `HR.Employees_stg2`
2. Destination: **ADO.NET Destination**
3. Destination connection: select the ADO.NET connection manager using ODBC provider
4. Data access mode: start with **Table or view** (non-fast-load)
5. Map columns: `SSN`, `FirstName`, `LastName`, `Salary`

---

## 3) Source query adjustments

Use explicit cast in source query to keep numeric metadata stable:

```sql
SELECT
    SSN,
    FirstName,
    LastName,
    CAST(Salary AS decimal(19,4)) AS Salary
FROM HR.Employees_stg2
WHERE SSN IS NOT NULL
  AND Salary IS NOT NULL;
```

Why this still matters:
- Even with ODBC provider, explicit precision/scale avoids pipeline inference drift and prevents avoidable metadata mismatches.

---

## 4) Why this works

The article’s key point is that SSIS Always Encrypted support is practical when using:

- ADO.NET Destination component
- backed by ODBC provider/driver with Always Encrypted enabled

This avoids known failures seen with default SQL client destination path in this scenario (decimal precision mismatch and randomized nvarchar null-reference failure).

---

## 5) If ADO.NET still fails in your environment

Use the direct ODBC implementation in `odbc_approach.md`. That is the validated fallback and should be treated as primary production route for this issue.
