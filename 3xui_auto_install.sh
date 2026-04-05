#!/usr/bin/env bash
set -Eeuo pipefail

# Made with love for U1Host
# 3x-ui auto installer for Ubuntu/Debian
# Target: 3x-ui v2.8.10 + VLESS XHTTP TLS + ECH artifacts
# Author: YaFoxin Dev
# Telegram: https://t.me/yafoxindev
# GitHub: https://github.com/yafoxins
# Authoring basis: proven working config from user
#
# Notes:
# - Uses acme.sh for DOMAIN cert issuance
# - Uses 3x-ui installer non-interactively
# - Feeds installer a fixed panel port and custom SSL cert paths
# - Creates inbound directly in x-ui.db
# - Generates echServerKeys for server and ECH config for clients
# - Prints panel credentials and client data at the end

VERSION="v2.8.10"
INSTALLER_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
DB_PATH="/etc/x-ui/x-ui.db"
XUI_BIN="/usr/local/x-ui/x-ui"
XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
ARTIFACT_DIR="/root/3xui-install-artifacts"
BLOCKED_PORTS=(25 26 465 587 2525 1025 8025)

ERROR_TRAP_FIRED=0

on_error() {
  local line="$1"
  if [[ "${ERROR_TRAP_FIRED}" == "1" ]]; then
    return
  fi
  ERROR_TRAP_FIRED=1

  echo
  echo -e "${red}════════════════════════════════════════════════${plain}" >&2
  echo -e "${red}[ERR] Установка остановлена из-за ошибки.${plain}" >&2
  echo -e "${red}[ERR] Строка скрипта: ${line}${plain}" >&2
  echo >&2
  echo "Что сделать дальше:" >&2
  echo "  1) Скопируйте текст ошибки выше." >&2
  echo "  2) Если есть диагностический файл, приложите его." >&2
  echo "  3) Создайте тикет в поддержку хоста и приложите эти данные." >&2
  echo >&2
  echo "Если файл уже был создан, приложите его в тикет:" >&2
  echo "  ${ARTIFACT_DIR}/${DOMAIN:-unknown}_inbound_debug.txt" >&2
  echo >&2
  echo "Также можно приложить:" >&2
  echo "  journalctl -u x-ui -n 120 --no-pager" >&2
  echo "  systemctl status x-ui --no-pager -l" >&2
  echo -e "${red}════════════════════════════════════════════════${plain}" >&2
}
trap 'on_error ${LINENO}' ERR

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
blue='\033[0;34m'
plain='\033[0m'

msg() { echo -e "${green}[OK]${plain} $*"; }
warn() { echo -e "${yellow}[WARN]${plain} $*"; }
err() { echo -e "${red}[ERR]${plain} $*" >&2; }
info() { echo -e "${blue}[INFO]${plain} $*"; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "Запусти скрипт от root."
    exit 1
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

wait_for_apt_lock() {
  local timeout="${1:-900}"
  local waited=0

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1      || fuser /var/lib/dpkg/lock >/dev/null 2>&1      || fuser /var/lib/apt/lists/lock >/dev/null 2>&1      || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "Сейчас заняты apt/dpkg lock-файлы. Жду завершения unattended-upgrades или другого apt-процесса."
    fi
    if (( waited >= timeout )); then
      err "Не удалось дождаться освобождения apt/dpkg lock за ${timeout} секунд."
      err "Обычно это значит, что ещё работает unattended-upgrades или другой apt-процесс."
      err "Проверь:"
      err "  ps -fp \$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null)"
      err "  systemctl status unattended-upgrades --no-pager -l"
      return 1
    fi
    sleep 5
    ((waited+=5))
  done

  return 0
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  wait_for_apt_lock 900

  apt-get -o Acquire::Retries=3 update -y
  wait_for_apt_lock 900

  apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y \
    curl wget jq sqlite3 openssl cron socat ca-certificates dnsutils gawk sed grep coreutils procps iproute2

  systemctl enable cron >/dev/null 2>&1 || true
  systemctl start cron >/dev/null 2>&1 || true
}

random_string() {
  local len="${1:-16}"
  local bytes=$(( len + 16 ))
  local raw=""
  raw="$(openssl rand -hex "${bytes}")" || return 1
  printf '%s' "${raw:0:${len}}"
}

random_uuid() {
  if command_exists uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

random_subid() {
  local raw=""
  raw="$(openssl rand -hex 8)" || return 1
  printf '%s' "${raw:0:16}"
}

get_public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsS --max-time 10 https://ifconfig.me || true)"
  fi
  echo "$ip"
}

get_public_ipv6() {
  local ip=""
  ip="$(curl -6 -fsS --max-time 10 https://api64.ipify.org || true)"
  echo "$ip"
}

resolve_a_records() {
  local domain="$1"
  dig +short A "$domain" | awk 'NF' | sort -u || true
}

resolve_aaaa_records() {
  local domain="$1"
  dig +short AAAA "$domain" | awk 'NF && /:/{print}' | sort -u || true
}


print_dns_guidance() {
  local ipv4="$1"
  print_block_title "[ ШАГ 1 / 4 ] Проверка DNS перед установкой"

  echo "Найден внешний IPv4 сервера: ${ipv4}"
  echo
  echo "Перед продолжением направьте ваш домен на этот IP:"
  echo "  @    -> ${ipv4}"
  echo "  www  -> ${ipv4}"
  echo
  echo "Важно:"
  echo "  - нужна именно A-запись домена, а не PTR-запись;"
  echo "  - PTR менять не нужно;"
  echo "  - если вы используете поддомен, он тоже должен указывать на ${ipv4};"
  echo "  - если DNS ещё не обновился, выпуск SSL-сертификата не сработает."
}

print_banner() {
  echo
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║            3x-ui XHTTP Auto Installer               ║"
  echo "║              Made with love for U1Host              ║"
  echo "║           Friendly setup by YaFoxin Dev             ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo
}

print_block_title() {
  local title="$1"
  echo
  echo "══════════════════════════════════════════════════════"
  echo "$title"
  echo "══════════════════════════════════════════════════════"
}

press_enter_to_continue() {
  local prompt="${1:-Нажмите Enter, чтобы продолжить...}"
  echo
  read -r -p "$prompt" _
}

tcp_port_in_use() {
  local port="$1"
  ss -ltnH "( sport = :${port} )" 2>/dev/null | grep -q .
}

port_is_blocked() {
  local port="$1"
  local blocked
  for blocked in "${BLOCKED_PORTS[@]}"; do
    [[ "$port" == "$blocked" ]] && return 0
  done
  return 1
}

pick_random_free_port_from_ranges() {
  local ranges=("$@")
  local candidates=()
  local range start end p

  for range in "${ranges[@]}"; do
    start="${range%%:*}"
    end="${range##*:}"
    for ((p=start; p<=end; p++)); do
      if ! port_is_blocked "$p"; then
        candidates+=("$p")
      fi
    done
  done

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    return 1
  fi

  while IFS= read -r p; do
    if ! tcp_port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done < <(printf '%s\n' "${candidates[@]}" | shuf)

  return 1
}

prompt_connection_word() {
  while true; do
    print_block_title "[ ШАГ 3 / 4 ] Слово для ссылки подключения"

    echo "Введите короткое слово, которое станет частью ссылки подключения."
    echo "Это просто часть адреса. Скрипт сам превратит его в путь вида /ваше_слово/."
    echo
    echo "Подойдут такие примеры:"
    echo "  foxgate"
    echo "  stream_room"
    echo "  myserver01"
    echo "  u1host_link"
    echo
    echo "Не подойдут:"
    echo "  моибуквы"
    echo "  my server"
    echo "  test/path"
    echo "  test?123"
    echo
    echo "Требования:"
    echo "  - только английские буквы, цифры и _"
    echo "  - без пробелов"
    echo "  - длина от 4 до 32 символов"
    echo

    read -rp "Введите слово для ссылки подключения: " CONNECTION_WORD
    CONNECTION_WORD="$(printf '%s' "$CONNECTION_WORD" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    if [[ ! "$CONNECTION_WORD" =~ ^[A-Za-z0-9_]{4,32}$ ]]; then
      err "Неверный формат. Примеры правильного ввода: foxgate, stream_room, myserver01"
      continue
    fi

    msg "Слово принято: ${CONNECTION_WORD}"
    msg "Будущий путь подключения: /${CONNECTION_WORD}/"
    return 0
  done
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local val=""
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " val
    echo "${val:-$default}"
  else
    read -rp "$prompt: " val
    echo "$val"
  fi
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
}

stop_services_using_80() {
  local services=(nginx apache2 httpd caddy x-ui)
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc"; then
      warn "Временно останавливаю $svc для standalone-проверки на 80 порту."
      systemctl stop "$svc" || true
    fi
  done
}

start_services_using_80() {
  local services=(nginx apache2 httpd caddy)
  for svc in "${services[@]}"; do
    if systemctl list-unit-files | grep -q "^${svc}\.service"; then
      systemctl start "$svc" || true
    fi
  done
}

ensure_acme() {
  local email="$1"
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    info "Устанавливаю acme.sh"
    curl https://get.acme.sh | sh -s "email=${email}"
  fi
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true

  local cron_ok="0"
  if crontab -l 2>/dev/null | grep -q '/root/.acme.sh/acme.sh'; then
    cron_ok="1"
  fi
  if [[ "$cron_ok" != "1" ]]; then
    warn "Не нашёл cron-задачу acme.sh, добавляю."
    (crontab -l 2>/dev/null; echo '18 3 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" >/dev/null') | crontab -
  fi
}

issue_domain_cert() {
  local domain="$1"
  stop_services_using_80
  mkdir -p "/root/cert/${domain}"

  /root/.acme.sh/acme.sh --issue -d "${domain}" --standalone --force
  /root/.acme.sh/acme.sh --install-cert -d "${domain}" \
    --key-file "/root/cert/${domain}/privkey.pem" \
    --fullchain-file "/root/cert/${domain}/fullchain.pem" \
    --reloadcmd "systemctl restart x-ui || true"

  start_services_using_80

  if [[ ! -s "/root/cert/${domain}/fullchain.pem" || ! -s "/root/cert/${domain}/privkey.pem" ]]; then
    err "Сертификат для домена не выпущен или не установлен в /root/cert/${domain}"
    exit 1
  fi

  chmod 600 "/root/cert/${domain}/privkey.pem" || true
  chmod 644 "/root/cert/${domain}/fullchain.pem" || true
  msg "Сертификат для ${domain} готов."
}

download_3xui_installer() {
  local dest="/tmp/3xui_install.sh"
  curl -fsSL "${INSTALLER_URL}" -o "${dest}"
  chmod +x "${dest}"
  echo "${dest}"
}

run_3xui_installer_noninteractive() {
  local installer="$1"
  local panel_port="$2"
  local panel_domain="$3"
  local panel_cert="$4"
  local panel_key="$5"

  # Fresh install path in official installer:
  # y -> choose custom panel port
  # <port>
  # 3 -> custom cert path
  # <domain>
  # <cert path>
  # <key path>
  # This matches the prompts in upstream install.sh.
  printf 'y\n%s\n3\n%s\n%s\n%s\n' \
    "${panel_port}" \
    "${panel_domain}" \
    "${panel_cert}" \
    "${panel_key}" | VERSION="${VERSION}" bash "${installer}" "${VERSION}"
}

ensure_xui_cli_settings() {
  local username="$1"
  local password="$2"
  local port="$3"
  local webbase="$4"
  local cert="$5"
  local key="$6"

  "${XUI_BIN}" setting -username "${username}" -password "${password}" -port "${port}" -webBasePath "${webbase}" >/dev/null 2>&1 || true
  "${XUI_BIN}" cert -webCert "${cert}" -webCertKey "${key}" >/dev/null 2>&1 || true

  systemctl restart x-ui
  sleep 2
}

generate_ech_material() {
  local domain="$1"
  local server_key=""
  local client_cfg=""

  if [[ ! -x "${XRAY_BIN}" ]]; then
    err "Не найден ${XRAY_BIN}"
    exit 1
  fi

  server_key="$("${XRAY_BIN}" tls ech --serverName "${domain}" 2>/dev/null | tail -n 1 | tr -d '\r')"
  if [[ -z "${server_key}" ]]; then
    err "Не удалось сгенерировать ECH Server Key."
    exit 1
  fi

  client_cfg="$("${XRAY_BIN}" tls ech -i "${server_key}" 2>/dev/null | tail -n 1 | tr -d '\r')"
  if [[ -z "${client_cfg}" ]]; then
    warn "Не удалось извлечь ECH config list из server key. Продолжаю без извлечения."
  fi

  mkdir -p "${ARTIFACT_DIR}"
  printf '%s\n' "${server_key}" > "${ARTIFACT_DIR}/${DOMAIN}_ech_server_key.txt"
  printf '%s\n' "${client_cfg}" > "${ARTIFACT_DIR}/${DOMAIN}_ech_config_list.txt"

  ECH_SERVER_KEY="${server_key}"
  ECH_CONFIG_LIST="${client_cfg}"
}

wait_for_db() {
  local i
  for i in {1..30}; do
    if [[ -s "${DB_PATH}" ]]; then
      return 0
    fi
    sleep 1
  done
  err "Не дождался появления ${DB_PATH}"
  exit 1
}

ensure_db_schema() {
  sqlite3 "${DB_PATH}" ".tables" | grep -q "inbounds" || {
    err "В базе 3x-ui не найдена таблица inbounds."
    exit 1
  }
}

db_list_inbound_columns() {
  sqlite3 "${DB_PATH}" "PRAGMA table_info(inbounds);" | awk -F'|' '{print $2}'
}

db_has_inbound_column() {
  local col="$1"
  db_list_inbound_columns | grep -Fxq "$col"
}

delete_existing_port_inbound() {
  local inbound_port="$1"
  sqlite3 "${DB_PATH}" "DELETE FROM inbounds WHERE port=${inbound_port};" || true
}

json_compact() {
  local input=""
  input="$(cat)"
  if [[ -z "${input}" ]]; then
    err "Внутренняя ошибка: попытка упаковать пустой JSON."
    return 1
  fi

  if command_exists jq; then
    printf '%s' "${input}" | jq -c . 2>/dev/null && return 0
  fi

  printf '%s' "${input}" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), ensure_ascii=False, separators=(",",":")))' || {
    err "Не удалось обработать JSON для записи в базу 3x-ui."
    return 1
  }
}

json_escape_sql() {
  python3 -c 'import sys; data = sys.stdin.read(); print(data.replace("\x27", "\x27\x27"))'
}

create_inbound() {
  local inbound_port="$1"
  local domain="$2"
  local path="$3"
  local uuid="$4"
  local email="$5"
  local subid="$6"
  local cert="/root/cert/${domain}/fullchain.pem"
  local key="/root/cert/${domain}/privkey.pem"

  local stream_settings
  local settings
  local sniffing
  local allocate
  local tag="inbound-${inbound_port}"
  local remark="XHTTP"

  read -r -d '' settings <<EOF || true
{
  "clients": [
    {
      "id": "${uuid}",
      "flow": "",
      "email": "${email}",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "${subid}",
      "comment": "",
      "reset": 0
    }
  ],
  "decryption": "none",
  "encryption": "none"
}
EOF

  read -r -d '' stream_settings <<EOF || true
{
  "network": "xhttp",
  "security": "tls",
  "externalProxy": [],
  "tlsSettings": {
    "serverName": "${domain}",
    "minVersion": "1.2",
    "maxVersion": "1.3",
    "cipherSuites": "",
    "rejectUnknownSni": false,
    "disableSystemRoot": false,
    "enableSessionResumption": false,
    "certificates": [
      {
        "certificateFile": "${cert}",
        "keyFile": "${key}",
        "oneTimeLoading": false,
        "usage": "encipherment",
        "buildChain": false
      }
    ],
    "alpn": [
      "h2",
      "http/1.1"
    ],
    "echForceQuery": "none",
    "echServerKeys": "${ECH_SERVER_KEY}"
  },
  "xhttpSettings": {
    "headers": {},
    "host": "${domain}",
    "mode": "stream-up",
    "noSSEHeader": false,
    "path": "${path}",
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000",
    "scStreamUpServerSecs": "20-80",
    "seqKey": "",
    "seqPlacement": "",
    "sessionKey": "",
    "sessionPlacement": "",
    "uplinkChunkSize": 0,
    "uplinkDataKey": "",
    "uplinkDataPlacement": "",
    "uplinkHTTPMethod": "",
    "xPaddingBytes": "100-1000",
    "xPaddingHeader": "",
    "xPaddingKey": "",
    "xPaddingMethod": "",
    "xPaddingObfsMode": false,
    "xPaddingPlacement": ""
  }
}
EOF

  read -r -d '' sniffing <<'EOF' || true
{
  "enabled": false,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": false
}
EOF

  allocate='{"strategy":"always","refresh":5,"concurrency":3}'

  settings="$(printf '%s' "${settings}" | json_compact | json_escape_sql)"
  stream_settings="$(printf '%s' "${stream_settings}" | json_compact | json_escape_sql)"
  sniffing="$(printf '%s' "${sniffing}" | json_compact | json_escape_sql)"
  allocate="$(printf '%s' "${allocate}" | json_compact | json_escape_sql)"

  local -a columns=()
  local -a values=()
  local col_csv
  local val_csv

  add_col_val() {
    columns+=("$1")
    values+=("$2")
  }

  add_col_val "up" "0"
  add_col_val "down" "0"
  add_col_val "total" "0"

  if db_has_inbound_column "allTime"; then add_col_val "allTime" "0"; fi
  if db_has_inbound_column "all_time"; then add_col_val "all_time" "0"; fi

  if db_has_inbound_column "remark"; then add_col_val "remark" "'${remark}'"; fi
  if db_has_inbound_column "enable"; then add_col_val "enable" "1"; fi

  if db_has_inbound_column "expiryTime"; then add_col_val "expiryTime" "0"; fi
  if db_has_inbound_column "expiry_time"; then add_col_val "expiry_time" "0"; fi

  if db_has_inbound_column "trafficReset"; then add_col_val "trafficReset" "'never'"; fi
  if db_has_inbound_column "traffic_reset"; then add_col_val "traffic_reset" "'never'"; fi

  if db_has_inbound_column "lastTrafficResetTime"; then add_col_val "lastTrafficResetTime" "0"; fi
  if db_has_inbound_column "last_traffic_reset_time"; then add_col_val "last_traffic_reset_time" "0"; fi

  if db_has_inbound_column "userId"; then add_col_val "userId" "1"; fi
  if db_has_inbound_column "user_id"; then add_col_val "user_id" "1"; fi

  if db_has_inbound_column "listen"; then add_col_val "listen" "'0.0.0.0'"; fi
  if db_has_inbound_column "port"; then add_col_val "port" "${inbound_port}"; fi
  if db_has_inbound_column "protocol"; then add_col_val "protocol" "'vless'"; fi
  if db_has_inbound_column "settings"; then add_col_val "settings" "'${settings}'"; fi

  if db_has_inbound_column "stream_settings"; then add_col_val "stream_settings" "'${stream_settings}'"; fi
  if db_has_inbound_column "streamSettings"; then add_col_val "streamSettings" "'${stream_settings}'"; fi

  if db_has_inbound_column "tag"; then add_col_val "tag" "'${tag}'"; fi
  if db_has_inbound_column "sniffing"; then add_col_val "sniffing" "'${sniffing}'"; fi
  if db_has_inbound_column "allocate"; then add_col_val "allocate" "'${allocate}'"; fi

  col_csv="$(IFS=,; echo "${columns[*]}")"
  val_csv="$(IFS=,; echo "${values[*]}")"

  info "Найдены колонки inbounds: $(db_list_inbound_columns | tr '\n' ' ' | sed 's/ $//')"

  sqlite3 "${DB_PATH}" <<SQL
DELETE FROM inbounds WHERE port=${inbound_port};
INSERT INTO inbounds (${col_csv}) VALUES (${val_csv});
SQL

  local settings_len stream_len
  settings_len="$(sqlite3 "${DB_PATH}" "select length(settings) from inbounds where port=${inbound_port} limit 1;" 2>/dev/null || true)"
  stream_len="$(sqlite3 "${DB_PATH}" "select length(stream_settings) from inbounds where port=${inbound_port} limit 1;" 2>/dev/null || true)"

  mkdir -p "${ARTIFACT_DIR}"
  {
    echo "settings_json_length=${#settings}"
    echo "stream_settings_json_length=${#stream_settings}"
    echo "sniffing_json_length=${#sniffing}"
    echo "db_settings_length=${settings_len}"
    echo "db_stream_settings_length=${stream_len}"
  } > "${ARTIFACT_DIR}/${DOMAIN}_sql_lengths.txt"

  if [[ -z "${settings_len}" || "${settings_len}" == "0" || -z "${stream_len}" || "${stream_len}" == "0" ]]; then
    err "После записи inbound поля settings/stream_settings оказались пустыми. Установка остановлена, чтобы не создавать битый inbound."
    dump_inbound_debug "${inbound_port}" || true
    print_support_ticket_hint
    exit 1
  fi
}

extract_webbase_show() {
  "${XUI_BIN}" setting -show true 2>/dev/null | awk -F': ' '/webBasePath/{print $2}' | tr -d '[:space:]' | sed 's#^/*##; s#/*$##'
}

extract_port_show() {
  "${XUI_BIN}" setting -show true 2>/dev/null | awk -F': ' '/port/{print $2}' | tr -d '[:space:]' | head -n 1
}

extract_sub_port_show() {
  local sub_port=""
  local main_pid=""
  local panel_port=""

  # 1) First try the x-ui journal; it explicitly prints the sub server port.
  sub_port="$(journalctl -u x-ui -n 200 --no-pager 2>/dev/null | awk '
    /Sub server running HTTPS on/ {
      line=$0
      sub(/^.*:/, "", line)
      gsub(/[^0-9].*$/, "", line)
      if (line ~ /^[0-9]+$/) port=line
    }
    END { if (port != "") print port }
  ' | tail -n 1)"

  if [[ -n "${sub_port}" ]]; then
    printf '%s' "${sub_port}"
    return 0
  fi

  # 2) Fallback: detect the x-ui listening port that is NOT the main panel port.
  panel_port="$(extract_port_show || true)"
  main_pid="$(systemctl show -p MainPID --value x-ui 2>/dev/null || true)"

  if [[ -n "${main_pid}" && "${main_pid}" != "0" ]]; then
    sub_port="$(ss -ltnp 2>/dev/null | awk -v pid="${main_pid}" -v panel="${panel_port}" '
      index($0, "pid=" pid ",") {
        local_field=$4
        n=split(local_field, parts, ":")
        port=parts[n]
        if (port ~ /^[0-9]+$/ && port != panel) print port
      }
    ' | sort -u | head -n 1)"
  fi

  printf '%s' "${sub_port}"
}

print_support_ticket_hint() {
  echo
  echo "Если не удалось завершить установку:"
  echo "  - создайте тикет в поддержку хоста"
  echo "  - приложите текст ошибки"
  echo "  - приложите диагностический файл, если он был создан"
  echo "  - приложите последние строки журнала x-ui"
  echo
}

dump_inbound_debug() {
  local inbound_port="$1"
  local tag="inbound-${inbound_port}"
  local report="${ARTIFACT_DIR}/${DOMAIN}_inbound_debug.txt"

  mkdir -p "${ARTIFACT_DIR}"

  {
    echo "===== DEBUG REPORT ====="
    echo "Date: $(date -Is)"
    echo "Domain: ${DOMAIN}"
    echo "Inbound port: ${inbound_port}"
    echo "Tag: ${tag}"
    echo

    echo "----- systemctl status x-ui -----"
    systemctl status x-ui --no-pager -l || true
    echo

    echo "----- journalctl -u x-ui -n 120 -----"
    journalctl -u x-ui -n 120 --no-pager || true
    echo

    echo "----- ss -ltnp -----"
    ss -ltnp || true
    echo

    echo "----- x-ui setting -show true -----"
    "${XUI_BIN}" setting -show true 2>/dev/null || true
    echo

    echo "----- SQLite row for inbound -----"
    sqlite3 "${DB_PATH}" "select * from inbounds where port=${inbound_port};" || true
    echo

    echo "----- Generated config match -----"
    grep -nE "\"port\": ${inbound_port}|\"tag\": \"${tag}\"|\"serverName\": \"${DOMAIN}\"|\"path\":" /usr/local/x-ui/bin/config.json || true
    echo

    echo "----- Full inbound fragment from config.json -----"
    awk '
      /"inbounds": \[/ {in_inbounds=1}
      in_inbounds {print}
      in_inbounds && /"outbounds": \[/ {exit}
    ' /usr/local/x-ui/bin/config.json 2>/dev/null || true
    echo
  } > "${report}" 2>&1

  warn "Создан диагностический файл: ${report}"
  warn "Если установка не завершилась, создайте тикет в поддержку хоста и приложите этот файл."
}

verify_runtime() {
  local inbound_port="$1"
  local domain="$2"
  local path="$3"
  local panel_port="$4"
  local panel_webbase="$5"
  local tries=0

  systemctl restart x-ui
  sleep 2

  systemctl is-active --quiet x-ui || {
    journalctl -u x-ui -n 100 --no-pager >&2 || true
    err "x-ui не запустился."
    dump_inbound_debug "${inbound_port}"
    print_support_ticket_hint
    exit 1
  }

  while (( tries < 15 )); do
    if ss -ltnp | grep -q ":${inbound_port} "; then
      break
    fi
    sleep 1
    ((tries+=1))
  done

  if ! ss -ltnp | grep -q ":${inbound_port} "; then
    err "Inbound порт ${inbound_port} не слушается."
    warn "Сейчас скрипт соберёт диагностическую информацию, чтобы было понятно, где именно проблема."
    dump_inbound_debug "${inbound_port}"
    echo
    echo "Что приложить в тикет поддержки:"
    echo "  1) /root/3xui-install-artifacts/${DOMAIN}_inbound_debug.txt"
    echo "или отдельно вывод команд:"
    echo "  journalctl -u x-ui -n 120 --no-pager"
    echo "  sqlite3 ${DB_PATH} \"select * from inbounds where port=${inbound_port};\""
    echo "  grep -nE '\"port\": ${inbound_port}|\"tag\": \"inbound-${inbound_port}\"' /usr/local/x-ui/bin/config.json"
    exit 1
  fi

  openssl s_client -connect "${domain}:${inbound_port}" -servername "${domain}" </dev/null >/tmp/3xui_tls_check.txt 2>&1 || {
    cat /tmp/3xui_tls_check.txt >&2 || true
    err "TLS проверка inbound не прошла."
    dump_inbound_debug "${inbound_port}"
    print_support_ticket_hint
    exit 1
  }

  curl -kfsS --http2 "https://${domain}:${inbound_port}${path}" >/dev/null 2>&1 || true

  if [[ -n "${panel_webbase}" ]]; then
    curl -kfsS "https://${domain}:${panel_port}/${panel_webbase}" >/dev/null 2>&1 || true
  fi

  msg "Все основные проверки завершены. Панель и inbound выглядят рабочими."
}

print_summary() {
  local panel_host="$1"
  local panel_port="$2"
  local panel_user="$3"
  local panel_pass="$4"
  local panel_webbase="$5"
  local inbound_port="$6"
  local path="$7"
  local uuid="$8"
  local email="$9"
  local subid="${10}"
  local sub_port="${11}"

  mkdir -p "${ARTIFACT_DIR}"

  local panel_url="https://${panel_host}:${panel_port}/${panel_webbase}/"
  local sub_url="https://${DOMAIN}:${sub_port}/sub/${subid}"
  local client_json="${ARTIFACT_DIR}/${DOMAIN}_client_hint.json"

  cat > "${client_json}" <<EOF
{
  "address": "${DOMAIN}",
  "port": ${inbound_port},
  "id": "${uuid}",
  "email": "${email}",
  "security": "tls",
  "serverName": "${DOMAIN}",
  "network": "xhttp",
  "host": "${DOMAIN}",
  "path": "${path}",
  "alpn": [
    "h2",
    "http/1.1"
  ],
  "echConfigList": "${ECH_CONFIG_LIST}"
}
EOF

  local vless_uri
  vless_uri="vless://${uuid}@${DOMAIN}:${inbound_port}?security=tls&sni=${DOMAIN}&type=xhttp&host=${DOMAIN}&path=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${path}", safe=""))
PY
)&alpn=h2,http/1.1#${DOMAIN}-xhttp"

  cat > "${ARTIFACT_DIR}/${DOMAIN}_subscription.txt" <<EOF
Subscription URL: ${sub_url}
SubID: ${subid}
EOF

  cat > "${ARTIFACT_DIR}/${DOMAIN}_vless_uri.txt" <<EOF
${vless_uri}
EOF

  echo
  printf '%b
' "${green}╔══════════════════════════════════════════════════════╗${plain}"
  printf '%b
' "${green}║              УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО            ║${plain}"
  printf '%b
' "${green}╚══════════════════════════════════════════════════════╝${plain}"

  echo
  printf '%b
' "${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
  printf '%b
' "${blue}ПАНЕЛЬ${plain}"
  printf '%b
' "${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
  echo "URL      : ${panel_url}"
  echo "Логин    : ${panel_user}"
  echo "Пароль   : ${panel_pass}"

  echo
  printf '%b
' "${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
  printf '%b
' "${blue}ПОДКЛЮЧЕНИЕ${plain}"
  printf '%b
' "${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
  echo "ГОТОВАЯ VLESS ССЫЛКА:"
  echo "${vless_uri}"

  echo
  printf '%b
' "${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
  printf '%b
' "${blue}ПОДПИСКА 3X-UI${plain}"
  printf '%b
' "${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
  echo "Порт     : ${sub_port}"
  echo "URL      : ${sub_url}"

  echo
  printf '%b
' "${yellow}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
  printf '%b
' "${yellow}ВАЖНО${plain}"
  printf '%b
' "${yellow}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
  echo "• Порты были выбраны автоматически после проверки, что они свободны."
  echo "• SMTP-порты и похожие заблокированные порты исключены из выбора."
  echo "• WebBasePath панели сгенерирован автоматически."
  echo "• Введённое слово для ссылки подключения превращено в путь: ${path}"
  echo "• Для сервера используется echServerKeys."
  echo "• Для клиента отдельным файлом сохранён echConfigList."
  echo "• Для 3x-ui подписки клиенту автоматически выдан SubID."
  echo "• Порт подписки определяется автоматически после запуска x-ui."
  echo "• Если клиент без ECH у тебя не работает, используй файл:"
  echo "  ${ARTIFACT_DIR}/${DOMAIN}_ech_config_list.txt"

  echo
  printf '%b
' "${green}Made with love for U1Host${plain}"
  echo "Author   : YaFoxin Dev"
  echo "Telegram : https://t.me/yafoxindev"
  echo "GitHub   : https://github.com/yafoxins"
}

print_install_summary() {
  local domain="$1"
  local email="$2"
  local xhttp_path="$3"

  print_block_title "[ ШАГ 4 / 4 ] Проверьте данные перед установкой"
  echo "Домен: ${domain}"
  echo "Email для SSL-сертификата: ${email}"
  echo "Путь подключения: ${xhttp_path}"
  echo
  echo "Дополнительно скрипт сам:"
  echo "  - сгенерирует логин и пароль панели;"
  echo "  - подберёт свободные порты;"
  echo "  - выпустит SSL-сертификат;"
  echo "  - создаст inbound."
  echo
  read -r -p "Продолжить установку? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  case "$confirm" in
    Y|y|yes|YES) ;;
    *)
      warn "Установка отменена пользователем."
      exit 0
      ;;
  esac
}


require_root
install_packages

PUBLIC_IP4="$(get_public_ipv4)"
PUBLIC_IP6="$(get_public_ipv6 || true)"

if [[ -z "${PUBLIC_IP4}" ]]; then
  err "Не удалось определить внешний IPv4 сервера."
  exit 1
fi

print_banner
print_dns_guidance "${PUBLIC_IP4}"
press_enter_to_continue "Нажмите Enter, когда домен уже направлен на сервер..."

print_block_title "[ ШАГ 2 / 4 ] Основные данные"
echo "Введите данные для выпуска SSL-сертификата и панели."
echo

DOMAIN="$(ask 'Введите ваш домен или поддомен (пример: test.example.com)')"
EMAIL_ACME="$(ask 'Введите email для выпуска SSL-сертификата (например: you@example.com)')"

prompt_connection_word
XHTTP_PATH="/${CONNECTION_WORD}/"

print_install_summary "${DOMAIN}" "${EMAIL_ACME}" "${XHTTP_PATH}"

# Панельные данные генерируются автоматически, чтобы не путать пользователя.
PANEL_USER="admin$(random_string 6)"
PANEL_PASS="$(random_string 18)"
PANEL_WEBBASE="$(random_string 20)"

info "Логин, пароль и WebBasePath панели будут сгенерированы автоматически."
info "Подбираю свободные порты из безопасных пулов. SMTP-порты и похожие заблокированные порты исключены."

PANEL_PORT="$(pick_random_free_port_from_ranges "2050:2099" "8443:8499")" || {
  err "Не удалось найти свободный порт для панели."
  exit 1
}

INBOUND_PORT="$(pick_random_free_port_from_ranges "1000:1500" "4000:4500")" || {
  err "Не удалось найти свободный порт для inbound."
  exit 1
}

if [[ "${PANEL_PORT}" == "${INBOUND_PORT}" ]]; then
  warn "Сгенерировался одинаковый порт для панели и inbound, подбираю inbound повторно."
  INBOUND_PORT="$(pick_random_free_port_from_ranges "1000:1500" "4000:4500")" || {
    err "Не удалось найти отдельный порт для inbound."
    exit 1
  }
fi

validate_port "${PANEL_PORT}" || { err "Некорректный порт панели."; exit 1; }
validate_port "${INBOUND_PORT}" || { err "Некорректный порт inbound."; exit 1; }

msg "Выбран порт панели: ${PANEL_PORT}"
msg "Выбран порт inbound: ${INBOUND_PORT}"
msg "Сформирован путь подключения: ${XHTTP_PATH}"

info "Проверяю DNS домена ${DOMAIN}"
mapfile -t A_RECORDS < <(resolve_a_records "${DOMAIN}")
mapfile -t AAAA_RECORDS < <(resolve_aaaa_records "${DOMAIN}")

if [[ "${#A_RECORDS[@]}" -eq 0 ]]; then
  err "У домена нет A-записи."
  exit 1
fi

printf 'A-записи домена %s:\n' "${DOMAIN}"
printf '  - %s\n' "${A_RECORDS[@]}"

match_a="0"
for ip in "${A_RECORDS[@]}"; do
  [[ "${ip}" == "${PUBLIC_IP4}" ]] && match_a="1"
done

if [[ "${match_a}" != "1" ]]; then
  err "A-запись домена не указывает на текущий IPv4 сервера (${PUBLIC_IP4})."
  exit 1
fi

if [[ "${#AAAA_RECORDS[@]}" -gt 0 ]]; then
  printf 'AAAA-записи домена %s:\n' "${DOMAIN}"
  printf '  - %s\n' "${AAAA_RECORDS[@]}"
  if [[ -z "${PUBLIC_IP6}" ]]; then
    err "У домена есть AAAA-записи, но на сервере не найден глобальный IPv6. Для standalone это часто ломает выпуск сертификата."
    exit 1
  fi
fi

ensure_acme "${EMAIL_ACME}"
issue_domain_cert "${DOMAIN}"

PANEL_CERT="/root/cert/${DOMAIN}/fullchain.pem"
PANEL_KEY="/root/cert/${DOMAIN}/privkey.pem"

INSTALLER="$(download_3xui_installer)"
info "Ставлю 3x-ui ${VERSION}. Это может занять немного времени."
run_3xui_installer_noninteractive "${INSTALLER}" "${PANEL_PORT}" "${DOMAIN}" "${PANEL_CERT}" "${PANEL_KEY}"

if [[ ! -x "${XUI_BIN}" ]]; then
  err "После установки не найден ${XUI_BIN}"
  exit 1
fi

ensure_xui_cli_settings "${PANEL_USER}" "${PANEL_PASS}" "${PANEL_PORT}" "${PANEL_WEBBASE}" "${PANEL_CERT}" "${PANEL_KEY}"

wait_for_db
ensure_db_schema

generate_ech_material "${DOMAIN}"

CLIENT_UUID="$(random_uuid)"
CLIENT_EMAIL="$(random_string 8)"
CLIENT_SUBID="$(random_subid)"

create_inbound "${INBOUND_PORT}" "${DOMAIN}" "${XHTTP_PATH}" "${CLIENT_UUID}" "${CLIENT_EMAIL}" "${CLIENT_SUBID}"

# Make absolutely sure installer-generated or migrated garbage is gone
sqlite3 "${DB_PATH}" "UPDATE inbounds SET stream_settings = replace(stream_settings, '\"verifyPeerCertInNames\":[\"\"],', '') WHERE port=${INBOUND_PORT};" || true
sqlite3 "${DB_PATH}" "UPDATE inbounds SET stream_settings = replace(stream_settings, '\"h3\"', '\"http/1.1\"') WHERE port=${INBOUND_PORT};" || true

ACTUAL_PANEL_PORT="$(extract_port_show || true)"
if [[ -n "${ACTUAL_PANEL_PORT}" ]]; then
  PANEL_PORT="${ACTUAL_PANEL_PORT}"
fi

ACTUAL_WEBBASE="$(extract_webbase_show || true)"
if [[ -n "${ACTUAL_WEBBASE}" ]]; then
  PANEL_WEBBASE="${ACTUAL_WEBBASE}"
fi
PANEL_WEBBASE="$(printf '%s' "${PANEL_WEBBASE}" | sed 's#^/*##; s#/*$##')"

verify_runtime "${INBOUND_PORT}" "${DOMAIN}" "${XHTTP_PATH}" "${PANEL_PORT}" "${PANEL_WEBBASE}"

ACTUAL_SUB_PORT="$(extract_sub_port_show || true)"
if [[ -z "${ACTUAL_SUB_PORT}" ]]; then
  warn "Не удалось автоматически определить порт подписки. Использую стандартный 2096."
  ACTUAL_SUB_PORT="2096"
fi

# Сохраняем реальные данные панели в файл.
mkdir -p "${ARTIFACT_DIR}"
cat > "${ARTIFACT_DIR}/${DOMAIN}_panel_credentials.txt" <<EOF
Panel URL: https://${DOMAIN}:${PANEL_PORT}/${PANEL_WEBBASE}/
Username: ${PANEL_USER}
Password: ${PANEL_PASS}
Subscription URL: https://${DOMAIN}:${ACTUAL_SUB_PORT}/sub/${CLIENT_SUBID}
EOF

print_summary "${DOMAIN}" "${PANEL_PORT}" "${PANEL_USER}" "${PANEL_PASS}" "${PANEL_WEBBASE}" "${INBOUND_PORT}" "${XHTTP_PATH}" "${CLIENT_UUID}" "${CLIENT_EMAIL}" "${CLIENT_SUBID}" "${ACTUAL_SUB_PORT}"
