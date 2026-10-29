# GPU LLM Deployment (Ansible + NVIDIA + Docker + Ollama)

Ansible-проект для подготовки Ubuntu-сервера с NVIDIA GPU и запуска LLM через Ollama REST API. Playbook настраивает Docker, при необходимости устанавливает драйвер NVIDIA через `ubuntu-drivers`, устанавливает NVIDIA Container Toolkit, разворачивает Ollama, скачивает модель и выполняет smoke test генерации.

> **Статус проверки:** проект подготовлен без доступа к целевому серверу с NVIDIA GPU. Скрипт `setup-nvidia-g4dn.sh` включён в репозиторий на основе предоставленного пользователем варианта. Реальный запуск драйвера, GPU passthrough и GPU-инференса необходимо проверить на AWS EC2 G4dn; не считайте аппаратные проверки пройденными до такого запуска.

## Архитектура

- Ubuntu 22.04 / 24.04, архитектура `amd64` или `arm64`. Ubuntu 26.04 намеренно не разрешена конфигурацией проекта, пока отдельно не проверены драйверы и пакеты.
- Ansible на управляющей машине; подключение к серверу по SSH.
- Драйвер NVIDIA на хостовой ОС (устанавливается через `ubuntu-drivers install --gpgpu`, если `nvidia-smi` ещё не работает).
- Docker Engine и Docker Compose plugin из официального Docker APT-репозитория.
- NVIDIA Container Toolkit для передачи GPU в контейнер.
- Ollama в Docker Compose; образ по умолчанию закреплён на `ollama/ollama:0.40.13`, модель — `qwen2.5:3b`. Проверь версию перед намеренным обновлением.
- Ollama API по умолчанию опубликован только на `127.0.0.1:11434`, поскольку Ollama API сам по себе не следует считать защищённым внешним API.

## Требования

### Для целевого GPU-сервера

- Поддерживаемая Ubuntu и NVIDIA GPU, доступная ОС (например, через PCI passthrough, если это виртуальная машина).
- Пользователь SSH с `sudo`/become.
- Доступ в интернет для установки пакетов, загрузки контейнеров и модели.
- Достаточно места на диске для Docker-образа и весов модели. Размер модели зависит от выбранной модели и версии.
- Перед работами с драйвером согласуйте окно перезагрузки. Playbook может автоматически перезагрузить хост после установки драйвера. При `nvidia_reboot_after_driver_install=false` он пометит отложенную перезагрузку и намеренно пропустит GPU Toolkit/Ollama до повторного запуска после перезагрузки.

### Для управляющей машины

Python 3 и Ansible. Управляющая машина не обязана иметь GPU; это не означает, что GPU-инференс можно полноценно протестировать без GPU-сервера.

## Быстрый старт

### 1. Подготовить Ansible

Python controller environment должен удовлетворять версии `ansible-core`, доступной через `requirements.txt` (Ansible Core 2.17 или новее и младше 2.23). Коллекция `community.docker` закреплена в `requirements.yml` на версии 5.4.0. При GPU-развёртывании роль NVIDIA Container Toolkit устанавливает пакет `python3-docker`, который нужен модулю Ansible `community.docker.docker_image`; это покрывает и сценарий, где Docker уже установлен отдельно.

В корне проекта:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

### 2. Настроить inventory

Отредактируйте `inventory/hosts.yml`:

```yaml
all:
  children:
    gpu_servers:
      hosts:
        gpu01:
          ansible_host: 203.0.113.25 # заменить на реальный адрес
          ansible_user: ubuntu
          ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

`192.0.2.10` в начальном inventory — демонстрационный адрес, а не реальный сервер. Не забудьте заменить его. Убедитесь, что вы можете подключиться к серверу по SSH до запуска Playbook.

### 3. Настроить параметры

Переменные находятся в `group_vars/gpu_servers.yml`:

- `ollama_model` — модель для загрузки (по умолчанию `qwen2.5:3b`).
- `ollama_image` — закреплённый тег Docker image Ollama (в текущей версии проекта `ollama/ollama:0.40.13`). При обновлении задайте проверенный тег явно; для более строгой supply-chain воспроизводимости закрепите digest образа.
- `ollama_bind_address` — интерфейс публикации API, по умолчанию `127.0.0.1`.
- `ollama_enable_gpu` — GPU-режим, по умолчанию `true`.
- `nvidia_driver_method` — способ установки драйвера: `ubuntu_drivers` (по умолчанию) или `g4dn_script` для собственного установочного скрипта AWS EC2 G4dn.
- `nvidia_reboot_after_driver_install` — перезагружать ли сервер после установки драйвера, по умолчанию `true`.
- `ollama_validate_generation` — выполнять ли реальный тест генерации после загрузки модели.
- `ollama_min_free_disk_gb` — минимальное свободное место на файловой системе Docker data root перед загрузкой образа/модели.
- `ollama_require_gpu_inference` — в GPU-режиме проверить `ollama ps` и убедиться, что активная модель использует GPU.
- `docker_preinstalled`, `nvidia_driver_preinstalled`, `nvidia_container_toolkit_preinstalled` — явно сообщить, что эти компоненты уже установлены и управляются вне проекта. Если Docker уже настроен сторонним способом, установи `docker_preinstalled: true`; перед миграцией не удаляй конфликтующие пакеты, пока не изучишь контейнеры и volumes.

### Использование собственного скрипта для AWS EC2 G4dn

Файл `setup-nvidia-g4dn.sh` уже лежит в корне проекта. Он основан на твоём скрипте и запускается Ansible только при выборе `nvidia_driver_method: "g4dn_script"`. Он рассчитан именно на AWS EC2 G4dn, Ubuntu 22.04/24.04 и x86_64; для других серверов используй `ubuntu_drivers`.

1. Проверь содержимое `setup-nvidia-g4dn.sh` и при необходимости адаптируй его.
2. В `group_vars/gpu_servers.yml` измени параметры:

```yaml
nvidia_driver_method: "g4dn_script"
nvidia_g4dn_script_name: "setup-nvidia-g4dn.sh"
nvidia_g4dn_script_destination: "/usr/local/sbin/setup-nvidia-g4dn.sh"
nvidia_g4dn_script_args:
  - "--no-reboot"
nvidia_reboot_after_driver_install: true
```

3. Запусти обычный Playbook. Если `nvidia-smi` уже работает, установка будет пропущена. Иначе Ansible скопирует скрипт, запустит его асинхронно с указанными аргументами, при необходимости перезагрузит сервер и затем повторно проверит `nvidia-smi`.

Ansible передаёт только `--no-reboot`, чтобы перезагрузкой управлял сам Playbook. Не добавляй `--docker`, если не хочешь, чтобы твой скрипт также устанавливал/менял Docker: в проекте Docker и NVIDIA Container Toolkit настраиваются отдельными ролями. Добавляй `--cuda` только если это действительно требуется твоему сценарию. Скрипт сохраняет поддержку флагов `--cuda`, `--docker` и `--no-reboot`. Для данного проекта не передавай `--docker`: Docker и NVIDIA Container Toolkit устанавливаются отдельными идемпотентными Ansible-ролями. CUDA Toolkit обычно не нужен для Ollama, поэтому `--cuda` также не требуется.

Перед применением проверь скрипт и его источник. Важный нюанс: скрипт выполняет `apt-get update` и `apt-get upgrade`, поэтому может обновить ядро и другие системные пакеты. Запускай его на чистом/подготовленном G4dn в согласованное окно обслуживания, а не на неизвестном действующем сервере. Не запускай неизвестный инсталлятор от root без изучения содержимого.

В этом проекте используется версионированный тег Ollama, а не `latest`. Для строгой воспроизводимости production-окружения следует зафиксировать полный image digest и обновлять его через контролируемый change-процесс с тестированием и возможностью отката.

### 4. Проверить синтаксис

```bash
./tests/test_config.sh
# или
ansible-playbook -i inventory/hosts.yml playbook.yml --syntax-check
```

Этот шаг не подключается к серверу и не доказывает работоспособность драйверов или GPU.

### 5. Выполнить Playbook

```bash
ansible-playbook -i inventory/hosts.yml playbook.yml --ask-become-pass
```

Если SSH-ключ уже настроен и `sudo` не требует пароля, `--ask-become-pass` можно опустить. Ansible установит пакеты, настроит runtime, при необходимости перезагрузит сервер, загрузит модель и проверит генерацию.

Перед применением на существующем сервере сначала изучите изменения. Роль Docker теперь останавливается до установки, если обнаруживает известные конфликтующие пакеты (`docker.io`, `containerd`, `runc` и др.); она не удаляет их автоматически и не трогает Docker data root. Осознанную миграцию существующей установки нужно провести отдельно. Установка драйвера может вызвать перезагрузку.

## Тестирование без NVIDIA GPU

Режим CPU-only предназначен для проверки развёртывания Ollama на Ubuntu VM или Ubuntu-хосте без GPU. Он **не проверяет** установку NVIDIA-драйвера и GPU passthrough.

1. Создайте Ubuntu VM или используйте отдельную тестовую Ubuntu-машину.
2. В `inventory/localhost.yml` используется локальное подключение. Запустите команды из корня проекта на самой Ubuntu-машине:

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/localhost.yml playbook.yml \
  -e 'ollama_enable_gpu=false' \
  -e 'install_nvidia_driver=false' \
  -e 'install_nvidia_container_toolkit=false' \
  --ask-become-pass
```

В этом режиме Playbook установит Docker, запустит Ollama без GPU, загрузит ту же модель и выполнит API smoke test. Для локального сценария нужны права sudo и доступ в интернет; загрузка модели может занять заметное время и место на диске.

Для проверки только синтаксиса GPU не нужен:

```bash
./tests/test_config.sh
```

Режим `--check` допустим для предварительного просмотра, но не заменяет реальную установку: некоторые команды и сетевые действия не могут быть корректно симулированы Ansible check mode.

## Проверка GPU после установки

На целевом сервере:

```bash
nvidia-smi
```

Проверка NVIDIA runtime из Docker (используется CUDA base image, где доступна утилита `nvidia-smi`; обычный `ubuntu:24.04` её не содержит):

```bash
docker run --rm --gpus all nvidia/cuda:12.2.2-base-ubuntu22.04 nvidia-smi
```

Проверка запущенного Ollama и загруженной модели:

```bash
docker ps --filter name=ollama
docker logs --tail=100 ollama
docker exec ollama ollama list
curl --fail http://127.0.0.1:11434/api/version
curl --fail http://127.0.0.1:11434/api/tags
```

Проверка реальной генерации:

```bash
./tests/test_api.sh
```

Для другой модели укажите `OLLAMA_MODEL`, а для другого API URL — `OLLAMA_URL`:

```bash
OLLAMA_MODEL='qwen2.5:3b' OLLAMA_URL='http://127.0.0.1:11434' ./tests/test_api.sh
```

## Пример API-запроса

Генерация обычного текста через Ollama REST API:

```bash
curl --fail --silent --show-error \
  http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen2.5:3b",
    "prompt": "Объясни, что такое Ansible, в двух предложениях.",
    "stream": false
  }'
```

При успехе API вернёт JSON с полем `response`. Дополнительная документация: <https://github.com/ollama/ollama/blob/main/docs/api.md>.

## Безопасный удалённый доступ

Так как порт опубликован только на loopback, обращайтесь к API с локального компьютера через SSH-туннель:

```bash
ssh -N -L 11434:127.0.0.1:11434 ubuntu@203.0.113.25
```

После запуска туннеля локально используйте `http://127.0.0.1:11434`.

Не публикуйте Ollama напрямую в интернет. Если нужен API для других машин, разместите перед Ollama reverse proxy с HTTPS и аутентификацией, настройте firewall и ограничение источников. Только после этого можно менять `ollama_bind_address`; для снятия защитного assert нужно явно установить `ollama_public_api_acknowledged=true`. Это подтверждение не включает защиту автоматически — она должна быть настроена отдельно.

## Автозапуск и диагностика

Контейнер использует `restart: unless-stopped`, поэтому Docker восстановит его после перезапуска хоста, если Docker-сервис включён. Весы модели находятся в постоянном Docker volume `ollama_data`.

Полезные команды:

```bash
sudo systemctl status docker
sudo docker compose -f /opt/ollama/compose.yml ps
sudo docker logs --tail=200 ollama
sudo docker exec ollama ollama list
sudo docker inspect --format='{{json .State.Health}}' ollama
```

Если API не отвечает, проверьте сначала `docker ps` и логи контейнера, затем наличие модели и свободное место на диске. Если `nvidia-smi` на хосте работает, а внутри контейнера нет — проверьте NVIDIA Container Toolkit и повторите тест `docker run --gpus all ... nvidia-smi`. После smoke test в GPU-режиме Playbook также проверяет вывод `ollama ps`; если Ollama генерирует на CPU, deployment завершится ошибкой, чтобы не скрывать проблему GPU.

## Мониторинг и дальнейшее улучшение

- GPU: NVIDIA DCGM Exporter + Prometheus/Grafana для загрузки, температуры, VRAM и других метрик.
- API: мониторинг `GET /api/version`, latency генерации, ошибок и времени загрузки модели.
- Безопасность: authenticated reverse proxy, HTTPS, firewall, ограничение сетевых источников и Ansible Vault для секретов.
- Повторяемость: закрепить версию Ollama image, контролировать версии драйвера и фиксировать выбранную модель.
- Нагрузочное тестирование: измерить latency и throughput на конкретной GPU и ожидаемой конкурентности.

## Использованные официальные руководства

- Docker Engine on Ubuntu: <https://docs.docker.com/engine/install/ubuntu/>
- NVIDIA Container Toolkit installation: <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html>
- Ollama Docker image: <https://github.com/ollama/ollama/blob/main/docs/docker.mdx>
- Ollama API: <https://github.com/ollama/ollama/blob/main/docs/api.md>

## Ограничения

Это базовый инфраструктурный шаблон для одного сервера, а не полноценный HA-кластер или production inference platform. Он не создаёт reverse proxy и не выдаёт API-ключи; наружный API требует отдельной конфигурации безопасности. Поддержка конкретного GPU и соответствие драйвера должны быть подтверждены на целевой машине. Фактическая производительность зависит от модели, VRAM, GPU и нагрузки.
