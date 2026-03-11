#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ELK + Kafka Cluster Automation Script ===${NC}"
echo "Выберите режим установки:"
echo "1) Master (Первая машина: генерация сертификатов и запуск)"
echo "2) Node   (2-я и 3-я машины: скачивание сертификатов и запуск)"
read -p "Ваш выбор (1/2): " MODE

# Функция проверки Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker не найден. Установите его перед запуском.${NC}"
        exit 1
    fi
}

# 1. ПОДГОТОВКА .ENV
if [ ! -f .env ]; then
    echo "Файл .env не найден. Копирую из шаблона..."
    cp .env_example .env
    echo -e "${RED}ВНИМАНИЕ: Отредактируйте .env (nano .env) и запустите скрипт снова!${NC}"
    exit 1
fi

source .env

if [ "$MODE" == "1" ]; then
    # === РЕЖИМ MASTER ===
    check_docker
    mkdir -p certs
    echo -e "${GREEN}Генерация SSL для Logstash...${NC}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout certs/logstash.key -out certs/logstash.crt -subj "/CN=${PUBLISH_HOST}"
    
    echo -e "${GREEN}Генерация сертификатов кластера Elastic...${NC}"
    # Используем твой кастомный образ для генерации
    sudo docker run --rm -v $(pwd)/certs:/certs raul5589/elasticsearch-custom:9.2.2 bin/elasticsearch-certutil cert --name elastic-certificates --out /certs/elastic-certificates.p12 --pass ""
    sudo chmod -R 644 certs/
    
    echo -e "${GREEN}Запуск контейнеров...${NC}"
    sudo docker compose --profile kafka up -d
    
    echo -e "${GREEN}Ожидание запуска базы (30 сек)...${NC}"
    sleep 30
    
    echo -e "${GREEN}Инициализация Alias и ILM...${NC}"
    curl -k -u elastic:${ELASTIC_PASSWORD} -X POST "https://localhost:9200/_aliases" -H 'Content-Type: application/json' -d'
    {
      "actions": [
        { "add": { "index": "filebeat-*", "alias": "filebeat", "is_write_index": true } }
      ]
    }'
    
    echo -e "${GREEN}Настройка завершена!${NC}"
    echo "Запустите временный сервер для передачи сертификатов на другие ноды?"
    read -p "(y/n): " RUN_SERVER
    if [ "$RUN_SERVER" == "y" ]; then
        cd certs && python3 -m http.server 8080
    fi

elif [ "$MODE" == "2" ]; then
    # === РЕЖИМ NODE ===
    check_docker
    mkdir -p certs
    read -p "Введите IP Master-ноды (1-й машины): " MASTER_IP
    echo -e "${GREEN}Скачивание сертификатов...${NC}"
    cd certs && wget http://${MASTER_IP}:8080/elastic-certificates.p12
    cd ..
    
    echo -e "${GREEN}Запуск контейнеров...${NC}"
    sudo docker compose --profile kafka up -d
    echo -e "${GREEN}Node успешно запущена!${NC}"
fi
