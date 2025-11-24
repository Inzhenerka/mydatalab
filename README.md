# My Data Lab

Локальная лаборатория данных с PySpark, Jupyter, MinIO (S3), Lakekeeper (Iceberg REST), PostgreSQL и Supervisor UI.

## Быстрый старт с нуля
```bash
git clone https://github.com/Inzhenerka/mydatalab
cd mydatalab
docker compose pull         # подтянуть готовый образ (быстрее первого запуска)
docker compose up           # собрать при необходимости и запустить все сервисы
```

Что открывать:
- Лендинг и ссылки на сервисы: http://localhost:1111
- Jupyter Lab: http://localhost:8888 (токен пустой)
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

## Обновление окружения
- Подтянуть свежий образ без пересборки: `docker compose pull`
- Пересобрать после изменений в Dockerfile: `docker compose build`
