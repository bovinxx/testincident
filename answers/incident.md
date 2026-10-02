# Incident analysis

## Первые пять команд

1. `docker compose -f docker-compose.prod.yml ps` - так как вырос error rate и p95 latency, логично предположить, что контейнер падает и рестартится, поэтому проверим статус контейнера api. Ожидаемый сигнал - контейнер падает и рестартится.
2. `docker inspect "$(docker compose -f docker-compose.prod.yml ps -q api)" --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} RestartCount={{.RestartCount}}'` - так как статус контейнера api `Restarting (137) 8 seconds ago`, предполагаем, что его убил OOM Killer, смотрим так ли это и смотрим на количество рестартов контейнера. Ожидаемый сигнал - `OOMKilled=true ExitCode=137 RestartCount=...`
3. `free -h` - так как контейнер убит OOM киллером, проверяем доступную память и наличие свапа. Видим, что доступно около 5% RAM и свап отключён. Ожидаемый сигнал - сильная нехватка доступной памяти.
4. `git diff a81f9c2^ a81f9c2 -- docker-compose.prod.yml` - проверяем что изменилось в докер композ перед релизом, видим что подняли WEB_CONCURRENCY с 2 до 16. Ожидаемый сигнал - изменение конфигурации, касающейся контейнера api.
5. `docker stats --no-stream` - проверим сколько ресурсов потребляет контейнер после увеличения WEB_CONCURRENCY. Ожидаемый сигнал - контейнер api потребляет чрезмерно много RAM.

## Основная причина

В связи с существенным увеличением WEB_CONCURRENCY, сильно выросло потребление памяти контейнером api. Виртуальная машина имеет 4 GiB RAM и не выдерживает такую нагрузку, поэтому процессы node убиваются OOM киллером, контейнер api рестартится и пользователи получают ошибки 502 и растёт latency.

## Вторичные риски

1. У контейнеров нет лимитов. Поэтмоу при росте потребления памяти, api может съесть почти всю память на хосте, тем самым действуя и на другие контейнеры. Отключён свап, поэтому при розком росте потребления памяти нет никакого резерва.
2. Диск занят на 92%, логи контейнеров занимают 11GiB. Если диск запонится - остановится запись в постгрес.


## Первое mitigation

В текущем композе меняем только WEB_CONCURRENCY с 16 на 2, сохраняем текущий image api и делаем `docker compose -f docker-compose.prod.yml up -d --no-deps --pull never api`.
Проверяем `docker compose -f docker-compose.prod.yml ps`, `docker stats --no-stream` и healthcheck api.
Потсгрес и db-data не трогаем, это действие уменьшает число воркеров, но не откатывает версию приложения.
После первого mitigation готовим .env и secrets по комментариям в композе. Первый переход на лимиты и secrets db делаем с проверенным backup в согласованное окно, сохраняем текущую major версию потсгреса, волюм и имя Compose project. Проверяем `docker compose -f docker-compose.prod.yml config --quiet`, затем применяем композ и проверяем healthy db, api и nginx, downtime не более 5 минут.

## Rollback plan

Если после уменьшения WEB_CONCURRENCY не улучшается, то откатим приложение на последний успешный релиз.
При откате - не пересоздавать контейнер с потсгресом и не пересоздавать волюм db-data.
Проверяем `docker compose -f docker-compose.prod.yml ps`, `docker stats --no-stream` и healthcheck api.
Мониторим error rate и p95 latency.
Перед откатом смотрим текущий image: `docker inspect "$(docker compose -f docker-compose.prod.yml ps -q api)" --format '{{.Config.Image}} {{.Image}}'` и сохраняем его для handover.
После настройки pipeline запускаем `bash /opt/shop/scripts/rollback.sh`, скрипт возвращает локальный image предыдущего api и проверяет health, этот image не удаляем при очистке Docker. До первого deploy берём digest последнего успешного релиза из истории pipeline. Предыдущая версия должна быть совместима с текущей схемой БД, это проверяем до deploy, иначе его не запускаем.
Не используем `docker compose down -v`, эта команда удалит волюм db-data.

## Проверка восстановления

Проверяем `docker inspect "$(docker compose -f docker-compose.prod.yml ps -q api)" --format 'Health={{.State.Health.Status}} RestartCount={{.RestartCount}}'` и `curl -fsS http://127.0.0.1/health`. Ожидаемый сигнал - healthy и успешный ответ через nginx.
Смотрим `free -m`, ожидаем минимум 500 MiB available, в течение 5 минут проверяем, что RestartCount не растёт, error rate вернулся к 0.2%, а p95 latency к 220 ms.

## Приоритеты

### P0

1. WEB_CONCURRENCY подняли с 2 до 16 и получили OOM. Возвращаем 2 и проверяем восстановление api.
2. В deploy используется `docker compose down -v`, это удаляет волюм с данными потсгреса. Убираем эту команду, обновляем только api без пересоздания db-data.

### P1

3. У контейнеров нет лимитов памяти. Задаём api 1536 MiB, db 1536 MiB и nginx 128 MiB, суммарно 3200 MiB. По данным free остаётся около 730 MiB для ОС и Docker, после применения проверяем available, лимиты уточняем по потреблению под нагрузкой.
4. Логи контейнеров занимают 11GiB и диск занят на 92%. Настраиваем ротацию логов для всех контейнеров.
5. Пароль БД лежит в композе, а ssh ключ выводится в лог pipeline. Убираем echo ключа, переносим секреты в защищённые переменные или файлы вне git, пароль и ключ меняем согласованно после восстановления.
6. Pipeline делает deploy до тестов и сборки, использует latest и не проверяет результат. Делаем test, build, deploy, собираем image с ommit SHA, сохраняем предыдущую версию и проверяем health после deploy.

### P2

7. api и db доступны снаружи, api запущен с privileged. Убираем публикацию портов 3000 и 5432 и privileged, оставляем доступ только через nginx.
8. postgres и nginx используют latest, а nginx не имеет healthcheck. Фиксируем текущие версии image, для потсгреса сохраняем текущую major версию и db-data, добавляем проверку nginx и ожидание healthy зависимостей. В api image проверяем наличие curl, в nginx image наличие wget.