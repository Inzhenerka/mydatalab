# My Data Lab by Inzhenerka.Tech

Набор инструментов и окружение для локального запуска учебной лаборатории данных.

## Возможности

- PySpark для обработки данных
- Jupyter/ноутбуки для экспериментов.
- Локальный MinIO для хранения данных (S3 API).
- Быстрый старт через Docker Compose.

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
