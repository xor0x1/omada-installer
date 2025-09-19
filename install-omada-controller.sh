#!/bin/bash
#title           :install-omada-controller.sh
#description     :Installer for TP-Link Omada Software Controller
#supported       :Ubuntu 20.04 (focal), 22.04 (jammy), 24.04 (noble), 24.10 (oracular*)
#author          :monsn0
#date            :2021-07-29
#updated         :2025-09-19

#!/usr/bin/env bash
# title   : install-omada-safe.sh
# purpose : Safe installer for TP-Link Omada Controller (.deb only)
# supports: Ubuntu 20.04 (focal), 22.04 (jammy), 24.04 (noble), 24.10 (oracular*)
# note    : *Для 24.10 MongoDB берём из репозитория noble (24.04) — фоллбэек.
# updated : 2025-09-19

set -Eeuo pipefail
IFS=$'\n\t'

log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
info() { printf "\033[0;36m[~]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; exit 1; }
trap 'warn "Произошла ошибка. Проверьте сообщения выше."' ERR

usage() {
  cat <<'USAGE'
Установщик Omada Controller (.deb только).

Опции:
  --omada-url URL         Прямая ссылка на .deb Omada (рекомендуется)
  --omada-sha256 SHA      SHA256 для .deb (опционально, но желательно)
  --ufw-allow-cidr CIDR   Разрешить доступ к 8043 только из CIDR (например 192.168.0.0/16)
  --help                  Показать помощь
USAGE
}

OMADA_URL=""; OMADA_SHA=""; UFW_CIDR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --omada-url)        OMADA_URL="${2:-}"; shift 2 ;;
    --omada-sha256)     OMADA_SHA="${2:-}"; shift 2 ;;
    --ufw-allow-cidr)   UFW_CIDR="${2:-}"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  die "Неизвестный аргумент: $1 (см. --help)";;
  esac
done

echo -e "\n=== TP-Link Omada Controller — безопасная установка (.deb) ===\n"

# ---- базовые проверки ----
[[ "$(id -u)" -eq 0 ]] || die "Нужны права root. Запустите: sudo bash $0 [опции]"
lscpu | grep -iq 'avx' || die "CPU без AVX. MongoDB 5.0+/8.0 требует AVX."

[[ -r /etc/os-release ]] || die "Не могу прочитать /etc/os-release"
. /etc/os-release
case "${VERSION_CODENAME:-}" in
  focal|jammy|noble|oracular) OS_CODENAME="$VERSION_CODENAME" ;;
  *) die "Поддерживаются только Ubuntu 20.04/22.04/24.04/24.10";;
esac
ARCH="$(dpkg --print-architecture)" # amd64/arm64
info "Обнаружена Ubuntu $VERSION_ID ($OS_CODENAME), arch=$ARCH"

export DEBIAN_FRONTEND=noninteractive

# ---- зависимости ----
log "Устанавливаю зависимости"
apt-get update -qq
apt-get install -yq --no-install-recommends \
  ca-certificates gnupg curl jq lsb-release apt-transport-https \
  coreutils grep sed gawk

# ---- MongoDB 8.0 репозиторий ----
MONGO_REPO_CODENAME="$OS_CODENAME"
if [[ "$OS_CODENAME" == "oracular" ]]; then
  warn "MongoDB 8.0 для Ubuntu 24.10 отсутствует; использую репозиторий noble (24.04)."
  MONGO_REPO_CODENAME="noble"
fi

log "Добавляю репозиторий MongoDB 8.0 и настраиваю пиннинг"
curl -fsSL --proto '=https' --tlsv1.2 https://www.mongodb.org/static/pgp/server-8.0.asc \
  | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg

echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] https://repo.mongodb.org/apt/ubuntu ${MONGO_REPO_CODENAME}/mongodb-org/8.0 multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-8.0.list

cat >/etc/apt/preferences.d/mongodb-org-8.0.pref <<'PREF'
Package: mongodb-org*
Pin: version 8.0*
Pin-Priority: 1001
PREF

apt-get update -qq
apt-get install -y mongodb-org openjdk-21-jre-headless jsvc

# Привязываем mongod к localhost
if [[ -f /etc/mongod.conf ]]; then
  if grep -qE '^\s*bindIp\s*:' /etc/mongod.conf; then
    sed -E -i 's/^\s*bindIp\s*:\s*.*/  bindIp: 127.0.0.1/' /etc/mongod.conf || true
  else
    awk '1; END{print "net:\n  bindIp: 127.0.0.1"}' /etc/mongod.conf > /etc/mongod.conf.new && mv /etc/mongod.conf.new /etc/mongod.conf
  fi
fi
systemctl enable --now mongod

# ---- поиск .deb Omada ----
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/125 Safari/537.36"

allow_domain() {
  local u="$1"
  [[ "$u" =~ ^https://([a-z0-9.-]+\.)?(omadanetworks\.com|tp-link\.com)/ ]] && return 0
  return 1
}

make_absolute() {
  local u="$1"
  if [[ "$u" =~ ^// ]]; then
    printf "https:%s" "$u"
  elif [[ "$u" =~ ^/ ]]; then
    printf "https://support.omadanetworks.com%s" "$u"
  else
    printf "%s" "$u"
  fi
}

resolve_deb_url() {
  local patt page url_list pages best
  case "$ARCH" in
    amd64) patt='(linux_(x64|amd64|x86_64))' ;;
    arm64) patt='(linux_(arm64|aarch64))' ;;
    *)     die "Неподдерживаемая архитектура: $ARCH (нужны amd64/arm64)" ;;
  esac

  pages=(
    "https://support.omadanetworks.com/us/product/omada-software-controller/?resourceType=download"
    "https://www.tp-link.com/support/download/omada-software-controller/"
    "https://www.tp-link.com/us/support/download/omada-software-controller/"
  )

  url_list="$(mktemp)"
  for p in "${pages[@]}"; do
    info "Пробую страницу загрузок: $p"
    page="$(mktemp)"
    if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 40 \
         --compressed -A "$UA" "$p" -o "$page"; then
      # только .deb
      grep -oP 'href="\K[^"]+\.deb' "$page" 2>/dev/null \
        | while read -r u; do make_absolute "$u"; done \
        | grep -Ei "$patt" \
        | grep -Eiv '(beta|rc)' \
        | sort -u >> "$url_list" || true
      grep -oP 'data-href="\K[^"]+\.deb' "$page" 2>/dev/null \
        | while read -r u; do make_absolute "$u"; done \
        | grep -Ei "$patt" \
        | grep -Eiv '(beta|rc)' \
        | sort -u >> "$url_list" || true
    fi
  done

  mapfile -t urls < <(sort -u "$url_list" | grep -E '^https?://')
  [[ ${#urls[@]} -gt 0 ]] || die "Не нашёл .deb Omada для $ARCH на известных страницах."

  # оставляем только доступные (HEAD 200) и с доверенных доменов
  valid_urls=()
  for u in "${urls[@]}"; do
    allow_domain "$u" || continue
    if curl -fsSI -A "$UA" "$u" | grep -qE '^HTTP/.* 200'; then
      valid_urls+=("$u")
    fi
  done
  [[ ${#valid_urls[@]} -gt 0 ]] || die "Все найденные .deb недоступны (404/…); укажите --omada-url."

  best="$(
    printf '%s\n' "${valid_urls[@]}" \
    | awk -F/ '{
        u=$0; f=$NF; ver="0.0.0";
        if (match(f, /[0-9]+(\.[0-9]+){1,3}/)) ver=substr(f,RSTART,RLENGTH);
        print ver " " u
      }' \
    | sort -V | tail -n1 | awk '{print $2}'
  )"
  echo "$best"
}

DL_URL=""
if [[ -n "$OMADA_URL" ]]; then
  info "Использую заданный URL Omada (.deb)"
  [[ "$OMADA_URL" =~ \.deb($|\?) ]] || die "Ожидался .deb: $OMADA_URL"
  [[ "$OMADA_URL" =~ ^https?:// ]] || die "Некорректный URL: $OMADA_URL"
  allow_domain "$OMADA_URL" || die "Подозрительный домен ссылки: $OMADA_URL"
  DL_URL="$OMADA_URL"
else
  log "Ищу последнюю стабильную .deb сборку Omada на сайтах TP-Link"
  DL_URL="$(resolve_deb_url)"
fi

FILE="/tmp/$(basename "$DL_URL")"
log "Скачиваю пакет: $DL_URL"
curl -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 600 \
     --compressed -A "$UA" -o "$FILE" "$DL_URL"
info "Сохранено: $FILE"

if [[ -n "$OMADA_SHA" ]]; then
  log "Проверяю SHA256"
  DOWN_SHA="$(sha256sum "$FILE" | awk '{print $1}')"
  [[ "$DOWN_SHA" == "$OMADA_SHA" ]] || die "Несовпадение SHA256 (ожидалось $OMADA_SHA, получено $DOWN_SHA)"
else
  warn "SHA256 не задан — продолжаю без проверки целостности (рекомендуется указать --omada-sha256)"
fi

# ---- установка Omada (.deb) ----
log "Устанавливаю Omada (.deb) через apt"
apt-get install -y "$FILE"

# ---- автозапуск сервиса ----
if systemctl list-unit-files | grep -qiE 'omada|tpeap'; then
  svc="$(systemctl list-unit-files | awk '/(omada|tpeap).*service/ {print $1; exit}')"
  systemctl enable --now "$svc"
fi

# ---- UFW опционально ----
if [[ -n "$UFW_CIDR" ]]; then
  if command -v ufw >/dev/null 2>&1; then
    log "UFW: разрешаю 8043 из $UFW_CIDR"
    ufw allow from "$UFW_CIDR" to any port 8043 proto tcp || warn "Не удалось добавить правило UFW"
  else
    warn "UFW не установлен. Чтобы ограничить доступ: apt-get install ufw && ufw allow from $UFW_CIDR to any port 8043 proto tcp"
  fi
fi

IP="$(hostname -I | awk '{print $1}')"
echo
printf "\033[0;32m[✓]\033[0m Omada установлена (.deb).\n"
printf "\033[0;32m[→]\033[0m Откройте: https://%s:8043  (самоподписанный сертификат)\n" "$IP"
printf "\033[0;32m[ℹ]\033[0m Ограничьте доступ к порту 8043 только из доверенной сети.\n"
