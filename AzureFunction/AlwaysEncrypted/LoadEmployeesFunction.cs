using System;
using System.Collections.Generic;
using System.Data;
using System.Threading.Tasks;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace StageToAlwaysEncrypted;

/// <summary>
/// Loads rows from the staging table (<c>HR.Employees_stg2</c>) into the
/// Always Encrypted destination table (<c>HR.Employees2</c>).
///
/// Authentication uses the Function App's Managed Identity for BOTH:
///   * logging in to Azure SQL (no username/password), and
///   * unlocking the Column Master Key in Azure Key Vault (wired up in Program.cs).
///
/// The connection string MUST contain <c>Column Encryption Setting=Enabled</c>
/// so that Microsoft.Data.SqlClient encrypts SSN and Salary on the client side
/// before sending them to SQL Server.
/// </summary>
public class LoadEmployeesFunction
{
    private readonly ILogger<LoadEmployeesFunction> _logger;

    // Name of the environment / application setting holding the SQL connection string.
    private const string ConnectionStringSettingName = "SqlConnectionString";

    // Simple source query: explicit decimal(19,4) cast keeps numeric metadata
    // stable and the NOT NULL filter avoids inserting nulls into NOT NULL
    // encrypted columns (see SSIS/AlwaysEncrypted docs in this repo).
    private const string SelectSql = @"
SELECT SSN, FirstName, LastName, CAST(Salary AS decimal(19,4)) AS Salary
FROM HR.Employees_stg2
WHERE SSN IS NOT NULL AND Salary IS NOT NULL;";

    private const string InsertSql = @"
INSERT INTO HR.Employees2 (SSN, FirstName, LastName, Salary)
VALUES (@SSN, @FirstName, @LastName, @Salary);";

    public LoadEmployeesFunction(ILogger<LoadEmployeesFunction> logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Runs on a schedule (default: every day at 02:00 UTC). Adjust the CRON
    /// expression as needed, or replace the trigger with an HTTP trigger to run
    /// it on demand.
    /// </summary>
    [Function("LoadEmployees")]
    public async Task Run([TimerTrigger("0 0 2 * * *")] TimerInfo timer)
    {
        _logger.LogInformation("LoadEmployees started at {UtcNow}.", DateTime.UtcNow);

        string? connectionString = Environment.GetEnvironmentVariable(ConnectionStringSettingName);
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException(
                $"Missing application setting '{ConnectionStringSettingName}'. " +
                "It must include 'Authentication=Active Directory Default' and " +
                "'Column Encryption Setting=Enabled'.");
        }

        int rowsRead = 0;
        int rowsInserted = 0;

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync();

        // Read all source rows first so the reader is closed before we start
        // inserting on the same connection.
        var rows = new List<EmployeeRow>();
        await using (var selectCommand = new SqlCommand(SelectSql, connection))
        await using (var reader = await selectCommand.ExecuteReaderAsync())
        {
            while (await reader.ReadAsync())
            {
                rows.Add(new EmployeeRow(
                    Ssn: reader.GetString(0),
                    FirstName: reader.GetString(1),
                    LastName: reader.GetString(2),
                    Salary: reader.GetDecimal(3)));
                rowsRead++;
            }
        }

        foreach (var row in rows)
        {
            await using var insertCommand = new SqlCommand(InsertSql, connection);

            // Always pass values as parameters (never concatenate into SQL text).
            // The driver encrypts SSN and Salary transparently before sending.
            insertCommand.Parameters.Add("@SSN", SqlDbType.NVarChar, 11).Value = row.Ssn;
            insertCommand.Parameters.Add("@FirstName", SqlDbType.NVarChar, 100).Value = row.FirstName;
            insertCommand.Parameters.Add("@LastName", SqlDbType.NVarChar, 100).Value = row.LastName;

            // Match the destination column precision/scale exactly: decimal(19,4).
            var salaryParam = insertCommand.Parameters.Add("@Salary", SqlDbType.Decimal);
            salaryParam.Precision = 19;
            salaryParam.Scale = 4;
            salaryParam.Value = row.Salary;

            rowsInserted += await insertCommand.ExecuteNonQueryAsync();
        }

        // Log counts only — never log SSN, Salary, or any sensitive value.
        _logger.LogInformation(
            "LoadEmployees finished. Rows read: {RowsRead}. Rows inserted: {RowsInserted}.",
            rowsRead,
            rowsInserted);
    }

    private readonly record struct EmployeeRow(string Ssn, string FirstName, string LastName, decimal Salary);
}
