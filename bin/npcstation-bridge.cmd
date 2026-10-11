@echo off
pushd "%~dp0\.."
call tools\bootstrap\python.bat tools\npcstation_bridge\bridge.py %*
popd

