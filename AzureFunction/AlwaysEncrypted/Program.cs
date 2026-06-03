using System.Collections.Generic;
using Azure.Core;
using Azure.Identity;
using Microsoft.Data.SqlClient;
using Microsoft.Data.SqlClient.AlwaysEncrypted.AzureKeyVaultProvider;
using Microsoft.Extensions.Hosting;

// Entry point for the .NET 8 isolated-worker Azure Function.
//
// Two responsibilities are wired up here, ONCE at startup:
//   1) Build a single token credential based on Managed Identity (in Azure)
//      or the developer sign-in (locally). This is shared for SQL login and
//      for unlocking the Column Master Key (CMK) in Azure Key Vault.
//   2) Register the Azure Key Vault column-encryption key store provider so
//      Always Encrypted can encrypt/decrypt SSN and Salary transparently.

// 1) Credential via Managed Identity (cloud) / developer identity (local).
//    DefaultAzureCredential automatically uses the Function App's
//    system-assigned Managed Identity when running in Azure, and falls back to
//    the local `az login` / Visual Studio / VS Code identity during development.
TokenCredential credential = new DefaultAzureCredential();

// 2) Register the Azure Key Vault provider for Always Encrypted (once).
//    This lets Microsoft.Data.SqlClient reach the CMK in Key Vault using the
//    same Managed Identity, so no certificate is needed on the host.
var akvProvider = new SqlColumnEncryptionAzureKeyVaultProvider(credential);
SqlConnection.RegisterColumnEncryptionKeyStoreProviders(
    new Dictionary<string, SqlColumnEncryptionKeyStoreProvider>(System.StringComparer.OrdinalIgnoreCase)
    {
        { SqlColumnEncryptionAzureKeyVaultProvider.ProviderName, akvProvider }
    });

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .Build();

host.Run();
