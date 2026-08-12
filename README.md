<p align="center">
  <img src="assets/sg_github_3.png" alt="OpenMission Sugar Glider" width="180">
</p>

<h1 align="center">OpenMission</h1>

<h3 align="center">OpenMission gives project managers a faster, lower-cost path from business idea to development-ready project.</h3>

<p align="center">
  <a href="#why-openmission">Why OpenMission?</a> &bull;
  <a href="#-get-started">Get Started</a> &bull;
  <a href="#-requirements">Requirements</a> &bull;
  <a href="#-data-and-operations">Operations</a> &bull;
  <a href="#feedback">Feedback</a> &bull;
  <a href="#-troubleshooting">Troubleshooting</a>
</p>

<p align="center">
  <img alt="Public Technical Preview" src="https://img.shields.io/badge/status-public%20technical%20preview-f59e0b">
  <img alt="Docker Compose" src="https://img.shields.io/badge/runtime-Docker%20Compose-2496ed">
  <img alt="macOS validated" src="https://img.shields.io/badge/macOS-validated-34c759">
  <img alt="Linux AMD64 and ARM64" src="https://img.shields.io/badge/Linux-AMD64%20%7C%20ARM64-fcc624">
  <a href="LICENSE"><img alt="Apache License 2.0" src="https://img.shields.io/badge/deployment-Apache--2.0-d22128"></a>
</p>

<p align="center">
  <strong>You define the business need. OpenMission turns it into a tested project developers can continue.</strong>
</p>

> **Public technical preview:** OpenMission is available to anyone for
> experimentation and feedback. It is still evolving and is not recommended
> for production use. This source-free Docker deployment contains no
> OpenMission product source and performs no local OpenMission image builds.
> Public application source and OpenMission Cloud are planned for future
> releases.

## Why OpenMission?

<div>✅ <strong>Business-first</strong> — Turn your idea into a clear Story and acceptance criteria.</div>
<div>✅ <strong>Development-ready</strong> — Generate working source and executable tests developers can continue.</div>
<div>✅ <strong>Browser-verified</strong> — Validate each acceptance criterion through the visible application.</div>
<div>✅ <strong>Local AI</strong> — Iterate without recurring per-token inference charges.</div>
<div>✅ <strong>Secure and portable</strong> — Run isolated Docker services on supported macOS and Linux systems.</div>

> OpenMission verifies observable application behavior against the acceptance
> criteria. It does not replace engineering review for architecture, security,
> integrations, operations, or production readiness.

## Feedback

> [!NOTE]
> **Trying OpenMission?** This public technical preview is available for
> experimentation, and direct feedback is valuable.
>
> [Share your experience or report a problem](https://github.com/CharlieKuharski/openmission-deploy/issues/new).

Feedback can cover bugs, installation problems, feature requests,
project-generation results, or whether the generated project improved the
handoff to developers.

Include the OpenMission version, operating system and hardware, selected
Thinking and Coding models, expected behavior, actual behavior, and sanitized
screenshots or logs when useful.

Do not publish `.env` values, credentials, private prompts, confidential
generated source, or other sensitive information in a public issue.

## ⚡ Get Started
Install these prerequisites first:

* [Docker with Docker Compose](https://docs.docker.com/get-started/get-docker/)
* [Ollama](https://ollama.com/download)

Pull the default local models:

```bash
ollama pull hermes3:8b
ollama pull qwen3-coder:30b
```

Clone the immutable RC11 deployment and start OpenMission:

```bash
git clone --branch v0.1.0-rc.12 --depth 1 https://github.com/CharlieKuharski/openmission-deploy.git openmission

cd openmission
cp .env.example .env
docker compose --env-file .env pull
docker compose --env-file .env up -d --wait
```

Open http://127.0.0.1:15173.

On first startup, OpenMission opens the Utility screen so you can verify the
Ollama connection, pull other models by name, and choose the global Thinking
and Coding defaults.

Compose pulls and starts the complete configured stack; no OpenMission source
checkout or local image build is required.

The stack includes:

* [OpenMission API](https://hub.docker.com/r/charliekuharski/openmission)
* [OpenMission UI](https://hub.docker.com/r/charliekuharski/openmission-ui)
* [OpenMission Hermes](https://hub.docker.com/r/charliekuharski/openmission-hermes)
* Browserless
* Playwright MCP
* SearXNG

## 🖥️ Requirements

| Platform                                   | Status                 |
| ------------------------------------------ | ---------------------- |
| macOS on Apple Silicon with Docker Desktop | Validated              |
| Linux AMD64 with Docker Engine and Compose | Validated              |
| Linux ARM64                                | Published images       |
| Windows and WSL2                           | **Validation pending** |

OpenMission runs Ollama directly on the host so local models can use the host's
GPU acceleration.

The default 30B coding model needs substantial memory. A practical reference
system is:

```text
Mac with Apple M4 Pro
48 GB unified memory
1 TB SSD
Docker Desktop
Ollama running on macOS
```

Machines with less memory can use smaller models selected from the Utility
screen. Model size affects generation quality, speed, and memory available for
Docker builds and browser validation.

## 💾 Data and Operations

OpenMission keeps its primary data beside the deployment:

* `./workspace` — generated applications, source, tests, and evidence
* `./data` — OpenMission SQLite database
* `openmission-hermes-data` — Compose-managed Hermes runtime volume

Check service health:

```bash
docker compose --env-file .env ps
curl -f http://127.0.0.1:18080/api/health
```

Restart without deleting data:

```bash
docker compose --env-file .env restart
```

Stop OpenMission while preserving data:

```bash
docker compose --env-file .env down
```

Back up project data after stopping OpenMission:

```bash
tar -czf "openmission-backup-$(date +%Y%m%d).tar.gz" workspace data
```

Do not use `docker compose down --volumes` unless you intend to remove the
Hermes runtime volume.

Do not delete `workspace` or `data` unless you intend to remove generated
projects or OpenMission state.

### Update

Deployment releases are immutable and match the Docker image version.

To move to a newer tested release:

```bash
NEW_VERSION=0.1.0-rc.13

git fetch --tags
git switch --detach "v${NEW_VERSION}"
sed -i.bak "s/^OPENMISSION_VERSION=.*/OPENMISSION_VERSION=${NEW_VERSION}/" .env
rm -f .env.bak
docker compose --env-file .env pull
docker compose --env-file .env up -d --wait
```

Set `NEW_VERSION` to the release you are installing and review its release
notes before updating.

## 🔒 Security

All published ports bind to `127.0.0.1` by default.

The values supplied in `.env.example` are local-only defaults. Replace every
value ending in `change-me` before remote access, reverse-proxy exposure, cloud
deployment, or use on a shared machine.

Generate replacements with:

```bash
openssl rand -hex 32
```

The API and Hermes containers mount `/var/run/docker.sock` so OpenMission can
build and validate generated applications. Docker socket access is equivalent
to host-level administrative control.

Run OpenMission only on a machine and with container images you trust.

## 🛠️ Troubleshooting

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

## 🚀 What's Next

**OpenMission Cloud is coming.**

The managed version will be for users who want OpenMission without operating
Docker, Ollama, models, or local infrastructure.

Public availability of the OpenMission application source is also planned for
a future release. This deployment repository will continue to provide tested,
versioned Compose configurations for published OpenMission images.

## License and Brand

The OpenMission container distribution and deployment materials are available
under the [Apache License 2.0](LICENSE).

The OpenMission name, logo, and OpenMission Sugar Glider artwork are excluded
from that license and remain reserved brand assets.

Truthful references such as "runs OpenMission" or "compatible with OpenMission"
are permitted when they do not imply endorsement or official status.
