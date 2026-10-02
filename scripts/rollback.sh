#!/usr/bin/env bash
set -euo pipefail

# возвращаем предыдущий image api, проверки и блокировка общие с deploy
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$script_dir/deploy.sh" rollback
