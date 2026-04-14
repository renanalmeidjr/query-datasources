@echo off
setlocal enableextensions enabledelayedexpansion

REM SSIS IR custom setup: install Microsoft ODBC Driver for SQL Server (18 preferred, 17 fallback)
REM Place this file in custom setup package root.

set "SCRIPT_DIR=%~dp0"
set "TEMP_DIR=%TEMP%\ssisir_odbc_setup"
if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%"

set "ODBC18_LOCAL=%SCRIPT_DIR%msodbcsql18.exe"
set "ODBC17_LOCAL=%SCRIPT_DIR%msodbcsql17.exe"
set "ODBC18_DL=%TEMP_DIR%\msodbcsql18.exe"
set "ODBC17_DL=%TEMP_DIR%\msodbcsql17.exe"

echo [INFO] Checking existing SQL Server ODBC drivers...
reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers" /v "ODBC Driver 18 for SQL Server" >nul 2>&1
if %errorlevel%==0 (
  echo [INFO] ODBC Driver 18 already installed.
  goto :eof
)

reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers" /v "ODBC Driver 17 for SQL Server" >nul 2>&1
if %errorlevel%==0 (
  echo [INFO] ODBC Driver 17 already installed.
  goto :eof
)

echo [INFO] ODBC 18/17 not found. Beginning installation...

if exist "%ODBC18_LOCAL%" (
  echo [INFO] Found local installer: %ODBC18_LOCAL%
  set "ODBC18_EXE=%ODBC18_LOCAL%"
) else (
  echo [INFO] Downloading ODBC Driver 18 installer from aka.ms...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/downloadmsodbcsql18' -OutFile '%ODBC18_DL%' -ErrorAction Stop } catch { exit 1 }"
  set "DL_RC=%errorlevel%"
  if not "%DL_RC%"=="0" (
    echo [ERROR] ODBC Driver 18 download failed from https://aka.ms/downloadmsodbcsql18
  ) else (
    set "ODBC18_EXE=%ODBC18_DL%"
  )
)

if defined ODBC18_EXE (
  echo [INFO] Installing ODBC Driver 18 silently...
  "%ODBC18_EXE%" /quiet /norestart IACCEPTMSODBCSQLLICENSETERMS=YES ADDLOCAL=ALL
  if %errorlevel%==0 (
    echo [INFO] ODBC Driver 18 installation succeeded.
    goto :verify
  ) else (
    echo [WARN] ODBC Driver 18 installation failed. Will try ODBC Driver 17 fallback.
  )
)

if exist "%ODBC17_LOCAL%" (
  echo [INFO] Found local installer: %ODBC17_LOCAL%
  set "ODBC17_EXE=%ODBC17_LOCAL%"
) else (
  echo [INFO] Downloading ODBC Driver 17 installer from aka.ms...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/downloadmsodbcsql17' -OutFile '%ODBC17_DL%' -ErrorAction Stop } catch { exit 1 }"
  set "DL_RC=%errorlevel%"
  if not "%DL_RC%"=="0" (
    echo [ERROR] ODBC Driver 17 download failed from https://aka.ms/downloadmsodbcsql17
  ) else (
    set "ODBC17_EXE=%ODBC17_DL%"
  )
)

if not defined ODBC17_EXE (
  echo [ERROR] Could not acquire ODBC Driver 17 installer.
  exit /b 1
)

echo [INFO] Installing ODBC Driver 17 silently...
"%ODBC17_EXE%" /quiet /norestart IACCEPTMSODBCSQLLICENSETERMS=YES ADDLOCAL=ALL
if not %errorlevel%==0 (
  echo [ERROR] ODBC Driver 17 installation failed.
  exit /b 1
)

echo [INFO] ODBC Driver 17 installation succeeded.

:verify
reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers" /v "ODBC Driver 18 for SQL Server" >nul 2>&1
if %errorlevel%==0 (
  echo [INFO] Verified ODBC Driver 18 is installed.
  exit /b 0
)

reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers" /v "ODBC Driver 17 for SQL Server" >nul 2>&1
if %errorlevel%==0 (
  echo [INFO] Verified ODBC Driver 17 is installed.
  exit /b 0
)

echo [ERROR] ODBC driver installation finished but driver registration was not detected.
exit /b 1
