# SSIS + SQL Server Always Encrypted: Script Component Destination Workaround

## Why ADO.NET Destination fails in this scenario

For SQL Server Always Encrypted columns, SSIS ADO.NET Destination can fail during runtime parameter construction:

1. **Decimal precision mismatch bug**
   - Destination encrypted column: `decimal(19,4)`
   - ADO.NET Destination may infer `decimal(9,4)` for `@Salary`
   - SQL Server rejects encrypted parameter metadata mismatch (`decimal(9,4)` vs `decimal(19,4)`)

2. **Randomized `nvarchar` NullReferenceException**
   - For randomized encrypted `nvarchar` columns (for example `SSN`), ADO.NET Destination can throw:
   - `Object reference not set to an instance of an object`
   - This happens while provider metadata for Always Encrypted parameters is being resolved.

Because of these provider/component limitations, use a **Script Component (Destination)** so parameter metadata is explicitly controlled.

## Script file

Use: `/SSIS/AlwaysEncrypted/ScriptComponent_AlwaysEncrypted.cs`

This script:
- creates `SqlConnection` with `Column Encryption Setting=Enabled`
- inserts into `HR.Employees2`
- explicitly defines parameters:
  - `@SSN` as `SqlDbType.NVarChar`, size `11`
  - `@FirstName` as `SqlDbType.NVarChar`, size `50`
  - `@LastName` as `SqlDbType.NVarChar`, size `50`
  - `@Salary` as `SqlDbType.Decimal`, `Precision=19`, `Scale=4`
- handles nullable source fields (`SSN`, `Salary`) using `DBNull.Value`
- opens connection in `PreExecute()` and closes in `PostExecute()`

## SSIS setup steps (replace ADO.NET Destination)

1. In your Data Flow, remove (or disconnect) the failing ADO.NET Destination.
2. Add a **Script Component** and choose **Destination**.
3. Connect your upstream data flow path into the Script Component.
4. In Script Component input columns, include:
   - `SSN` (nullable)
   - `FirstName`
   - `LastName`
   - `Salary` (nullable)
5. Edit the script and replace the generated class with `ScriptComponent_AlwaysEncrypted.cs` logic.
6. Update the SQL connection details (`DataSource`, `InitialCatalog`, authentication) in `PreExecute()`.
7. Ensure the connection string contains `Column Encryption Setting=Enabled`.
8. Confirm SQL Server key/certificate access is available to the SSIS runtime account.
9. Execute the package.

## Notes

- If destination columns are `NOT NULL`, passing `DBNull.Value` from nullable source rows will still fail at SQL constraint level. In that case, cleanse or default values before destination.
- This workaround avoids ADO.NET Destination parameter inference issues by setting exact SQL metadata in code.
