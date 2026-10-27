@echo off
rem Install: Docker Desktop if missing, then build and start the system,
rem desktop shortcuts. Progress is shown in a window. Safe to run again.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\balans.ps1" install
