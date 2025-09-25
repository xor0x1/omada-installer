#!/bin/bash
#title           :install-omada-controller.sh
#description     :Installer for TP-Link Omada Software Controller (.deb only, author-style parsing)
#supported       :Ubuntu 20.04 (focal), 22.04 (jammy), 24.04 (noble), 24.10 (oracular*), 25.04 (plucky*)
#author          :monsn0 (+minimal fork)
#updated         :2025-09-19

set -Eeuo pipefail
IFS=$'\n\t'

log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
info() { printf "\033[0;36m[~]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; exit 1; }
trap 'warn "Произошла ошибка. Проверьте сообщения выше."' ERR

# Чтобы никакие алиасы/функции curl не мешали
unalias curl 2>/dev/null || true
unset -f curl 2>/dev/null || true
CURL() { command curl "$@"; }
UA="${UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/125 Safari/537.36}"

usage() {
  cat <<'USAGE'
Установщик Omada Controller (.deb только).

Опции:
  --omada-url URL         Прямая ссылка на .deb Omada (если указана — парсинг не используется)
  --omada-sha256 SHA      SHA256 для .deb (опционально)
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

echo -e "\n=== TP-Link Omada Controller — установка (.deb, упрощённый парсинг) ===\n"

# ---- проверки окружения ----
[[ "$(id -u)" -eq 0 ]] || die "Нужны права root. Запустите: sudo bash $0 [опции]"
lscpu | grep -iq 'avx' || die "CPU без AVX. MongoDB 5.0+/8.0 требует AVX."
[[ -r /etc/os-release ]] || die "Не могу прочитать /etc/os-release"
. /etc/os-release
case "${VERSION_CODENAME:-}" in
  focal|jammy|noble|oracular|plucky) OS_CODENAME="$VERSION_CODENAME" ;;
  *) die "Поддерживаются только Ubuntu 20.04/22.04/24.04/24.10/25.04";;
esac
ARCH="$(dpkg --print-architecture)"  # amd64|arm64
info "Обнаружена Ubuntu $VERSION_ID ($OS_CODENAME), arch=$ARCH"

export DEBIAN_FRONTEND=noninteractive

# ---- deps ----
log "Устанавливаю зависимости"
apt-get update -qq
apt-get install -yq --no-install-recommends \
  ca-certificates gnupg curl jq lsb-release apt-transport-https \
  coreutils grep sed gawk

# ---- MongoDB 8.0 ----
MONGO_REPO_CODENAME="$OS_CODENAME"
if [[ "$OS_CODENAME" == "oracular" || "$OS_CODENAME" == "plucky" ]]; then
  warn "MongoDB 8.0 для Ubuntu $VERSION_ID отсутствует; использую репозиторий noble (24.04) как фоллбэк."
  MONGO_REPO_CODENAME="noble"
fi

log "Добавляю репозиторий MongoDB 8.0"
CURL -fsSL --proto '=https' --tlsv1.2 https://www.mongodb.org/static/pgp/server-8.0.asc \
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

# bindIp safety
if [[ -f /etc/mongod.conf ]]; then
  if grep -qE '^\s*bindIp\s*:' /etc/mongod.conf; then
    sed -E -i 's/^\s*bindIp\s*:\s*.*/  bindIp: 127.0.0.1/' /etc/mongod.conf || true
  else
    awk '1; END{print "net:\n  bindIp: 127.0.0.1"}' /etc/mongod.conf > /etc/mongod.conf.new && mv /etc/mongod.conf.new /etc/mongod.conf
  fi
fi
systemctl enable --now mongod

# ---- Получение ссылки Omada ----
# Если URL задан – используем его
if [[ -n "$OMADA_URL" ]]; then
  info "Использую заданный URL Omada (.deb)"
  [[ "$OMADA_URL" =~ \.deb($|\?) ]] || die "Ожидался .deb: $OMADA_URL"
  DL_URL="$OMADA_URL"
else
  log "Парсинг ссылки Omada (как у автора)"
  PAGE="https://support.omadanetworks.com/us/product/omada-software-controller/?resourceType=download"

  # шаблон по архитектуре (узкий, как в оригинале)
  if [[ "$ARCH" == "amd64" ]]; then
    RX='<a[^>]*href="\K[^"]*linux_x64_[0-9]*\.deb[^"]*'
  else
    RX='<a[^>]*href="\K[^"]*linux_arm64_[0-9]*\.deb[^"]*'
  fi

  # 1) тянем страницу
  html="$(CURL -fsSL --compressed -A "$UA" "$PAGE")"

  # 2) берём ПЕРВУЮ подходящую ссылку
  raw_url="$(printf '%s' "$html" | grep -oPi "$RX" | head -n1 || true)"
  [[ -n "$raw_url" ]] || die "Не удалось найти .deb ссылку на странице загрузки."

  # 3) делаем абсолютной (учёт CDN)
  case "$raw_url" in
    //*)    DL_URL="https:${raw_url}" ;;
    /upload/software/*) DL_URL="https://static.tp-link.com${raw_url}" ;;
    /*)     DL_URL="https://support.omadanetworks.com${raw_url}" ;;
    *)      DL_URL="$raw_url" ;;
  esac
fi

# ---- Загрузка и установка ----
FILE="/tmp/$(basename "$DL_URL")"
log "Скачиваю пакет: $DL_URL"
CURL -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 600 \
     --compressed -A "$UA" -o "$FILE" "$DL_URL"
info "Сохранено: $FILE"

if [[ -n "$OMADA_SHA" ]]; then
  log "Проверяю SHA256"
  DOWN_SHA="$(sha256sum "$FILE" | awk '{print $1}')"
  [[ "$DOWN_SHA" == "$OMADA_SHA" ]] || die "Несовпадение SHA256 (ожидалось $OMADA_SHA, получено $DOWN_SHA)"
fi

log "Устанавливаю Omada (.deb)"
apt-get install -y "$FILE"

# ---- Автозапуск + UFW ----
if systemctl list-unit-files | grep -qiE 'omada|tpeap'; then
  svc="$(systemctl list-unit-files | awk '/(omada|tpeap).*service/ {print $1; exit}')"
  systemctl enable --now "$svc"
fi

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
printf "\033[0;32m[✓]\033[0m Omada установлена.\n"
printf "\033[0;32m[→]\033[0m Откройте: https://%s:8043  (самоподписанный сертификат)\n" "$IP"
printf "\033[0;32m[ℹ]\033[0m Ограничьте доступ к порту 8043 только из доверенной сети.\n"
