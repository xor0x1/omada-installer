#!/bin/bash
#title           :install-omada-controller.sh
#description     :Installer for TP-Link Omada Software Controller
#supported       :Ubuntu 20.04 (focal), 22.04 (jammy), 24.04 (noble), 24.10 (oracular*)
#author          :monsn0
#date            :2021-07-29
#updated         :2025-09-19

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


resolve_deb_url() {
  local UA="Mozilla/5.0"
  local patt
  case "$ARCH" in
    amd64) patt='(linux_(x64|amd64|x86_64))' ;;
    arm64) patt='(linux_(arm64|aarch64))' ;;
    *)     die "Неподдерживаемая архитектура: $ARCH (нужны amd64/arm64)" ;;
  esac

  # --- странички, где чаще всего есть ссылки ---
  local pages=(
    "https://support.omadanetworks.com/us/product/omada-software-controller/?resourceType=download"
    "https://www.tp-link.com/support/download/omada-software-controller/"
    "https://www.tp-link.com/us/support/download/omada-software-controller/"
  )

  # вспомогалка: сделать ссылку абсолютной с учётом текущей страницы
  __abs() {
    local link="$1" base="$2"
    local host; host="$(printf '%s' "$base" | awk -F/ '{print $3}')"
    if [[ "$link" =~ ^// ]]; then
      printf 'https:%s\n' "$link"
    elif [[ "$link" =~ ^/upload/software/ ]]; then
      # CDN-пути всегда на static.tp-link.com
      printf 'https://static.tp-link.com%s\n' "$link"
    elif [[ "$link" =~ ^/ ]]; then
      printf 'https://%s%s\n' "$host" "$link"
    else
      printf '%s\n' "$link"
    fi
  }

  # --- 1) «умный» сбор кандидатов ---
  local url_list; url_list="$(mktemp)"
  for p in "${pages[@]}"; do
    info "Пробую страницу загрузок: $p"
    local page; page="$(mktemp)"
    if curl -fsSL --compressed -A "$UA" "$p" -o "$page"; then
      # собираем из разных атрибутов
      for attr in 'href' 'data-href' 'data-url' 'content'; do
        grep -oP "${attr}=\"\K[^\" ]+\.deb" "$page" 2>/dev/null \
          | while IFS= read -r u; do __abs "$u" "$p"; done \
          | grep -Ei "$patt" \
          | grep -Eiv '(beta|rc)' \
          | sed 's/%20/ /g' \
          | sort -u >> "$url_list" || true
      done
    fi
  done

  # уникальные кандидаты
  mapfile -t urls < <(sort -u "$url_list" | grep -E '^https?://' )
  if ((${#urls[@]} > 0)); then
    # сортируем по версии, свежие в конце
    mapfile -t ordered < <(
      printf '%s\n' "${urls[@]}" \
      | awk -F/ '{
          u=$0; f=$NF; ver="0.0.0";
          if (match(f, /[0-9]+(\.[0-9]+){1,3}/)) ver=substr(f,RSTART,RLENGTH);
          print ver " " u
        }' \
      | sort -V | awk '{print $2}'
    )

# проверяем доступность через HEAD (без range!)
for u in $(printf '%s\n' "${ordered[@]}" | tac); do
  [[ "$u" =~ ^https://([a-z0-9.-]+\.)?(omadanetworks\.com|tp-link\.com)/ ]] || continue
  info "Проверяю доступность: $u"
  if curl -fsIL -A "$UA" "$u" >/dev/null; then
    echo "$u"
    return 0
  else
    warn "Недоступно (HEAD != 200/206/30x): $u"
  fi
done
  
  mapfile -t urls < <(sort -u "$url_list" | grep -E '^https?://')
  [[ ${#urls[@]} -gt 0 ]] || die "Не нашёл .deb Omada для $ARCH на известных страницах."

  # сортируем по версии (возрастающе) — начнём проверку с самых новых
  mapfile -t ordered < <(
    printf '%s\n' "${urls[@]}" \
    | awk -F/ '{
        u=$0; f=$NF; ver="0.0.0";
        if (match(f, /[0-9]+(\.[0-9]+){1,3}/)) ver=substr(f,RSTART,RLENGTH);
        print ver " " u
      }' \
    | sort -V | awk '{print $2}'
  )
  
  die "Все найденные .deb недоступны (404/…); укажите --omada-url."
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
