# Harbor Private Registry — Self-Hosted Setup & Ops Notes

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Harbor](https://img.shields.io/badge/Harbor-v2.10.2-60B932)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED)

A hands-on guide to deploying [Harbor](https://goharbor.io/) — a private, self-hosted container registry — on a bare Ubuntu machine, secured with a self-signed TLS certificate, with multi-client push/pull access over a LAN.

This isn't just a copy of the official install docs. It documents the full path from a clean machine to a working registry, **including every failure encountered along the way** — TLS trust issues, DNS misconfiguration, and an intermittent stack failure — with root causes and fixes for each.

> **Environment note:** This was built and tested in a homelab/lab environment on a private LAN, not exposed to the public internet. Treat the security posture (self-signed certs, hardcoded example password) as lab-appropriate, not production-ready — see [Security Notes](docs/setup-guide.md#security-reminders).

---

## Architecture

```
┌────────────┐        HTTPS (443)        ┌─────────────────────────────────────┐
│   Client    │ ────────────────────────▶ │              nginx (TLS)              │
│ (worker /   │                            │        reverse proxy / ingress        │
│  workstation)│◀──────────────────────── └───────────────┬───────────────────────┘
└────────────┘        docker push/pull                     │
                                                             ▼
                                        ┌────────────────────────────────────┐
                                        │              harbor-core            │
                                        │   auth · projects · API · webhooks  │
                                        └───────┬─────────────┬──────────────┘
                                                 │             │
                                    ┌────────────▼───┐   ┌─────▼──────┐
                                    │   registry      │   │ jobservice │
                                    │ (image storage)  │   │ (scanning, │
                                    └────────────────┘   │  GC, etc.)  │
                                                          └─────────────┘
                                                 │
                                    ┌────────────▼───┐   ┌─────────────┐
                                    │  postgresql     │   │    redis     │
                                    │ (harbor-db)     │   │  (cache/queue)│
                                    └────────────────┘   └─────────────┘
```

See [assets/architecture-diagram.svg](assets/architecture-diagram.svg) for the rendered version.

---

## Quick Start

```bash
# 1. Install Docker + Docker Compose
sudo apt-get update -y && sudo apt-get install -y docker.io
sudo systemctl enable --now docker

# 2. Generate a self-signed cert with SAN (see docs/setup-guide.md for full script)
sudo mkdir -p /certs && cd /certs
sudo openssl req -newkey rsa:4096 -nodes -keyout registry.key -out registry.csr \
  -subj "/C=US/L=City/O=YourOrg/CN=registry.example.com"

# 3. Download & configure Harbor
wget https://github.com/goharbor/harbor/releases/download/v2.10.2/harbor-offline-installer-v2.10.2.tgz
tar -xvzf harbor-offline-installer-v2.10.2.tgz && cd harbor
cp harbor.yml.tmpl harbor.yml   # edit hostname, cert paths, admin password

# 4. Install
sudo ./prepare && sudo ./install.sh

# 5. Verify
sudo docker-compose ps
```

👉 **Full walkthrough with every configuration detail:** [docs/setup-guide.md](docs/setup-guide.md)

---

## What's in this repo

| Doc | What it covers |
|---|---|
| 📘 [Full Setup Guide](docs/setup-guide.md) | Complete step-by-step: dependencies, TLS cert, Harbor config, client connection, push/pull workflow |
| 🔧 [Troubleshooting Guide](docs/troubleshooting.md) | Every real error hit during setup, root cause, and fix — including the two-part TLS trust gotcha and the hosts-file client/server mixup |
| 📋 [Incident Postmortem](docs/postmortem-stack-down.md) | A production-style writeup of the Harbor stack silently dropping to a single container mid-operation, and how it was diagnosed and resolved |

---

## Key things I learned building this

- **TLS trust for a self-signed registry isn't one step, it's two.** Docker's daemon-level trust (`/etc/docker/certs.d/`) covers image layer transfers, but the OAuth token exchange during login/push validates against the **OS-wide CA store** separately. Missing either one produces a `x509: certificate signed by unknown authority` error that looks identical from the outside but has a different fix.
- **A hosts-file entry that's correct on the server is wrong on every client.** `127.0.0.1 <hostname>` only makes sense on the machine running Harbor itself; on any other machine it silently resolves to that machine's own loopback, producing a `connection refused` that looks like a firewall problem.
- **"It's running" and "it's healthy" aren't the same claim.** The full 10-container stack dropped to a single container mid-session with no crash log pointing at an obvious cause — worth always re-verifying `docker-compose ps` before debugging anything upstream of it. See the [postmortem](docs/postmortem-stack-down.md) for the full timeline.

---

## Tech Stack

`Docker` · `Docker Compose` · `Harbor v2.10.2` · `OpenSSL` (X.509 / SAN certs) · `Ubuntu` · `nginx` (via Harbor's bundled proxy)

---

## License

[MIT](LICENSE) — feel free to adapt this for your own homelab or internal registry setup.
