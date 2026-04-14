@echo off
setlocal

echo [INFO] Installing SQL Server ODBC driver for Always Encrypted support...

rem Prefer Driver 18; fallback to Driver 17.

powershell -NoProfile -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "function Test-MsiSignature([string]$Path) {" ^
  "  $sig = Get-AuthenticodeSignature -FilePath $Path;" ^
  "  if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate) {" ^
  "    throw ('Invalid installer signature for ' + $Path + '. Status=' + $sig.Status);" ^
  "  }" ^
  "  $subject = $sig.SignerCertificate.Subject;" ^
  "  if ($subject -notlike '*Microsoft Corporation*' -and $subject -notlike '*CN=Microsoft*') {" ^
  "    throw ('Invalid installer signature for ' + $Path + '. Status=' + $sig.Status);" ^
  "  }" ^
  "}" ^
  "function Install-Msi([string]$Path, [string]$Label) {" ^
  "  $proc = Start-Process msiexec.exe -ArgumentList '/i', $Path, '/quiet', '/norestart', 'IACCEPTMSODBCSQLLICENSETERMS=YES' -Wait -NoNewWindow -PassThru;" ^
  "  if ($proc.ExitCode -ne 0) { throw ($Label + ' installation failed with exit code: ' + $proc.ExitCode) }" ^
  "}" ^
  "$driver18 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server' -ErrorAction SilentlyContinue;" ^
  "if (-not $driver18) {" ^
  "  Write-Host '[INFO] ODBC Driver 18 not found. Installing...';" ^
  "  $msi18 = Join-Path $env:TEMP 'msodbcsql18.msi';" ^
  "  Invoke-WebRequest -Uri 'https://aka.ms/downloadmsodbcsql18' -OutFile $msi18 -UseBasicParsing;" ^
  "  Test-MsiSignature -Path $msi18;" ^
  "  Install-Msi -Path $msi18 -Label 'ODBC Driver 18';" ^
  "}" ^
  "$driver18 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server' -ErrorAction SilentlyContinue;" ^
  "if (-not $driver18) {" ^
  "  Write-Host '[WARN] ODBC Driver 18 install not detected. Trying Driver 17 fallback...';" ^
  "  $msi17 = Join-Path $env:TEMP 'msodbcsql17.msi';" ^
  "  Invoke-WebRequest -Uri 'https://aka.ms/downloadmsodbcsql17' -OutFile $msi17 -UseBasicParsing;" ^
  "  Test-MsiSignature -Path $msi17;" ^
  "  Install-Msi -Path $msi17 -Label 'ODBC Driver 17';" ^
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
