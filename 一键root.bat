@echo off
rem 统一入口：所有检测/流程都在 一键root.cmd 里，这里只转发，避免两套逻辑不一致
chcp 65001 >nul
cd /d "%~dp0"
if not exist "%~dp0一键root.cmd" (
  echo [!] 同目录下缺少 一键root.cmd
  pause
  exit /b 1
)
call "%~dp0一键root.cmd"
