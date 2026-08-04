@echo off
rem Fake exiftool launcher for Windows: defers to the Node stub.
node "%~dp0exiftool.mjs" %*
