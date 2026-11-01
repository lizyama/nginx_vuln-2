#!/usr/bin/env bash
# ============================================================================
# reload_probe.sh — Сценарий 1 «пустая статистика».
# Выполняет мягкую перезагрузку воркеров (systemctl reload либо <бинарник> -s reload —
# БЕЗ остановки сервиса), затем делает ПЕРВЫЙ запрос к эндпоинту мониторинга
# и сверяет логи: если воркер упал по сигналу — скрипт печатает [!] ПАДЕНИЕ.
#
# Использование:  sudo bash reload_probe.sh <URL> [число_попыток]
# Пример:         sudo bash reload_probe.sh http://127.0.0.1:8080/status 8
#
# Бинарник определяется автоматически (syngx/nginx); имя можно задать вручную:
#   NGINX_BIN=/opt/syngx/sbin/syngx sudo -E bash reload_probe.sh <URL>
# Тела ответов сохраняются в /tmp/probe_<номер>.bin для последующей сверки.
# ============================================================================
set -u

URL="${1:?Использование: reload_probe.sh <URL> [число_попыток]}"
N="${2:-5}"

# ---- автоопределение бинарника (nginx или форк, например syngx) ----
if [ -n "${NGINX_BIN:-}" ]; then
  BIN="$NGINX_BIN"
else
  BIN=''
  for b in syngx nginx /usr/sbin/syngx /usr/sbin/nginx \
           /usr/local/sbin/syngx /usr/local/sbin/nginx; do
    if command -v "$b" >/dev/null 2>&1 || { [ -x "$b" ] && [ -f "$b" ]; }; then
      BIN="$b"; break
    fi
  done
  BIN="${BIN:-nginx}"
fi
BNAME=$(basename "$BIN")

# ---- systemd-юнит (если сервис управляется через systemctl) ----
UNIT="${NGINX_UNIT:-}"
if [ -z "$UNIT" ] && command -v systemctl >/dev/null 2>&1; then
  for u in "$BNAME" nginx syngx; do
    if systemctl list-unit-files "$u.service" --no-legend 2>/dev/null | grep -q "^$u\.service"; then
      UNIT="$u.service"; break
    fi
  done
fi

# ---- мягкая перезагрузка воркеров (только reload, без stop/start) ----
do_reload() {
  if [ -n "$UNIT" ] && systemctl is-active "$UNIT" >/dev/null 2>&1; then
    systemctl reload "$UNIT"
  else
    "$BIN" -s reload
  fi
}

# Путь к error.log: из параметров сборки, иначе первый существующий стандартный
LOG=$("$BIN" -V 2>&1 | grep -oE '\-\-error-log-path=[^ ]+' | head -1 | cut -d= -f2)
if [ -z "$LOG" ]; then
  for cand in /var/log/nginx/error.log /var/log/syngx/error.log; do
    [ -f "$cand" ] && { LOG="$cand"; break; }
  done
fi
LOG="${LOG:-/var/log/nginx/error.log}"
echo "Бинарник:       $BIN"
echo "Юнит systemd:   ${UNIT:-нет (перезагрузка через $BNAME -s reload)}"
echo "URL:            $URL"
echo "Число попыток:  $N"
echo "error.log:      $LOG"

crashes=0
for i in $(seq 1 "$N"); do
  echo "--------------------------------------------------------------"
  echo "Попытка $i из $N"

  before=$(pgrep -f '(nginx|syngx): worker process' | sort | tr '\n' ',')
  mark=$(wc -l < "$LOG" 2>/dev/null || echo 0)

  # 1) Мягкий перезапуск воркеров (конфигурация и мастер не меняются)
  if ! do_reload; then
    echo "[!] Перезагрузка не удалась (нужен root?). Проверьте вручную: sudo $BNAME -s reload"
    exit 1
  fi
  sleep 1

  # 2) ПЕРВЫЙ запрос к эндпоинту после перезапуска воркеров
  code=$(curl -s --max-time 5 -o "/tmp/probe_${i}.bin" -w '%{http_code}' "$URL")
  rc=$?
  size=$(stat -c%s "/tmp/probe_${i}.bin" 2>/dev/null || echo 0)
  echo "  curl: код_ответа=${code:-нет} код_возврата=$rc размер=${size} байт"
  case "$rc" in
    52) echo '  [!] curl 52 — «пустой ответ»: соединение закрыли до отправки данных';;
    56) echo '  [!] curl 56 — соединение сброшено (возможно, упал воркер)';;
    18) echo '  [!] curl 18 — ответ оборван, переданы не все данные (аномалия размера)';;
  esac

  # 3) Ищем в НОВЫХ строках лога сообщения о гибели воркера
  new=$(tail -n +"$((mark + 1))" "$LOG" 2>/dev/null \
        | grep -E 'exited on signal|signal SIGSEGV|core dump')
  if [ -n "$new" ]; then
    echo "  [!] ПАДЕНИЕ ВОРКЕРА:"
    echo "$new" | sed 's/^/        /'
    crashes=$((crashes + 1))
  fi

  after=$(pgrep -f '(nginx|syngx): worker process' | sort | tr '\n' ',')
  if [ "$before" != "$after" ]; then
    echo "  [i] состав воркеров изменился (мастер пересоздал процессы)"
  fi

  sleep 1
done

echo "=============================================================="
if [ "$crashes" -gt 0 ]; then
  echo "ИТОГ: падений зафиксировано: $crashes из $N попыток."
  echo "Уязвимость воспроизведена. Переходите к фиксации улик (collect_evidence.sh)."
else
  echo "ИТОГ: падений не зафиксировано за $N попыток."
  echo "Ветку «пустой статистики» на этой конфигурации не задействовали."
  echo "Это НЕ опровержение уязвимости — переходите к Сценарию 2 (нехватка памяти)."
fi
echo "Тела ответов сохранены: /tmp/probe_*.bin"
