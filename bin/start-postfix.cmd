@echo off
rem Wrapper the logon Scheduled Task runs: starts the unprivileged Postfix
rem master via the replica's bash. Edit both lines below for your install --
rem BASH is the replica's bash.exe, LAUNCH is the POSIX path to the launcher.
set "BASH=C:\cyg-rhel-8.10\cygwin64\bin\bash.exe"
set "LAUNCH=/home/USER/repo/cyg-rhel-8.10/bin/postfix-user-launch.sh"
rem Clear HOME so the replica's bash resolves it from its own /etc/passwd
rem rather than inheriting the primary Cygwin's home.
set "HOME="
"%BASH%" -lc "%LAUNCH% start"
