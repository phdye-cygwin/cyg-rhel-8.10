@echo off
rem Thin wrapper so the one-shot installer runs from cmd or a double-click.
rem All work is in install-all.ps1; arguments pass straight through, e.g.
rem   install-all.cmd -DryRun
rem   install-all.cmd -Root C:\cyg-rhel-8.10\cygwin64 -Shortcut
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-all.ps1" %*
