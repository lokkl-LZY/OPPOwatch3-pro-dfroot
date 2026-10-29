@echo off
chcp 65001 >nul
setlocal EnableExtensions
title OWW211 One-Click Root
cd /d "%~dp0"

rem ============================================================
rem  找 Git Bash（多路兜底）
rem    0) 手动指定：set BASH=D:\Git\bin\bash.exe
rem    1) PATH 里的 bash（排除 WSL 的 C:\Windows\System32\bash.exe）
rem    2) 常见安装位置（逐条 if exist）
rem    3) 注册表 InstallPath
rem    4) 从 git.exe 反推 ..\bin\bash.exe
rem
rem  注意：这里不能用 for %%P in (...) 列表装 "%ProgramFiles(x86)%"，
rem        因为展开后的 "(x86)" 里的右括号会提前闭合 for 块。
rem ============================================================
set "BASH="

rem -- 1) PATH（跳过 WSL）--
for /f "delims=" %%I in ('where bash 2^>nul') do (
  if not defined BASH echo %%I | find /i "\Windows\System32\" >nul || set "BASH=%%I"
)

rem -- 2) 常见安装位置 --
set "PF86=%ProgramFiles(x86)%"
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe"          set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles%\Git\usr\bin\bash.exe"      set "BASH=%ProgramFiles%\Git\usr\bin\bash.exe"
if not defined BASH if exist "%PF86%\Git\bin\bash.exe"                  set "BASH=%PF86%\Git\bin\bash.exe"
if not defined BASH if exist "%PF86%\Git\usr\bin\bash.exe"              set "BASH=%PF86%\Git\usr\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe"     set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\usr\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\usr\bin\bash.exe"
if not defined BASH if exist "%USERPROFILE%\scoop\apps\git\current\bin\bash.exe"     set "BASH=%USERPROFILE%\scoop\apps\git\current\bin\bash.exe"
if not defined BASH if exist "%USERPROFILE%\scoop\apps\git\current\usr\bin\bash.exe" set "BASH=%USERPROFILE%\scoop\apps\git\current\usr\bin\bash.exe"
if not defined BASH if exist "%ProgramData%\chocolatey\lib\git\tools\bin\bash.exe"   set "BASH=%ProgramData%\chocolatey\lib\git\tools\bin\bash.exe"
if not defined BASH if exist "%~dp0PortableGit\bin\bash.exe"      set "BASH=%~dp0PortableGit\bin\bash.exe"
if not defined BASH if exist "%~dp0PortableGit\usr\bin\bash.exe"  set "BASH=%~dp0PortableGit\usr\bin\bash.exe"
if not defined BASH if exist "%~dp0git\bin\bash.exe"              set "BASH=%~dp0git\bin\bash.exe"
if not defined BASH if exist "%USERPROFILE%\PortableGit\bin\bash.exe" set "BASH=%USERPROFILE%\PortableGit\bin\bash.exe"

rem -- 3) 注册表 --
if not defined BASH for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do (
  if exist "%%B\bin\bash.exe" set "BASH=%%B\bin\bash.exe"
)
if not defined BASH for /f "tokens=2,*" %%A in ('reg query "HKCU\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do (
  if exist "%%B\bin\bash.exe" set "BASH=%%B\bin\bash.exe"
)
if not defined BASH for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\WOW6432Node\GitForWindows" /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do (
  if exist "%%B\bin\bash.exe" set "BASH=%%B\bin\bash.exe"
)

rem -- 4) 从 git.exe 反推 --
if not defined BASH for /f "delims=" %%I in ('where git 2^>nul') do (
  if not defined BASH if exist "%%~dpI..\bin\bash.exe" for %%D in ("%%~dpI..\bin\bash.exe") do set "BASH=%%~fD"
)

if not defined BASH goto :nobash

rem ---- 检查 python ----
set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY where py >nul 2>nul && set "PY=py"
if not defined PY (
  echo.
  echo  [!] 没有找到 Python（打 adbd 补丁要用）。
  echo      安装 Python 3: https://www.python.org/downloads/
  echo      安装时勾选 "Add Python to PATH"。
  echo.
  pause
  exit /b 1
)

echo.
echo  bash   : %BASH%
echo  python : %PY%
echo.
echo  开始一键 root。保持手表连接、屏幕解锁。
echo.
set "PYTHON=%PY%"
"%BASH%" "%~dp0root_oneclick.sh"

echo.
echo  ==============================================
echo   结束。按任意键关闭。
echo  ==============================================
pause >nul
exit /b 0

:nobash
echo.
echo  [!] 没有找到 Git Bash（bash.exe）。
echo.
echo  已检查：
echo      PATH 中的 bash（已排除 WSL 的 System32\bash.exe）
echo      Program Files / Program Files (x86) 下的 Git
echo      LocalAppData\Programs\Git
echo      scoop / chocolatey
echo      注册表 HKLM/HKCU\SOFTWARE\GitForWindows\InstallPath
echo      从 git.exe 反推 ..\bin\bash.exe
echo      脚本同目录的 PortableGit
echo.
echo  解决办法（任选其一）：
echo    1) 安装 Git for Windows: https://git-scm.com/download/win
echo       安装时选 "Git from the command line and also from 3rd-party software"
echo    2) 手动指定后再运行：
echo         set BASH=D:\你的Git目录\bin\bash.exe
echo         一键root.cmd
echo.
pause
exit /b 1
