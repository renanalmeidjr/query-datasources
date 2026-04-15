# Client-side Encryption Workflow with Azure Key Vault (no secure enclaves)

Use this pattern when plaintext must be encrypted in application code before SQL is sent to SQL Server.

## 1) Security goal

- Source rows may be plaintext.
- Application encrypts sensitive fields before SQL execution.
- SQL parameters carry only ciphertext (`varbinary`), never raw values.
- SQL traces/logs show encrypted blobs only.

---

## 2) Recommended schema shape for this pattern

Store sensitive values as encrypted payloads:

```sql
CREATE TABLE HR.Employees2_ClientEncrypted
(
    EmployeeId int IDENTITY PRIMARY KEY,
    SSN_Encrypted varbinary(max) NOT NULL,
    Salary_Encrypted varbinary(max) NOT NULL,
    FirstName nvarchar(100) NOT NULL,
    LastName nvarchar(100) NOT NULL
);
```

---

## 3) C# (.NET) example with AKV envelope encryption

This is the best fit for this repository stack (SQL Server + SSIS/Azure ecosystem).

```csharp
using System;
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Azure.Core;
using Azure.Identity;
using Azure.Security.KeyVault.Keys.Cryptography;
using Microsoft.Data.SqlClient;

public static class ClientEncryptionExample
{
    // Persist this once (e.g., config table/secret) and reuse for decrypt operations.
    // It is safe to store wrapped DEK in DB/config because AKV key is required to unwrap.
    public static byte[] WrapDekWithAkv(Uri keyId, byte[] dek, TokenCredential credential)
    {
        var cryptoClient = new CryptographyClient(keyId, credential);
        var wrapResult = cryptoClient.WrapKey(KeyWrapAlgorithm.RsaOaep256, dek);
        return wrapResult.EncryptedKey;
    }

    public static byte[] UnwrapDekWithAkv(Uri keyId, byte[] wrappedDek, TokenCredential credential)
    {
        var cryptoClient = new CryptographyClient(keyId, credential);
        var unwrapResult = cryptoClient.UnwrapKey(KeyWrapAlgorithm.RsaOaep256, wrappedDek);
        return unwrapResult.Key;
    }

    // Envelope format:
    // [version:1][ivLen:4][iv][tagLen:4][tag][cipherLen:4][cipher]
    public static byte[] EncryptAesGcm(string plaintext, byte[] dek)
    {
        byte[] input = Encoding.UTF8.GetBytes(plaintext);
        byte[] iv = RandomNumberGenerator.GetBytes(12);
        byte[] cipher = new byte[input.Length];
        byte[] tag = new byte[16];

        using var aes = new AesGcm(dek);
        aes.Encrypt(iv, input, cipher, tag);

        byte[] output = new byte[1 + 4 + iv.Length + 4 + tag.Length + 4 + cipher.Length];
        int offset = 0;
        output[offset++] = 1;
        BinaryPrimitives.WriteInt32BigEndian(output.AsSpan(offset, 4), iv.Length); offset += 4;
        iv.CopyTo(output, offset); offset += iv.Length;
        BinaryPrimitives.WriteInt32BigEndian(output.AsSpan(offset, 4), tag.Length); offset += 4;
        tag.CopyTo(output, offset); offset += tag.Length;
        BinaryPrimitives.WriteInt32BigEndian(output.AsSpan(offset, 4), cipher.Length); offset += 4;
        cipher.CopyTo(output, offset);
        return output;
    }

    public static void InsertEmployeeCiphertextOnly(
        string sqlConnectionString,
        Uri keyId,
        byte[] wrappedDek,
        string ssnPlaintext,
        decimal salaryPlaintext,
        string firstName,
        string lastName)
    {
        TokenCredential credential = new DefaultAzureCredential();
        byte[] dek = UnwrapDekWithAkv(keyId, wrappedDek, credential);

        byte[] ssnCipher = EncryptAesGcm(ssnPlaintext, dek);
        byte[] salaryCipher = EncryptAesGcm(salaryPlaintext.ToString("0.####"), dek);

        const string sql = @"
INSERT INTO HR.Employees2_ClientEncrypted
    (SSN_Encrypted, Salary_Encrypted, FirstName, LastName)
VALUES
    (@ssnEncrypted, @salaryEncrypted, @firstName, @lastName);";

        using var conn = new SqlConnection(sqlConnectionString);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@ssnEncrypted", System.Data.SqlDbType.VarBinary, -1).Value = ssnCipher;
        cmd.Parameters.Add("@salaryEncrypted", System.Data.SqlDbType.VarBinary, -1).Value = salaryCipher;
        cmd.Parameters.Add("@firstName", System.Data.SqlDbType.NVarChar, 100).Value = firstName;
        cmd.Parameters.Add("@lastName", System.Data.SqlDbType.NVarChar, 100).Value = lastName;

        conn.Open();
        cmd.ExecuteNonQuery();

        CryptographicOperations.ZeroMemory(dek);
    }
}
```

---

## 4) AKV permissions and operational rules

- Give app identity (`Managed Identity`/service principal) AKV key permissions: `get`, `wrapKey`, `unwrapKey`.
- Never write plaintext sensitive values to logs, traces, telemetry, or exception messages.
- Never concatenate plaintext into SQL text; always pass encrypted bytes as parameters.
- Keep SQL tracing enabled if needed: traces should contain ciphertext blobs only for protected fields.
