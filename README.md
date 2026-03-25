# Kafka Cluster (KRaft mode)

Развёртывание трёхузлового кластера Apache Kafka 3.9.2 в режиме **KRaft** (без ZooKeeper) с SSL-шифрованием внешних подключений.

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

| Listener   | Порт | Протокол  | Кто подключается             |
|------------|------|-----------|------------------------------|
| CONTROLLER | 9093 | PLAINTEXT | KRaft quorum (только внутри) |
| INTERNAL   | 9094 | PLAINTEXT | Межброкерная репликация      |
| EXTERNAL   | 9092 | SSL       | Filebeat, Logstash (клиенты)|

---

## Требования

- Docker 24.0+
- Docker Compose 2.20+
- OpenSSL 3.0+
- ОЗУ: минимум 2 ГБ на узел

---

## Структура репозитория

```
kafka/
├── docker-compose.yml
├── .env.template
└── certs/              # создаётся вручную (см. Шаг 1)
    ├── ca.crt
    ├── kafka.crt
    ├── kafka.key
    └── kafka-keystore.pem
```

---

## Шаг 1 — Генерация SSL-сертификатов

> **Важно:** сертификаты генерируются **один раз** на любом узле (например, `kafka-node-01`),
> затем одни и те же файлы копируются на все остальные узлы.

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

### 1.4 Распределить сертификаты на остальные узлы

```bash
for NODE in kafka-node-02 kafka-node-03; do
  ssh user@$NODE "mkdir -p ~/kafka/certs"
  scp ~/kafka/certs/{ca.crt,kafka.crt,kafka.key,kafka-keystore.pem} \
    user@$NODE:~/kafka/certs/
done
```

> **`ca.key` никуда не копировать и хранить в безопасном месте.**

---

## Шаг 2 — Настройка .env

На **каждом** узле:

```bash
cd ~/kafka
cp .env.template .env
nano .env
```

| Переменная               | Описание                                     | Пример                                                          |
|--------------------------|----------------------------------------------|-----------------------------------------------------------------|
| `NODE_NAME`              | Уникальное имя ноды                          | `node-01`                                                       |
| `KAFKA_NODE_ID`          | Уникальный числовой ID ноды                  | `1` / `2` / `3`                                                 |
| `INTERNAL_IP`            | Локальный IP **этого** сервера               | `192.168.1.10`                                                  |
| `EXTERNAL_IP`            | Внешний IP **этого** сервера                 | `10.0.0.10`                                                     |
| `KAFKA_QUORUM_VOTERS`    | Все три контроллера (одинаково везде)        | `1@192.168.1.10:9093,2@192.168.1.11:9093,3@192.168.1.12:9093`  |
| `KAFKA_CLUSTER_ID`       | UUID кластера — **одинаковый на всех узлах** | см. Шаг 3                                                       |
| `KAFKA_REPLICATION_FACTOR` | `3` для трёх узлов, `1` для одного        | `3`                                                             |
| `KAFKA_MIN_ISR`          | `2` для трёх узлов, `1` для одного           | `2`                                                             |

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

> **Запускать на всех трёх узлах в течение ~2 минут.** Если узлы стартуют с большим разрывом,
> KRaft quorum не соберётся и контейнеры зациклятся в ошибках.

```bash
cd ~/kafka
docker compose up -d
```

---

## Шаг 5 — Проверка

### Статус quorum

```bash
docker exec -it kafka-node-01 \
  kafka-metadata-quorum.sh \
  --bootstrap-server localhost:9094 \
  describe --status
```

Ожидаемый результат: все три ноды отображаются в секции `Voters`.

### Список брокеров

```bash
docker exec -it kafka-node-01 \
  kafka-broker-api-versions.sh \
  --bootstrap-server localhost:9094
```

---

## Управление топиками

```bash
# Создать топик kafka-logs вручную (если auto.create.topics не сработал)
docker exec -it kafka-node-01 \
  kafka-topics.sh \
  --bootstrap-server localhost:9094 \
  --create \
  --topic kafka-logs \
  --partitions 3 \
  --replication-factor 3

# Список топиков
docker exec -it kafka-node-01 \
  kafka-topics.sh --bootstrap-server localhost:9094 --list

# Детали топика
docker exec -it kafka-node-01 \
  kafka-topics.sh \
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

# Статус consumer group Logstash
docker exec -it kafka-node-01 \
  kafka-consumer-groups.sh \
  --bootstrap-server localhost:9094 \
  --describe \
  --group logstash-diploma-v2
```

---

## Устранение неполадок

| Симптом | Причина | Решение |
|---------|---------|---------|
| `LEADER_NOT_AVAILABLE` при создании топика | Не все брокеры успели стартовать | Подождать 30–60 сек, повторить |
| Брокеры не видят друг друга | Разные `CLUSTER_ID` или неверные IP в `KAFKA_QUORUM_VOTERS` | Проверить `.env` на всех узлах |
| Filebeat: `SSL handshake failed` | Неверный `ca.crt` или путь | Проверить `/etc/filebeat/certs/ca.crt` |
| Контейнер падает при старте | `kafka-keystore.pem` собран неверно или отсутствует | Пересобрать: `cat kafka.crt kafka.key ca.crt > kafka-keystore.pem` |
