# My Data Lab

Набор инструментов и окружение для локального запуска учебной лаборатории данных.

## Возможности

- PySpark для обработки данных
- Jupyter/ноутбуки для экспериментов
- Локальный MinIO для хранения данных (S3 API)
- Apache Gravitino с веб-интерфейсом и Iceberg REST API поверх MinIO
- Supervisord с веб-интерфейсом для контроля фоновых сервисов
- Быстрый старт через Docker Compose

## Быстрый старт

1. Установите Docker и Docker Compose.
2. Клонируйте репозиторий:
   ```bash
   git clone https://github.com/Inzhenerka/mydatalab
   cd mydatalab
   ```
3. Запустите контейнер:
   ```bash
   docker compose pull
   docker compose up
   ```
4. Откройте в браузере стартовую страницу с описанием всех сервисов: http://localhost:1111
5. Следите за состоянием процессов и управляйте ими через Supervisord: http://localhost:9010 (логин `admin`, пароль `admin`)
6. Работайте с Gravitino через браузер: http://localhost:8090 (UI) или напрямую по REST `http://localhost:8181`
> Папка `gravitino-data` рядом с docker-compose создаётся автоматически и содержит рабочие данные (H2-БД и служебные файлы) Gravitino. Конфигурация сервиса уже запечена в образ и не требует ручной правки, поэтому директория добавлена в `.gitignore`.
