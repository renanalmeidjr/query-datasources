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
using Azure.Identity;
using Azure.Security.KeyVault.Keys.Cryptography;
using Microsoft.Data.SqlClient;

public static class ClientEncryptionExample
{
    // Caller should reuse and dispose this client at application shutdown.
    public static CryptographyClient CreateCryptoClient(Uri keyId)
    {
        return new CryptographyClient(keyId, new DefaultAzureCredential());
    }

    private static void ValidateAesDek(byte[] dek)
    {
        if (dek is null || (dek.Length != 16 && dek.Length != 24 && dek.Length != 32))
            throw new InvalidOperationException("Invalid DEK length. Expected 16, 24, or 32 bytes for AES.");
    }

    // Persist this once (e.g., config table/secret) and reuse for decrypt operations.
    // It is safe to store wrapped DEK in DB/config because AKV key is required to unwrap.
    public static byte[] WrapDekWithAkv(CryptographyClient cryptoClient, byte[] dek)
    {
        var wrapResult = cryptoClient.WrapKey(KeyWrapAlgorithm.RsaOaep256, dek);
        return wrapResult.EncryptedKey;
    }

    public static byte[] UnwrapDekWithAkv(CryptographyClient cryptoClient, byte[] wrappedDek)
    {
        var unwrapResult = cryptoClient.UnwrapKey(KeyWrapAlgorithm.RsaOaep256, wrappedDek);
        ValidateAesDek(unwrapResult.Key);
        return unwrapResult.Key;
    }

    // Envelope format:
    // [version:1][ivLen:4][iv][tagLen:4][tag][cipherLen:4][cipher]
    public static byte[] EncryptAesGcm(string plaintext, byte[] dek)
    {
        ValidateAesDek(dek);
        byte[] input = Encoding.UTF8.GetBytes(plaintext);
        // 12-byte nonce is the NIST-recommended IV size for AES-GCM.
        byte[] iv = RandomNumberGenerator.GetBytes(12);
        byte[] cipher = new byte[input.Length];
        byte[] tag = new byte[16];

        using var aes = new AesGcm(dek);
        aes.Encrypt(iv, input, cipher, tag);

        try
        {
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
        finally
        {
            CryptographicOperations.ZeroMemory(input);
            CryptographicOperations.ZeroMemory(iv);
            CryptographicOperations.ZeroMemory(tag);
            CryptographicOperations.ZeroMemory(cipher);
        }
    }

    public static byte[] EncryptDecimal(decimal value, byte[] dek)
    {
        Span<int> bits = stackalloc int[4];
        decimal.GetBits(value, bits);
        byte[] raw = new byte[16];
        BinaryPrimitives.WriteInt32BigEndian(raw.AsSpan(0, 4), bits[0]);
        BinaryPrimitives.WriteInt32BigEndian(raw.AsSpan(4, 4), bits[1]);
        BinaryPrimitives.WriteInt32BigEndian(raw.AsSpan(8, 4), bits[2]);
        BinaryPrimitives.WriteInt32BigEndian(raw.AsSpan(12, 4), bits[3]);
        string base64 = Convert.ToBase64String(raw);
        CryptographicOperations.ZeroMemory(raw);
        return EncryptAesGcm(base64, dek);
    }

    public static void InsertEmployeeCiphertextOnly(
        string sqlConnectionString,
        CryptographyClient cryptoClient,
        byte[] wrappedDek,
        string ssnPlaintext,
        decimal salaryPlaintext,
        string firstName,
        string lastName)
    {
        // Reuse cryptoClient across inserts to avoid repeated auth/client initialization cost.
        byte[] dek = UnwrapDekWithAkv(cryptoClient, wrappedDek);

        try
        {
            byte[] ssnCipher = EncryptAesGcm(ssnPlaintext, dek);
            byte[] salaryCipher = EncryptDecimal(salaryPlaintext, dek);

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
        }
        finally
        {
            CryptographicOperations.ZeroMemory(dek);
        }
    }
}

// Construct once and reuse for wrap/unwrap + insert operations:
// var cryptoClient = ClientEncryptionExample.CreateCryptoClient(new Uri("<akv-key-id>"));
```

---

## 4) AKV permissions and operational rules

- Give app identity (`Managed Identity`/`service principal`) AKV key permissions: `get`, `wrapKey`, `unwrapKey`.
- Never write plaintext sensitive values to logs, traces, telemetry, or exception messages.
- Never concatenate plaintext into SQL text; always pass encrypted bytes as parameters.
- For highly sensitive fields (for example SSN), prefer transient buffers (`char[]`/`byte[]`) over long-lived immutable strings when practical.
- Keep SQL tracing enabled if needed: traces should contain ciphertext blobs only for protected fields.
