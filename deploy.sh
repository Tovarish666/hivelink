#!/bin/bash
# hivelink — развёртывание на сервер одной командой.
#
# На целевом хосте:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Tovarish666/hivelink/main/deploy.sh)
#
# Скрипт сам поставит git, заберёт репозиторий и запустит install.sh.
# Повторный запуск обновляет уже установленное.
#
# Переменные окружения:
#   HIVELINK_REPO    адрес репозитория (по умолчанию GitHub)
#   HIVELINK_REF     ветка или тег (по умолчанию main)
#   HIVELINK_DIR     куда клонировать (по умолчанию /opt/src/hivelink)
#   HIVELINK_ARGS    аргументы для install.sh, например "--no-dkms"

set -euo pipefail

REPO="${HIVELINK_REPO:-https://github.com/Tovarish666/hivelink.git}"
REF="${HIVELINK_REF:-main}"
DIR="${HIVELINK_DIR:-/opt/src/hivelink}"
ARGS="${HIVELINK_ARGS:-}"

say()  { printf '\033[36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"

say "hivelink -> $DIR (ветка $REF)"

if ! apt-get check >/dev/null 2>&1; then
    warn "в apt битые зависимости — чиню, иначе не встанет ничего"
    apt-get --fix-broken install -y 2>&1 | tail -5
fi

if ! command -v git >/dev/null 2>&1; then
    say "ставлю git"
    apt-get update -qq 2>/dev/null || true
    apt-get install -y git 2>&1 | tail -3 || die "не поставился git"
fi

if [ -d "$DIR/.git" ]; then
    say "обновляю существующий клон"
    git -C "$DIR" fetch --depth 1 origin "$REF" 2>&1 | tail -2
    git -C "$DIR" reset --hard "origin/$REF" 2>&1 | tail -1
else
    say "клонирую"
    rm -rf "$DIR"
    mkdir -p "$(dirname "$DIR")"
    git clone --depth 1 --branch "$REF" "$REPO" "$DIR" 2>&1 | tail -2
fi

say "версия: $(cat "$DIR/VERSION" 2>/dev/null || echo '?')"
say "запускаю install.sh $ARGS"
echo

# shellcheck disable=SC2086
bash "$DIR/install.sh" $ARGS
