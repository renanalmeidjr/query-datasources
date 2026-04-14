using System;
using System.Data;
using System.Data.SqlClient;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;
using Microsoft.SqlServer.Dts.Runtime.Wrapper;

// Script Component type: Destination
public class ScriptMain : UserComponent
{
    private SqlConnection _connection;
    private SqlCommand _insertCommand;

    public override void PreExecute()
    {
        base.PreExecute();

        try
        {
            var builder = new SqlConnectionStringBuilder
            {
                DataSource = "YOUR_SQL_SERVER",
                InitialCatalog = "SampleDB",
                IntegratedSecurity = true
            };

            // Required for Always Encrypted
            builder["Column Encryption Setting"] = "Enabled";

            _connection = new SqlConnection(builder.ConnectionString);
            _connection.Open();

            _insertCommand = new SqlCommand(
                @"INSERT INTO HR.Employees2 (SSN, FirstName, LastName, Salary)
                  VALUES (@SSN, @FirstName, @LastName, @Salary);",
                _connection);

            _insertCommand.Parameters.Add(new SqlParameter("@SSN", SqlDbType.NVarChar, 11));
            _insertCommand.Parameters.Add(new SqlParameter("@FirstName", SqlDbType.NVarChar, 50));
            _insertCommand.Parameters.Add(new SqlParameter("@LastName", SqlDbType.NVarChar, 50));

            var salaryParameter = new SqlParameter("@Salary", SqlDbType.Decimal)
            {
                Precision = 19,
                Scale = 4
            };
            _insertCommand.Parameters.Add(salaryParameter);
        }
        catch
        {
            if (_insertCommand != null)
            {
                _insertCommand.Dispose();
                _insertCommand = null;
            }

            if (_connection != null)
            {
                _connection.Dispose();
                _connection = null;
            }

            throw;
        }
    }

    public override void Input0_ProcessInputRow(Input0Buffer Row)
    {
        _insertCommand.Parameters["@SSN"].Value = Row.SSN_IsNull ? (object)DBNull.Value : Row.SSN;
        _insertCommand.Parameters["@FirstName"].Value = Row.FirstName;
        _insertCommand.Parameters["@LastName"].Value = Row.LastName;
        _insertCommand.Parameters["@Salary"].Value = Row.Salary_IsNull ? (object)DBNull.Value : Row.Salary;

        _insertCommand.ExecuteNonQuery();
    }

    public override void PostExecute()
    {
        base.PostExecute();

        if (_insertCommand != null)
        {
            _insertCommand.Dispose();
            _insertCommand = null;
        }

        if (_connection != null)
        {
            _connection.Dispose();
            _connection = null;
        }
    }
}
