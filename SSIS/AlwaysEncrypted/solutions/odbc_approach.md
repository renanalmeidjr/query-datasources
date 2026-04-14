# ODBC Approach (Confirmed Working)

This is the confirmed working implementation for loading into `HR.Employees2` Always Encrypted columns.

## 1) ODBC connection string

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

Equivalent with ODBC Driver 17:

```text
Driver={ODBC Driver 17 for SQL Server};...;ColumnEncryption=Enabled;
```

---

## 2) SSIS component configuration steps

1. Create **ODBC Connection Manager** with Driver 18 (or 17)
2. In Data Flow:
   - Source: query or table from `HR.Employees_stg2`
   - Destination: **ODBC Destination**
3. Destination mode: table insert
4. Map:
   - `SSN` -> encrypted randomized `SSN`
   - `FirstName` -> `FirstName`
   - `LastName` -> `LastName`
   - `Salary` -> encrypted deterministic `Salary`
5. Use source query with explicit cast and null filter:

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

---

## 3) Azure-SSIS IR custom setup requirements

- Install ODBC Driver 18 (or fallback 17) on every node
- Use `SSIS/AlwaysEncrypted/custom_setup/main.cmd` in SSIS IR custom setup
- Restart/recycle IR after driver installation so package runtime picks up driver

---

## 4) Runtime prerequisites

- `ColumnEncryption=Enabled` in connection string
- CMK access available to runtime identity (certificate store or Azure Key Vault)
- Consistent driver/provider versions across dev/test/prod
