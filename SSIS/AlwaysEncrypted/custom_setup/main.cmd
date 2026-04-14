@echo off
setlocal

echo [INFO] Installing SQL Server ODBC driver for Always Encrypted support...

rem Prefer Driver 18; fallback to Driver 17.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "$driver18 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server' -ErrorAction SilentlyContinue;" ^
  "if (-not $driver18) {" ^
  "  Write-Host '[INFO] ODBC Driver 18 not found. Installing...';" ^
  "  $msi18 = Join-Path $env:TEMP 'msodbcsql18.msi';" ^
  "  Invoke-WebRequest -Uri 'https://aka.ms/downloadmsodbcsql18' -OutFile $msi18;" ^
  "  Start-Process msiexec.exe -ArgumentList '/i', $msi18, '/quiet', '/norestart', 'IACCEPTMSODBCSQLLICENSETERMS=YES' -Wait -NoNewWindow;" ^
  "}" ^
  "$driver18 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server' -ErrorAction SilentlyContinue;" ^
  "if (-not $driver18) {" ^
  "  Write-Host '[WARN] ODBC Driver 18 install not detected. Trying Driver 17 fallback...';" ^
  "  $msi17 = Join-Path $env:TEMP 'msodbcsql17.msi';" ^
  "  Invoke-WebRequest -Uri 'https://aka.ms/downloadmsodbcsql17' -OutFile $msi17;" ^
  "  Start-Process msiexec.exe -ArgumentList '/i', $msi17, '/quiet', '/norestart', 'IACCEPTMSODBCSQLLICENSETERMS=YES' -Wait -NoNewWindow;" ^
  "}" ^
  "$driver18 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server' -ErrorAction SilentlyContinue;" ^
  "$driver17 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 17 for SQL Server' -ErrorAction SilentlyContinue;" ^
  "if ($driver18 -or $driver17) { Write-Host '[INFO] ODBC SQL Server driver available.' } else { throw 'Neither ODBC Driver 18 nor 17 was detected after installation.' }"

if %errorlevel% neq 0 (
  echo [ERROR] ODBC driver installation failed.
  exit /b 1
)

echo [INFO] ODBC driver installation completed.
exit /b 0
