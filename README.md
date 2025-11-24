# My Data Lab

Набор инструментов и окружение для локального запуска учебной лаборатории данных.

## Возможности

- PySpark для обработки данных
- Jupyter/ноутбуки для экспериментов
- Локальный MinIO для хранения данных (S3 API)
- Lakekeeper — REST-каталог Iceberg с UI, использует PostgreSQL и MinIO
- PostgreSQL 18 в качестве базы данных
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
5. Каталог Iceberg и UI Lakekeeper доступны на http://localhost:8181 (Swagger: http://localhost:8181/swagger-ui/#/)
6. Следите за состоянием процессов и управляйте ими через Supervisord: http://localhost:9010 (логин `admin`, пароль `admin`)
