# Install OpenMission on macOS

Apple Silicon with Docker Desktop is the recommended, validated installation. Run the commands below in Terminal.

## 1. Install Docker Desktop and Ollama

1. Install [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/), choosing the Apple Silicon download. Move Docker to Applications, open it, complete the first-run setup, and wait for the Docker engine to start. Docker Desktop includes Docker Compose.
2. Install [Ollama for macOS](https://docs.ollama.com/macos), move it to Applications, and open it. Complete its command-line setup so `ollama` is available in Terminal. Keep Ollama running directly on macOS so it can use the Mac's GPU.
3. Open a new Terminal window and check both prerequisites.

```bash
docker version
docker compose version
curl --fail --show-error http://127.0.0.1:11434/api/tags
```

`docker version` must show both Client and Server information. The Ollama check must return JSON. An empty model list is normal before you pull models. If a command is missing, finish the application's command-line setup and reopen Terminal. If a connection fails, open the corresponding application and wait for it to finish starting.

Keep Docker Desktop and Ollama running. The supplied settings let the containers reach Ollama on your Mac at `host.docker.internal:11434`. Docker Desktop uses the default socket group. [Docker Desktop host networking](https://docs.docker.com/desktop/features/networking/networking-how-tos/#connect-a-container-to-a-service-on-the-host)

## 2. Pull the models

Choose a Thinking model and a Coding model for your Mac’s unified memory using the [model guide](../../README.md#recommended-ollama-models-by-memory). These commands pull the recommended pair for a Mac with 48 GB of unified memory.

```bash
ollama pull hermes3:8b
ollama pull qwen3-coder:30b
```

## 3. Download and configure the release

```bash
git clone --branch v0.1.0-rc.22 --depth 1 https://github.com/CharlieKuharski/openmission-deploy.git openmission

cd openmission
cp .env.example .env
```

Open `.env` and set these three entries to the models you pulled. The following settings match the example above.

```dotenv
OPENMISSION_CHAT_MODEL=hermes3:8b
OPENMISSION_CODE_GEN_MODEL=qwen3-coder:30b
OPENMISSION_OLLAMA_MODEL=qwen3-coder:30b
```

## 4. Start OpenMission

```bash
docker compose --env-file .env pull
docker compose --env-file .env run --rm --no-deps --user 0 api /app/openmission-api prepare-runtime
docker compose --env-file .env up -d --wait
```

## 5. Verify the installation and open the app

Run the following commands in the deployment directory. The first two should print the Docker server version. The third exits successfully when the API can reach Ollama, and the last prints `Ollama reachable from Hermes`.

```bash
docker compose --env-file .env exec -T api docker info --format '{{.ServerVersion}}'
docker compose --env-file .env exec -T --user hermes hermes-gateway docker info --format '{{.ServerVersion}}'
docker compose --env-file .env exec -T api wget -q -T 10 -O /dev/null http://host.docker.internal:11434/api/tags
docker compose --env-file .env exec -T --user hermes hermes-gateway /opt/hermes/.venv/bin/python -c \
  'import urllib.request; urllib.request.urlopen("http://host.docker.internal:11434/api/tags", timeout=10).close(); print("Ollama reachable from Hermes")'
```

If a Docker check fails, confirm Docker Desktop is running and the active Docker context is `desktop-linux`. If an Ollama check fails, confirm the Ollama app is running.

Open [OpenMission](http://127.0.0.1:15173). On the Utility screen, verify the Ollama connection and select your Thinking and Coding models before starting your first project.
