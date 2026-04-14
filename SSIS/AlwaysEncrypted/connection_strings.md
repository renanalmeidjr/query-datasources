# Connection string reference for SSIS Always Encrypted with ODBC

> Use these as templates. Replace placeholders with real values.

## 1) ODBC Driver 17 + Always Encrypted

```text
Driver={ODBC Driver 17 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<database>;
Uid=<username>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
```

## 2) ODBC Driver 18 + Always Encrypted

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<database>;
Uid=<username>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
```

## 3) Azure Key Vault CMK (Managed Identity)

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<database>;
Authentication=ActiveDirectoryMsi;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
KeyStoreAuthentication=KeyVaultManagedIdentity;
```

If you use a user-assigned managed identity, include the client ID in the authentication settings as required by your runtime configuration.

## 4) Azure Key Vault CMK (Service Principal)

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<database>;
Authentication=ActiveDirectoryServicePrincipal;
UID=<app-client-id>;
PWD=<app-client-secret>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
KeyStoreAuthentication=KeyVaultClientSecret;
KeyStorePrincipalId=<app-client-id>;
KeyStoreSecret=<app-client-secret>;
```

## 5) Windows Certificate Store CMK

```text
Driver={ODBC Driver 18 for SQL Server};
Server=tcp:<server>.database.windows.net,1433;
Database=<database>;
Uid=<username>;
Pwd=<password>;
Encrypt=yes;
TrustServerCertificate=no;
ColumnEncryption=Enabled;
```

For Windows Certificate Store CMK, no additional KeyStore parameters are required in most cases. The key requirement is that the certificate + private key exists on the SSIS IR node and is accessible to runtime identity.

## 6) DSN-based equivalent

```text
DSN=<YourSystemDsnName>;ColumnEncryption=Enabled;
```

You can still append security/auth options if not fully defined in DSN.
