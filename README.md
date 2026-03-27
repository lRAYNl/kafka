# Kafka Cluster (KRaft mode)

Развёртывание трёхузлового кластера Apache Kafka 3.9.2 в режиме **KRaft** (без ZooKeeper) с SSL-шифрованием внешних подключений.

```
git clone https://github.com/lRAYNl/kafka.git ~/kafka
```

---

## Содержание

- [Архитектура](#архитектура)
- [Требования](#требования)
- [Структура репозитория](#структура-репозитория)
- [Шаг 1 — Генерация SSL-сертификатов](#шаг-1--генерация-ssl-сертификатов)
- [Шаг 2 — Настройка .env](#шаг-2--настройка-env)
- [Шаг 3 — Генерация CLUSTER\_ID](#шаг-3--генерация-cluster_id)
- [Шаг 4 — Запуск кластера](#шаг-4--запуск-кластера)
- [Шаг 5 — Проверка](#шаг-5--проверка)
- [Управление топиками](#управление-топиками)
- [Полезные команды](#полезные-команды)
- [Устранение неполадок](#устранение-неполадок)

---

## Архитектура

```
kafka-node-01   kafka-node-02   kafka-node-03
     │                │                │
     └────────────────┴────────────────┘
              KRaft Controller Quorum
              (порт 9093, PLAINTEXT)

Внутренняя связь между брокерами : порт 9094 (PLAINTEXT)
Внешние клиенты (Filebeat, Logstash): порт 9092 (SSL)
```

| Listener   | Порт | Протокол  | Кто подключается              |
|------------|------|-----------|-------------------------------|
| CONTROLLER | 9093 | PLAINTEXT | KRaft quorum (только внутри)  |
| INTERNAL   | 9094 | PLAINTEXT | Межброкерная репликация       |
| EXTERNAL   | 9092 | SSL       | Filebeat, Logstash (клиенты)  |

> **Важно:** Logstash и Filebeat подключаются **только на порт 9092 (SSL)**.  
> Порт 9094 — только для внутренней связи между брокерами.

---

## Требования

- Docker 24.0+
- Docker Compose 2.20+
- OpenSSL 3.0+
- ОЗУ: минимум 2 ГБ на узел

### Установка Docker

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt install docker-compose-v2 -y
```

---

## Структура репозитория

```
kafka/
├── docker-compose.yml
├── .env.template
└── certs/              # создаётся вручную (см. Шаг 1)
    ├── ca.crt
    ├── ca.key          # только на kafka-node-01, не копировать!
    ├── kafka.crt
    ├── kafka.key
    └── kafka-keystore.pem
```

---

## Шаг 1 — Генерация SSL-сертификатов

> Все команды выполняются **один раз** на `kafka-node-01`.  
> Затем нужные файлы копируются на остальные узлы через Python HTTP-сервер.

```bash
mkdir -p ~/kafka/certs && cd ~/kafka/certs
```

### 1.1 Создать корневой CA

```bash
# Приватный ключ CA
openssl genrsa -out ca.key 4096

# Самоподписанный сертификат CA (10 лет)
openssl req -new -x509 -days 3650 \
  -key ca.key \
  -out ca.crt \
  -subj "/CN=Kafka-CA/O=MyOrg/C=RU"
```

### 1.2 Создать сертификат для Kafka

```bash
# Приватный ключ
openssl genrsa -out kafka.key 2048

# Запрос подписи (CSR)
openssl req -new \
  -key kafka.key \
  -out kafka.csr \
  -subj "/CN=kafka/O=MyOrg/C=RU"

# Подписать через CA
openssl x509 -req -days 3650 \
  -in kafka.csr \
  -CA ca.crt \
  -CAkey ca.key \
  -CAcreateserial \
  -out kafka.crt
```

### 1.3 Собрать keystore.pem

Kafka в PEM-режиме ожидает один файл: сертификат + приватный ключ + цепочка CA:

```bash
cat kafka.crt kafka.key ca.crt > kafka-keystore.pem
```

### 1.4 Выставить права на файлы

```bash
cd ~/kafka
sudo chmod -R 644 certs/
sudo chmod 755 certs/
```

### 1.5 Распределить сертификаты на остальные узлы

Используем Python HTTP-сервер для передачи файлов.

**На kafka-node-01** (откуда раздаём):

```bash
cd ~/kafka/certs
python3 -m http.server 8888
```

**На kafka-node-02 и kafka-node-03** (скачиваем):

```bash
mkdir -p ~/kafka/certs && cd ~/kafka/certs

# Скачать нужные файлы (ca.key НЕ копируем)
wget http://<IP_KAFKA_NODE_01>:8888/ca.crt
wget http://<IP_KAFKA_NODE_01>:8888/kafka.crt
wget http://<IP_KAFKA_NODE_01>:8888/kafka.key
wget http://<IP_KAFKA_NODE_01>:8888/kafka-keystore.pem
```

После скачивания — остановить сервер на kafka-node-01 (`Ctrl+C`).

> **`ca.key` никуда не копировать и хранить в безопасном месте.**

---

## Шаг 2 — Настройка .env

На **каждом** Kafka-узле:

```bash
cd ~/kafka
cp .env.template .env
nano .env
```

| Переменная                 | Описание                                      | Пример                                                          |
|----------------------------|-----------------------------------------------|-----------------------------------------------------------------|
| `NODE_NAME`                | Уникальное имя ноды                           | `node-01` / `node-02` / `node-03`                              |
| `KAFKA_NODE_ID`            | Уникальный числовой ID ноды                   | `1` / `2` / `3`                                                 |
| `INTERNAL_IP`              | Локальный IP **этого** сервера                | `192.168.1.10`                                                  |
| `EXTERNAL_IP`              | Внешний IP **этого** сервера                  | `10.0.0.10`                                                     |
| `KAFKA_QUORUM_VOTERS`      | Все три контроллера (одинаково на всех узлах) | `1@192.168.1.10:9093,2@192.168.1.11:9093,3@192.168.1.12:9093`  |
| `KAFKA_CLUSTER_ID`         | UUID кластера — **одинаковый на всех узлах**  | см. Шаг 3                                                       |
| `KAFKA_REPLICATION_FACTOR` | `3` для трёх узлов, `1` для одного            | `3`                                                             |
| `KAFKA_MIN_ISR`            | `2` для трёх узлов, `1` для одного            | `2`                                                             |

> Имя контейнера формируется как `kafka-${NODE_NAME}`. При `NODE_NAME=node-01` контейнер будет называться `kafka-node-01`.

---

## Шаг 3 — Генерация CLUSTER\_ID

> Выполнить **один раз** на любом узле. Полученный UUID вставить в `.env` на **всех трёх** узлах.

```bash
docker run --rm apache/kafka:3.9.2 kafka-storage.sh random-uuid
```

Пример вывода: `AbCdEfGhIjKlMnOpQrStUv`

Вставить результат в `.env` на каждом узле:

```dotenv
KAFKA_CLUSTER_ID=AbCdEfGhIjKlMnOpQrStUv
```

---

## Шаг 4 — Запуск кластера

> **Запускать на всех трёх узлах в течение ~2 минут.**  
> Если узлы стартуют с большим разрывом — KRaft quorum не соберётся.

```bash
cd ~/kafka
docker compose up -d
```

Проверить что контейнер запустился:

```bash
docker ps
docker logs kafka-node-01 --tail 50
```

---

## Шаг 5 — Проверка

> Все kafka-команды внутри контейнера находятся по пути `/opt/kafka/bin/`.

### Статус quorum

```bash
docker exec -it kafka-node-01 \
  /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server localhost:9094 \
  describe --status
```

Ожидаемый результат: все три ноды отображаются в секции `Voters`.

### Список брокеров

```bash
docker exec -it kafka-node-01 \
  /opt/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server localhost:9094
```

---

## Управление топиками

```bash
# Создать топик kafka-logs вручную (если auto.create.topics не сработал)
docker exec -it kafka-node-01 \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9094 \
  --create \
  --topic kafka-logs \
  --partitions 3 \
  --replication-factor 3

# Список топиков
docker exec -it kafka-node-01 \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9094 \
  --list

# Детали топика
docker exec -it kafka-node-01 \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9094 \
  --describe \
  --topic kafka-logs
```

---

## Полезные команды

```bash
# Логи контейнера
docker logs kafka-node-01 -f --tail 100

# Перезапуск
docker compose restart kafka

# Остановка (данные сохраняются в volumes)
docker compose down

# Статус consumer group Logstash (появится только после первого подключения Logstash)
docker exec -it kafka-node-01 \
  /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9094 \
  --describe \
  --group logstash-diploma-v2
```

---

## Устранение неполадок

| Симптом | Причина | Решение |
|---------|---------|---------|
| `executable file not found in $PATH` при вызове kafka-*.sh | Скрипты не в PATH | Использовать полный путь `/opt/kafka/bin/kafka-*.sh` |
| `LEADER_NOT_AVAILABLE` при создании топика | Не все брокеры успели стартовать | Подождать 30–60 сек, повторить |
| Брокеры не видят друг друга | Разные `CLUSTER_ID` или неверные IP в `KAFKA_QUORUM_VOTERS` | Проверить `.env` на всех узлах |
| Filebeat: `SSL handshake failed` | Неверный `ca.crt` или путь к нему | Проверить `/etc/filebeat/certs/ca.crt` |
| Logstash: `Failed to create new NetworkClient` | Logstash подключается на порт 9094 вместо 9092 | В `.env` ELK-узла: `KAFKA_BOOTSTRAP_SERVERS=IP:9092,...` |
| Контейнер падает при старте | `kafka-keystore.pem` собран неверно | Пересобрать: `cat kafka.crt kafka.key ca.crt > kafka-keystore.pem` |
| Consumer group не существует | Logstash ещё не подключался | Норма — группа создаётся при первом подключении Logstash |
