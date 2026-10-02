#!/usr/bin/env bash
set -euo pipefail
cd /opt/shop
umask 077

# защита от одновременного деплоя
exec 9>.deploy.lock
flock -n 9
compose() { docker compose --env-file .env -f docker-compose.prod.yml "$@"; }

mode="${1:?Укажите deploy или rollback}"
case "$mode" in
  deploy)
    export API_IMAGE="${2:?Укажите image}"
    # скачиваем новый image и сохраняем предыдущий до пересоздания api
    compose pull api
    docker inspect "$(compose ps -q api)" --format '{{.Image}}' > .previous-api-image.tmp
    mv .previous-api-image.tmp .previous-api-image
    ;;
  rollback)
    export API_IMAGE="$(cat .previous-api-image)"
    docker image inspect "$API_IMAGE" >/dev/null
    ;;
  *) echo 'Укажите deploy или rollback.' >&2; exit 2 ;;
esac

update_api() {
  # compose ждёт healthy, db не трогаем
  compose up -d --no-deps --pull never --wait --wait-timeout 90 api || return 1
  # после пересоздания api обновляем его адрес в nginx
  compose exec -T nginx nginx -t || return 1
  compose exec -T nginx nginx -s reload || return 1
  curl --retry 3 --retry-connrefused --retry-delay 1 --max-time 5 -fsS http://127.0.0.1/health >/dev/null || return 1
  awk '/MemAvailable:/ {exit ($2 < 512000)}' /proc/meminfo || return 1
}

save_image() {
  # сохраняем выбранный image для следующих запусков Compose
  sed '/^API_IMAGE=/d' .env > .env.tmp
  printf 'API_IMAGE=%s\n' "$API_IMAGE" >> .env.tmp
  mv .env.tmp .env
}

if ! update_api; then
  if [[ "$mode" == deploy ]]; then
    echo 'Проверка не прошла, возвращаем предыдущий image.' >&2
    export API_IMAGE="$(cat .previous-api-image)"
    update_api || { echo 'Rollback не восстановил сервис, нужен инженер.' >&2; exit 1; }
    save_image
  fi
  exit 1
fi
save_image
echo 'Health и запас памяти проверены, дальше мониторим error rate и p95 latency.'
