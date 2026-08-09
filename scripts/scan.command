#!/bin/zsh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/launcher-config" scan
STATUS=$?

echo
if (( STATUS == 0 )); then
  echo "Сканирование завершено. Нажмите любую клавишу, чтобы закрыть окно."
else
  echo "Сканирование завершилось с ошибкой $STATUS. Нажмите любую клавишу, чтобы закрыть окно."
fi
read -k 1
exit "$STATUS"
