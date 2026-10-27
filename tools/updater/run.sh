#!/bin/sh
# Обновлятор Баланса: контейнер без портов. Работает через общий каталог
# /update (том update_state), который видит и сервер:
#   request    — сервер просит обновиться (содержимое не читается);
#   status     — idle | running | ok | error;
#   log        — вывод последнего обновления;
#   available  — remote:<хеш коммита> или пусто: в реестре образ новее запущенного.
# Из интерфейса можно запустить только две команды, зашитые ниже: compose pull
# и compose up для сервера. Произвольных команд здесь нет.
#
# Режим сборки из исходников (рядом лежит compose.build.yml — система
# разработчика): образы собираются на месте, обновлять из реестра нечего.

UPDATE=/update
PROJECT_DIR=/project
CHECK_EVERY=${CHECK_EVERY:-600}

# Имя проекта — то же, что у этого контейнера: обновляются именно его
# контейнеры. Каталог проекта внутри контейнера — /project (папка установки
# на хосте, смонтированная только на чтение): путь хоста вида C:\Баланс Linux
# не понимает. Пути данных в .env абсолютные, поэтому от этого не зависят.
PROJ=$(docker inspect "$(hostname)" --format '{{index .Config.Labels "com.docker.compose.project"}}')

dc() {
    docker compose --project-directory "$PROJECT_DIR" -f "$PROJECT_DIR/compose.yml" \
        --env-file "$PROJECT_DIR/.env" -p "$PROJ" "$@"
}

image_ref() {
    # имя образа с тегом из конфигурации compose (то, что скачивает pull)
    dc config --images 2>/dev/null | grep -m1 balans
}

set_status() { echo "$1" > "$UPDATE/status"; }

do_update() {
    set_status running
    {
        echo "$(date '+%Y-%m-%d %H:%M:%S') обновление"
        dc pull api && dc up -d --no-deps api
    } > "$UPDATE/log" 2>&1
    if [ $? -eq 0 ]; then
        set_status ok
    else
        set_status error
    fi
    : > "$UPDATE/available"
}

check_remote() {
    ref=$(image_ref)
    [ -n "$ref" ] || return
    remote=$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>/dev/null)
    [ -n "$remote" ] || return
    local=$(docker image inspect "$ref" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//')
    if [ -n "$local" ] && [ "$remote" != "$local" ]; then
        echo "remote:$remote" > "$UPDATE/available"
    else
        : > "$UPDATE/available"
    fi
}

mkdir -p "$UPDATE"
[ -f "$UPDATE/status" ] || set_status idle
: > "$UPDATE/available"

since_check=$CHECK_EVERY
while true; do
    if [ -f "$UPDATE/request" ]; then
        rm -f "$UPDATE/request"
        if [ -f "$PROJECT_DIR/compose.build.yml" ]; then
            echo "Система собирается из исходников — обновление из реестра отключено." > "$UPDATE/log"
            set_status error
        else
            do_update
        fi
    fi
    if [ "$since_check" -ge "$CHECK_EVERY" ] && [ ! -f "$PROJECT_DIR/compose.build.yml" ]; then
        check_remote
        since_check=0
    fi
    sleep 2
    since_check=$((since_check + 2))
done
