# SSIS + SQL Server Always Encrypted (Employees_stg2 -> Employees2)

This guide documents what is currently reliable for loading data into Always Encrypted columns from SSIS, based on:

- User-confirmed tests in this repo issue thread
- Deep review of the referenced article approach (Rod Edwards): use **ADO.NET Destination with ODBC provider/driver** for Always Encrypted scenarios

---

## 1) What works vs what fails

### Confirmed working
- ✅ **ODBC Driver 17/18 path** for inserts into Always Encrypted columns
- ✅ **ADO.NET Destination + ODBC provider** (article pattern) when connection string enables column encryption and CMK access is correct

### Confirmed failing / unreliable
- ❌ **ADO.NET Destination with default SQL client provider**
  - Deterministic encrypted decimal can fail with precision mismatch (`decimal(9,4)` vs `decimal(19,4)`)
  - Randomized encrypted `nvarchar` can fail with `Object reference not set to an instance of an object`
- ⚠️ **OLE DB Destination**
  - Limited/partial behavior; not reliable for Randomized encrypted writes

---

## 2) Recommended implementation order

1. **Primary recommendation**: ODBC-based flow (see `solutions/odbc_approach.md`)
2. **If you must stay in ADO.NET Destination UI**: use the **ODBC provider** (see `solutions/ado_net_approach.md`)
3. Avoid default ADO.NET SQL client destination for this specific Always Encrypted pattern

---

## 3) Data model used in this issue

Source:
- `HR.Employees_stg2` (`SSN nvarchar(11)`, `Salary decimal(19,4)`, nullable)

Destination:
- `HR.Employees2`
  - `SSN nvarchar(11)` encrypted **Randomized** (NOT NULL)
  - `Salary decimal(19,4)` encrypted **Deterministic** (NOT NULL)

Operational note:
- Because destination `SSN` and `Salary` are `NOT NULL`, source rows with nulls must be handled before destination insert.

---

## 4) Connection string requirements

Always include encryption + trusted server identity + Always Encrypted enablement.

- ODBC keyword: `ColumnEncryption=Enabled`
- SqlClient keyword: `Column Encryption Setting=Enabled`

See full templates in `connection_strings.md`.

---

## 5) CMK access requirements

Always Encrypted writes require runtime access to Column Master Key metadata provider.

### Windows Certificate Store CMK
- SSIS runtime identity must be able to access private key in `CurrentUser` or `LocalMachine` certificate store (where CMK points)
- On Azure-SSIS IR, import certificate/private key on all worker nodes used by package runtime

### Azure Key Vault CMK (recommended for SSIS IR)
- Recommended for cloud-hosted SSIS IR
- Grant SSIS runtime identity (managed identity/service principal) permissions to AKV key (`get`, `unwrapKey`, `wrapKey` as required)
- Ensure firewall/network rules allow SSIS IR outbound access to Key Vault endpoint

---

## 6) Azure Data Factory / SSIS IR deployment considerations

- Install SQL Server ODBC Driver 18 (or 17 fallback) on SSIS IR via custom setup script (`custom_setup/main.cmd`)
- Keep ODBC driver version consistent across all nodes
- Validate package in catalog with same runtime identity used in production
- If using AKV CMK, validate identity and network path from IR node, not only from developer machine

---

## 7) Practical conclusion

For this scenario (`Randomized nvarchar` + `Deterministic decimal(19,4)`), the most reliable production approach is **ODBC driver-based** execution (either directly with ODBC destination, or via ADO.NET Destination configured with ODBC provider as described in the article).
