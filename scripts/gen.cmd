@echo off
rem gen.cmd -- launcher for gen.ps1 (PowerShell, no Python needed)
rem Usage: gen.cmd --prompt-file prompt.txt --out out.png
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gen.ps1" %*
exit /b %ERRORLEVEL%
