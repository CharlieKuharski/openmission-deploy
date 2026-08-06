# OpenMission

OpenMission turns a plain-language application idea into a working, tested
application. It writes the Story and acceptance criteria, generates the
application, validates each criterion in a browser, and preserves the source
and test evidence on your machine.

This repository is the public, source-free Docker deployment for OpenMission.
It contains no application source and performs no local image builds.

> **Early access:** The OpenMission application source repository is not public
> yet. The container distribution and these deployment files are available
> under the [Apache License 2.0](LICENSE). OpenMission Cloud and public source
> availability are planned for future releases.

## Requirements

- [Install Docker with Docker Compose](https://docs.docker.com/get-started/get-docker/)
- [Install Ollama](https://ollama.com/download)
- macOS with Docker Desktop, including Apple Silicon; or Linux AMD64/ARM64
- Windows and WSL2 have not yet been validated

OpenMission runs Ollama directly on the host so local models can use the host's
GPU acceleration. Install the default models before starting, or pull and
select models from OpenMission's first-run Utility screen:

```bash
ollama pull hermes3:8b
ollama pull qwen3-coder:30b
```

The 30B coding model needs substantial memory. A practical reference system is
an Apple M4 Pro with 48 GB unified memory and a 1 TB SSD. Smaller models may be
selected from the Utility screen on machines with less memory.

## Install

Clone the immutable deployment release:

```bash
git clone --branch v0.1.0-rc.8 --depth 1 \
  https://github.com/CharlieKuharski/openmission-deploy.git openmission

cd openmission
cp .env.example .env
docker compose --env-file .env pull
docker compose --env-file .env up -d --wait
```

Open [http://127.0.0.1:15173](http://127.0.0.1:15173). On first startup,
OpenMission opens the Utility screen so you can verify Ollama, pull models, and
choose the global Thinking and Coding defaults.

Compose pulls the complete configured stack, including:

- [OpenMission API](https://hub.docker.com/r/charliekuharski/openmission)
- [OpenMission UI](https://hub.docker.com/r/charliekuharski/openmission-ui)
- [OpenMission Hermes](https://hub.docker.com/r/charliekuharski/openmission-hermes)
- Browserless, Playwright MCP, and SearXNG

No OpenMission source checkout is required.

## Data and Operations

Projects, generated application source, tests, and evidence are stored in
`./workspace`. OpenMission's SQLite database is stored in `./data`. The Hermes
runtime also uses the Compose-managed `openmission-hermes-data` volume.

Check service health:

```bash
docker compose --env-file .env ps
curl -f http://127.0.0.1:18080/api/health
```

Restart without deleting data:

```bash
docker compose --env-file .env restart
```

Stop OpenMission while preserving projects, SQLite, and the Hermes volume:

```bash
docker compose --env-file .env down
```

Back up the primary project data after stopping OpenMission:

```bash
tar -czf "openmission-backup-$(date +%Y%m%d).tar.gz" workspace data
```

Do not use `docker compose down --volumes` unless you intend to remove the
Hermes runtime volume. Do not delete `workspace` or `data` unless you intend to
remove generated projects or OpenMission state.

## Update

Deployment releases are immutable and match the Docker image version. To move
to a newer tested release:

```bash
NEW_VERSION=0.1.0-rc.8

git fetch --tags
git switch --detach "v${NEW_VERSION}"
sed -i.bak "s/^OPENMISSION_VERSION=.*/OPENMISSION_VERSION=${NEW_VERSION}/" .env
rm -f .env.bak
docker compose --env-file .env pull
docker compose --env-file .env up -d --wait
```

Set `NEW_VERSION` to the release you are installing. Review its release notes
before updating.

## Security

All published ports bind to `127.0.0.1` by default. The values supplied in
`.env.example` are local-only defaults. Replace every value ending in
`change-me` before remote access, reverse-proxy exposure, cloud deployment, or
use on a shared machine. Generate replacements with:

```bash
openssl rand -hex 32
```

The API and Hermes containers mount `/var/run/docker.sock` so OpenMission can
build and validate generated applications. Docker socket access is equivalent
to host-level administrative control. Run OpenMission only on a machine and
with container images you trust.

## Troubleshooting

Confirm Ollama is running and reachable on the host:

```bash
ollama list
curl -f http://127.0.0.1:11434/api/tags
```

Inspect service status and recent logs:

```bash
docker compose --env-file .env ps
docker compose --env-file .env logs --tail 100 api ui hermes-gateway
```

On macOS, keep this repository under a directory shared with Docker Desktop so
generated project bind mounts are available to Docker.
