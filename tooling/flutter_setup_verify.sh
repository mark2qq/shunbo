#!/usr/bin/env bash
set -u
export PATH="$PATH:/d/flutter/bin"
cd /e/TV/shunbo
LOG=/e/TV/shunbo/tooling/flutter_setup.log
echo "=== [$(date)] flutter setup & verify ===" | tee -a "$LOG"
echo "--- flutter --version ---" | tee -a "$LOG"
flutter --version 2>&1 | tee -a "$LOG"
echo "--- flutter pub get ---" | tee -a "$LOG"
flutter pub get 2>&1 | tee -a "$LOG"
echo "--- flutter analyze ---" | tee -a "$LOG"
flutter analyze 2>&1 | tee -a "$LOG"
echo "--- flutter test ---" | tee -a "$LOG"
flutter test 2>&1 | tee -a "$LOG"
echo "=== [$(date)] DONE (exit $?) ===" | tee -a "$LOG"
