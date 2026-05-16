@echo off
setlocal EnableDelayedExpansion
for %%I in ("%~dp0.") do set "SCRIPT_ROOT=%%~fI\"

if /I not "%GITHUB_ACTIONS%"=="true" (
  powershell -noprofile -executionPolicy RemoteSigned -file "%SCRIPT_ROOT%build.ps1" -ci -restore -build -pack -publish -binaryLog %*
  exit /b %ERRORLEVEL%
)

set "REPO_ROOT=%SCRIPT_ROOT%.."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"

set "CONFIGURATION=Release"
set "SIGN_TYPE="
if defined DOTNET_INTERACTIVE_SIGN_TYPE set "SIGN_TYPE=%DOTNET_INTERACTIVE_SIGN_TYPE%"

:parse_args
if "%~1"=="" goto parsed_args
if /I "%~1"=="-configuration" (
  if not "%~2"=="" (
    set "CONFIGURATION=%~2"
    shift
    shift
    goto parse_args
  )
)
if /I "%~1"=="--configuration" (
  if not "%~2"=="" (
    set "CONFIGURATION=%~2"
    shift
    shift
    goto parse_args
  )
)
if /I "%~1"=="-c" (
  if not "%~2"=="" (
    set "CONFIGURATION=%~2"
    shift
    shift
    goto parse_args
  )
)
if /I "%~1"=="/p:SignType=Test" set "SIGN_TYPE=Test"
if /I "%~1"=="/p:SignType=Real" set "SIGN_TYPE=Real"
shift
goto parse_args

:parsed_args
set "NUGET_PACKAGES=%REPO_ROOT%\.packages"
set "DisableArcade=1"
if defined GITHUB_ENV echo DisableArcade=1>> "%GITHUB_ENV%"

powershell -noprofile -executionPolicy RemoteSigned -file "%SCRIPT_ROOT%build.ps1" -ci -noDotnet
if errorlevel 1 exit /b %ERRORLEVEL%

set "PACKAGE_VERSION="
if defined GITHUB_REF (
  if /I "!GITHUB_REF:~0,11!"=="refs/tags/v" (
    set "PACKAGE_VERSION=!GITHUB_REF:~11!"
  )
)
if not defined PACKAGE_VERSION if defined OfficialBuildId set "PACKAGE_VERSION=1.0.0-ci.%OfficialBuildId%"
if not defined PACKAGE_VERSION if defined BUILD_BUILDNUMBER set "PACKAGE_VERSION=1.0.0-ci.%BUILD_BUILDNUMBER%"

set "COMMON_PROPS=/p:DisableArcade=1 /p:ContinuousIntegrationBuild=true /p:PackageOutputPath=%REPO_ROOT%\artifacts\packages\%CONFIGURATION%\Shipping"
if defined PACKAGE_VERSION set "COMMON_PROPS=%COMMON_PROPS% /p:PackageVersion=%PACKAGE_VERSION%"
if defined SIGN_TYPE set "COMMON_PROPS=%COMMON_PROPS% /p:SignType=%SIGN_TYPE%"

if not exist "%REPO_ROOT%\artifacts\log\%CONFIGURATION%" (
  mkdir "%REPO_ROOT%\artifacts\log\%CONFIGURATION%"
)

dotnet restore "%REPO_ROOT%\dotnet-interactive.sln" %COMMON_PROPS%
if errorlevel 1 exit /b %ERRORLEVEL%

dotnet build "%REPO_ROOT%\dotnet-interactive.sln" -c %CONFIGURATION% --no-restore /bl:"%REPO_ROOT%\artifacts\log\%CONFIGURATION%\Build.binlog" %COMMON_PROPS%
if errorlevel 1 exit /b %ERRORLEVEL%

dotnet pack "%REPO_ROOT%\dotnet-interactive.sln" -c %CONFIGURATION% %COMMON_PROPS%
exit /b %ERRORLEVEL%
