# Install OpenMission on Linux

These steps cover Docker Engine and a host Ollama service managed by systemd. End-to-end Linux validation is pending.

## 1. Install Docker Engine, Compose, and Ollama

Install Docker Engine, the Compose plugin, and Ollama on the host. Check that `docker version` shows a Server section and that `docker compose version` succeeds from the account you will use for OpenMission. [Docker Engine installation](https://docs.docker.com/engine/install/) · [Ollama on Linux](https://docs.ollama.com/linux)

## 2. Let the containers reach Ollama

Compose maps `host.docker.internal` to the Docker host. A fresh Ollama service listens on loopback, so containers cannot reach that listener. For a systemd installation, run the following **on the Linux host**. [Ollama service configuration](https://docs.ollama.com/faq#setting-environment-variables-on-linux)

```bash
sudo systemctl edit ollama.service
```

Add these lines in the editable section, then save and exit.

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

This listens on all host interfaces. Limit inbound TCP port 11434 to trusted clients, including OpenMission’s Docker network. Reload the service and check that Ollama responds.

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
curl --fail --show-error http://127.0.0.1:11434/api/tags
```

## 3. Pull the models

Choose a Thinking model and a Coding model from the [model guide](../../README.md#recommended-ollama-models-by-memory). For a discrete GPU, use its VRAM to choose a pair and leave system memory for Docker and the application. These commands pull Hermes3 8B and Qwen3-Coder 30B if that pair fits your machine.

```bash
ollama pull hermes3:8b
ollama pull qwen3-coder:30b
```

## 4. Download the release and configure socket access

```bash
git clone --branch v0.1.0-rc.22 --depth 1 https://github.com/CharlieKuharski/openmission-deploy.git openmission

cd openmission
cp .env.example .env
```

The API runs as a non-root user and needs the group that owns the host’s Docker socket. Print the setting for this machine.

```bash
stat -c 'OPENMISSION_DOCKER_GID=%g' /var/run/docker.sock
```

Replace the commented `# OPENMISSION_DOCKER_GID=0` line in `.env` with the printed line. This saves the group for future starts and upgrades. In the same file, set the model names to the ones you pulled. The following settings match the example above.

```dotenv
OPENMISSION_CHAT_MODEL=hermes3:8b
OPENMISSION_CODE_GEN_MODEL=qwen3-coder:30b
OPENMISSION_OLLAMA_MODEL=qwen3-coder:30b
```

## 5. Start OpenMission

```bash
docker compose --env-file .env pull
docker compose --env-file .env run --rm --no-deps --user 0 api /app/openmission-api prepare-runtime
docker compose --env-file .env up -d --wait
```

## 6. Verify the installation and open the app

Run the following commands in the deployment directory. The first two should print the Docker server version. The third exits successfully when the API can reach Ollama, and the last prints `Ollama reachable from Hermes`.

```bash
docker compose --env-file .env exec -T api docker info --format '{{.ServerVersion}}'
docker compose --env-file .env exec -T --user hermes hermes-gateway docker info --format '{{.ServerVersion}}'
docker compose --env-file .env exec -T api wget -q -T 10 -O /dev/null http://host.docker.internal:11434/api/tags
docker compose --env-file .env exec -T --user hermes hermes-gateway /opt/hermes/.venv/bin/python -c \
  'import urllib.request; urllib.request.urlopen("http://host.docker.internal:11434/api/tags", timeout=10).close(); print("Ollama reachable from Hermes")'
```

If the API reports a Docker socket permission error, check its group in `.env`. If Ollama responds on the host but the container check fails, check the Ollama service listener and firewall for port 11434.

Open [OpenMission](http://127.0.0.1:15173). On the Utility screen, verify the Ollama connection and select your Thinking and Coding models before starting your first project.
