#!/usr/bin/env bash
# ============================================================================
# check_env.sh — разведка окружения стенда перед воспроизведением уязвимости
# модуля extstatus (nginx 1.24.0, ngx_http_exstatus_module).
# Запуск:  sudo bash check_env.sh
# Скрипт только ЧИТАЕТ информацию и ничего не меняет на стенде.
#
# Бинарник определяется автоматически: сначала syngx (форк), затем nginx.
# Нестандартное имя/путь задаётся переменной окружения, например:
#   NGINX_BIN=/opt/syngx/sbin/syngx sudo -E bash check_env.sh
# ============================================================================
set -u

hr() { printf '\n===== %s =====\n' "$1"; }

# ---- автоопределение бинарника (nginx или форк, например syngx) ----
if [ -n "${NGINX_BIN:-}" ]; then
  BIN="$NGINX_BIN"
else
  BIN=''
  for b in syngx nginx /usr/sbin/syngx /usr/sbin/nginx \
           /usr/local/sbin/syngx /usr/local/sbin/nginx /usr/local/nginx/sbin/nginx; do
    if command -v "$b" >/dev/null 2>&1 || { [ -x "$b" ] && [ -f "$b" ]; }; then
      BIN="$b"; break
    fi
  done
  BIN="${BIN:-nginx}"
fi
BNAME=$(basename "$BIN")
echo "Используемый бинарник: $BIN"

hr "1. Версия и сборка $BNAME"
"$BIN" -V 2>&1
echo
echo "Параметры модулей в сборке (--add-module / --add-dynamic-module):"
"$BIN" -V 2>&1 | grep -oE '\-\-add-(dynamic-)?module=[^ ]+' || echo '  (параметры add-module не найдены)'
if "$BIN" -V 2>&1 | grep -qiE 'exstatus'; then
  echo '  [OK] в параметрах сборки найден модуль exstatus'
else
  echo '  [!] ВНИМАНИЕ: exstatus в параметрах сборки не найден — сверьте вывод выше вручную,'
  echo '      возможно, модуль собран под другим именем пути или это не тот стенд'
fi

hr "2. Поиск эндпоинтов мониторинга в конфигурации"
# $BNAME -T выводит итоговую конфигурацию со всеми включёнными файлами
"$BIN" -T 2>/dev/null | grep -niE 'extstatus|prometheus|status_json|status_prometheus' \
  || echo "[!] Директивы не найдены через $BNAME -T. Попробуйте: sudo $BNAME -T 2>/dev/null | less"

hr "3. Пути к логам (из параметров сборки)"
"$BIN" -V 2>&1 | grep -oE '\-\-(error|access)-log-path=[^ ]+' || true
echo '(если пути не показаны — логи заданы в конфигурации, ищите на шаге 2)'

hr "4. Процессы $BNAME (мастер и воркеры)"
pout=$(ps -o pid,ppid,etime,rss,vsz,cmd -C "$BNAME" 2>/dev/null)
if [ "$(printf '%s\n' "$pout" | wc -l)" -le 1 ]; then
  pout=$(ps -o pid,ppid,etime,rss,vsz,cmd -C nginx 2>/dev/null)
fi
echo "${pout:-[!] Процессов $BNAME/nginx не найдено}"

hr "5. Потребление виртуальной памяти процессами (VmPeak/VmSize, КиБ)"
pids="$(pgrep -x "$BNAME" 2>/dev/null || true)"
[ -z "$pids" ] && pids="$(pgrep -x nginx 2>/dev/null || true)"
for p in $pids; do
  cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
  echo "--- PID $p (${cmd})"
  grep -E 'VmPeak|VmSize|VmRSS' "/proc/$p/status" 2>/dev/null || echo '    (нет доступа к /proc)'
done

hr "6. Доступные утилиты"
for c in python3 curl prlimit gdb addr2line dmesg jq free stat systemd-run; do
  if command -v "$c" >/dev/null 2>&1; then echo "  есть:      $c"; else echo "  ОТСУТСТВУЕТ: $c"; fi
done

# ---- имя systemd-юнита (syngx.service или nginx.service) ----
UNIT="${NGINX_UNIT:-}"
if [ -z "$UNIT" ] && command -v systemctl >/dev/null 2>&1; then
  for u in "$BNAME" nginx syngx; do
    if systemctl list-unit-files "$u.service" --no-legend 2>/dev/null | grep -q "^$u\.service"; then
      UNIT="$u.service"; break
    fi
  done
fi

hr "7. systemd и контрольная группа (cgroup)"
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
  echo "  systemd активен"
  if [ -n "$UNIT" ]; then
    echo "  юнит: $UNIT, состояние: $(systemctl is-active "$UNIT" 2>/dev/null || echo 'не активен')"
    systemctl show "$UNIT" -p MemoryMax -p MemorySwapMax 2>/dev/null | sed 's/^/  /'
  else
    echo "  юнит $BNAME.service/nginx.service не найден — сервис, вероятно, запущен вручную"
  fi
else
  echo "  systemd недоступен ($BNAME, вероятно, запущен вручную или в контейнере)"
fi
fstype=$(stat -fc %T /sys/fs/cgroup 2>/dev/null)
[ "$fstype" = "cgroup2fs" ] && echo "  контроллер: cgroup v2" || echo "  контроллер: cgroup v1 или неопределён ($fstype)"

hr "8. Оперативная память стенда"
free -m 2>/dev/null || true
grep MemAvailable /proc/meminfo 2>/dev/null || true

hr "9. Права на dmesg и параметры core dump"
if dmesg -T 2>/dev/null | head -1 >/dev/null; then
  echo "  dmesg доступен"
else
  echo "  dmesg требует sudo (запускайте скрипты через sudo)"
fi
echo "  core_pattern: $(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
echo "  ulimit -c (текущая сессия): $(ulimit -c)"
if command -v coredumpctl >/dev/null 2>&1; then
  echo "  coredumpctl есть; список дампов: coredumpctl list $BNAME"
fi

hr "10. Что зафиксировать перед началом работы"
echo "  а) URL эндпоинтов мониторинга (из шага 2), например:"
echo "     http://127.0.0.1:ПОРТ/ПУТЬ_json   и   http://127.0.0.1:ПОРТ/ПУТЬ_prometheus"
echo "  б) путь к error.log (из шага 3)"
echo "  в) число воркеров и их PID (из шага 4)"
echo
echo "Разведка завершена. Дальше — по инструкции (Этап 0, шаги 1-5)."
