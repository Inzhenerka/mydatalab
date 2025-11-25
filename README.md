# My Data Lab

Полнофункциональная среда для изучения анализа данных и работы с большими данными. Всё необходимое уже настроено и готово к работе — просто запустите Docker и начните экспериментировать:

- Jupyter-ноутбуки для экспериментов
- PySpark для обработки данных
- Локальный MinIO для хранения данных (S3)
- Lakekeeper — REST-каталог Iceberg с UI
- PostgreSQL 18 в качестве базы данных
- Быстрый старт через Docker Compose

## Быстрый старт с нуля

Установите [Docker](https://docs.docker.com/get-docker/) и [Docker Compose](https://docs.docker.com/compose/install/), если они ещё не установлены.

Клонируйте репозиторий и перейдите в папку проекта:

```bash
git clone https://github.com/Inzhenerka/mydatalab
cd mydatalab
```

Подтяните готовый образ `mydatalab` из интернета

```bash
docker compose pull    
```

Запустите контейнер `mydatalab` из образа в синхронном режиме:

```bash 
docker compose up
```

Логи будут выводиться в терминал, в котором запущен контейнер, что поможет в случае непредвиденных ошибок.

Остановить контейнер можно комбинацией клавиш `Ctrl+C`.

**Начните работу с главной страницы: http://localhost:1111**

- Jupyter Lab: http://localhost:1888 (токен пустой)
- Lakekeeper UI / Swagger: http://localhost:8181 и http://localhost:8181/swagger-ui/#/
- Supervisor UI: http://localhost:9010 (admin / admin)

## Продолжить работу после первой установки
```bash
cd mydatalab
docker compose up           # поднимет контейнер с сохранёнными данными
```

## Поставить на паузу или остановить
- Временная пауза, чтобы оставить данные: `docker compose stop`
- Полностью остановить и удалить контейнер (данные в примонтированных папках сохранятся): `docker compose down`

## Где лежат данные сервисов
- MinIO и PostgreSQL используют подмонтированные папки `service-data/minio` и `service-data/postgres` (сама `service-data` в .gitignore, в репозитории только `service-data/.gitkeep`).
- Рабочие файлы Jupyter Lab остаются в `jupyter-work`, чтобы их было удобно синхронизировать с ноутбуком.
- Если раньше данные лежали в `minio-data` или `postgres-data`, перенесите содержимое в новые папки перед запуском, чтобы сохранить окружение.

## Обновление окружения
- Подтянуть свежий образ без пересборки: `docker compose pull`
- Пересобрать после изменений в Dockerfile: `docker compose build`
