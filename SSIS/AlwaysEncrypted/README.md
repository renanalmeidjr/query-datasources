# SSIS + SQL Server Always Encrypted (Randomized + Deterministic) in ADF SSIS IR

## What is confirmed working

For this scenario:

- `SSN nvarchar(11)` encrypted as **Randomized**
- `Salary decimal(19,4)` encrypted as **Deterministic**

the confirmed working path is:

- ✅ **SSIS ODBC Destination**
- ✅ **ODBC Driver 17 or 18 for SQL Server**
- ✅ connection includes `ColumnEncryption=Enabled`

## What did not work (and should not be the recommended path)

### 1) ADO.NET Destination

Observed failures:

1. **Decimal precision mismatch**
   - Runtime error shows `decimal(9,4)` sent to encrypted `decimal(19,4)`.
   - With Always Encrypted, parameter metadata must match exactly, so this fails during statement preparation.

2. **NullReferenceException / Object reference not set** for Randomized `nvarchar`
   - When testing only `SSN` (Randomized encrypted column), ADO.NET Destination throws `Object reference not set to an instance of an object`.

Conclusion:

- ❌ ADO.NET Destination is not reliable for this mixed Always Encrypted insert pattern in SSIS.

### 2) OLE DB Destination

- OLE DB has partial Always Encrypted support but is not reliable for writing to **Randomized** encrypted columns in this scenario.
- Conclusion: treat OLE DB as non-solution for this use case.

## Why ODBC is the correct solution

ODBC Driver 17/18 supports Always Encrypted parameter encryption in a stable way for this scenario when:

- connection has `ColumnEncryption=Enabled`
- metadata is refreshed in data flow after switching destination
- destination mapping stays type-accurate (`nvarchar(11)`, `decimal(19,4)`)

---

## End-to-end implementation in ADF SSIS IR

## 1) Build the package with ODBC Destination

1. In SSIS Data Flow, replace ADO.NET/OLE DB destination with **ODBC Destination**.
2. Use an ODBC connection manager (DSN or DSN-less).
3. Ensure destination mapping is:
   - `SSN` -> `nvarchar(11)` (encrypted Randomized)
   - `Salary` -> `decimal(19,4)` (encrypted Deterministic)
4. Reopen destination and refresh/reselect columns after changing providers.

## 2) Use an ODBC connection string with Always Encrypted enabled

Example (DSN-less, SQL auth, Driver 18):

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<db>;
Uid=<user>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
```

See `connection_strings.md` for additional formats (Driver 17, AKV CMK options, Windows cert store CMK).

## 3) Install ODBC Driver on SSIS IR using custom setup

ADF SSIS IR nodes are managed VMs; if the required ODBC driver is not present, install it through SSIS IR **custom setup**.

### Files to provide in custom setup container

- `main.cmd` (provided in `custom_setup/main.cmd`)
- optional pre-downloaded driver installer EXE(s) to avoid internet dependency:
  - `msodbcsql18.exe` (preferred)
  - `msodbcsql17.exe` (fallback)

### How to wire custom setup in ADF

1. Zip your custom setup payload with `main.cmd` at the root of the zip file. If you include local installers (for example `msodbcsql18.exe`/`msodbcsql17.exe`), place them at the same root level so `main.cmd` can find them.
2. Upload to Azure Storage container.
3. Generate SAS URL.
4. In ADF -> SSIS Integration Runtime -> **Custom setup** -> add the package/SAS reference.
5. Restart or re-provision SSIS IR so setup executes on nodes.
6. Validate installation from an Execute Process Task or script task if needed (for example: `odbcconf /Lv`).

## 4) CMK requirements in SSIS IR

Always Encrypted can only work if SSIS IR runtime can access the **Column Master Key** provider.

### A) CMK in Windows Certificate Store

- The certificate (with private key) used by CMK must exist on each SSIS IR worker node in the expected store location (commonly `CurrentUser/My` or `LocalMachine/My`, matching CMK definition).
- Install/import cert + private key using SSIS IR custom setup.
- Ensure identity running the package can read the private key.

### B) CMK in Azure Key Vault

Use SQL client/provider authentication supported by the ODBC driver:

- **Managed Identity** (`KeyStoreAuthentication=KeyVaultManagedIdentity`)
- **Service Principal** (`KeyStoreAuthentication=KeyVaultClientSecret` + principal/secret)

Also ensure:

- SSIS IR identity/service principal has `get`, `unwrapKey`, `wrapKey` as required on Key Vault key.
- Firewall/network allows SSIS IR outbound access to Key Vault.

## 5) ODBC DSN vs DSN-less in SSIS

Both are valid.

- **DSN-less** is usually easier for promoted/deployed packages because all properties stay in the connection manager string.
- **System DSN** can be used if you create it in custom setup on each SSIS IR node.

## 6) Deploy package to SSIS IR

1. Deploy to **SSISDB** hosted in:
   - Azure SQL Database (with SSISDB)
   - or Azure SQL Managed Instance
2. Configure environment variables/parameters for server, database, auth, and secure values.
3. Execute package on SSIS IR and verify row counts in destination table.

---

## Known limitations and gotchas

- ADO.NET Destination can fail in this scenario with:
  - encrypted decimal precision mismatch behavior
  - null reference behavior on Randomized encrypted string writes
- OLE DB is not a reliable option for Randomized encrypted inserts in this scenario.
- Always Encrypted is strict about data type metadata: precision/scale/length must match encrypted target metadata.
- Source allows NULLs while destination is `NOT NULL` for `SSN` and `Salary`; guard data before destination.
- Driver 18 defaults to strict TLS behavior (`Encrypt=yes` by default). Ensure certificates/network trust are correct.

---

## Prior guidance correction

Earlier suggestions to keep using ADO.NET Destination or rely on OLE DB as equivalent alternatives were not correct for this tested case.

For this workload, use **ODBC Destination + ODBC Driver 17/18 + `ColumnEncryption=Enabled`** as the supported, confirmed-working approach.
