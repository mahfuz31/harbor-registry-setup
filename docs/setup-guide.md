# Harbor Private Container Registry — Full Setup Guide

This guide walks through deploying a self-hosted [Harbor](https://goharbor.io/) container registry on a clean Ubuntu machine, securing it with a self-signed TLS certificate, and connecting multiple client machines to push/pull images over a LAN.

**Example values used throughout this guide** (replace with your own):
- Hostname: `registry.example.com`
- Server LAN IP: `192.168.1.50`
- Harbor version: `v2.10.2`

> 🔒 This setup uses a self-signed certificate and is intended for internal/lab networks. See [Security Reminders](#security-reminders) before exposing anything beyond a trusted LAN.

---

## 1. Install Core Dependencies (Docker + Docker Compose)

Run on the clean target Ubuntu machine that will host Harbor.

```bash
# Update local package repositories
sudo apt-get update -y && sudo apt-get upgrade -y

# Install the Docker Engine
sudo apt-get install -y docker.io
sudo systemctl enable --now docker

# Install the standalone Docker Compose binary (v2.26.0)
sudo curl -SL https://github.com/docker/compose/releases/download/v2.26.0/docker-compose-linux-x86_64 -o /usr/bin/docker-compose
sudo chmod +x /usr/bin/docker-compose

# Verify installation
docker --version
docker-compose version
```

> **Tip:** Add your user to the `docker` group (`sudo usermod -aG docker $USER`, then re-login) if you'd rather not prefix every Docker command with `sudo`.

---

## 2. Generate a TLS Certificate with a Subject Alternative Name (SAN)

Modern clients (including Docker) reject certificates that only set the legacy Common Name field — a SAN entry is required.

```bash
# Create a dedicated directory for certificate material
sudo mkdir -p /certs && cd /certs

# Generate a 4096-bit RSA private key + certificate signing request
sudo openssl req -newkey rsa:4096 -nodes -keyout registry.key \
  -out registry.csr \
  -subj "/C=US/L=City/O=YourOrg/CN=registry.example.com"

# Define the SAN extension (replace IP.1 with your server's actual LAN IP)
cat <<EOF | sudo tee registry.ext
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = registry.example.com
IP.1 = 192.168.1.50
EOF

# Self-sign the certificate (valid 365 days)
sudo openssl x509 -req -days 365 -in registry.csr \
  -signkey registry.key -out registry.crt \
  -extfile registry.ext
```

You should now have three files in `/certs`: `registry.key`, `registry.csr`, and `registry.crt`.

> A ready-to-run version of this step is in [`scripts/generate-cert.sh`](../scripts/generate-cert.sh).

---

## 3. Download and Extract the Harbor Offline Installer

The offline bundle avoids dependency on upstream image mirrors during installation.

```bash
mkdir -p ~/harbor/ && cd ~/harbor/

wget https://github.com/goharbor/harbor/releases/download/v2.10.2/harbor-offline-installer-v2.10.2.tgz

tar -xvzf harbor-offline-installer-v2.10.2.tgz
cd harbor
```

---

## 4. Configure `harbor.yml`

Copy the template and edit it:

```bash
cp harbor.yml.tmpl harbor.yml
sudo nano harbor.yml
```

Set the following values (see [`harbor.yml.example`](../harbor.yml.example) in this repo for a full annotated reference):

```yaml
hostname: registry.example.com

http:
  port: 80

https:
  port: 443
  certificate: /certs/registry.crt
  private_key: /certs/registry.key

harbor_admin_password: <CHANGE_ME>
data_volume: /data
```

**Checklist before saving:**
- [ ] The `https:` block is **uncommented** (no leading `#`).
- [ ] `port`, `certificate`, and `private_key` are indented exactly **two spaces** under `https:`.
- [ ] `certificate` and `private_key` paths match where you generated the cert in Step 2.
- [ ] Change `harbor_admin_password` from the default before going anywhere near production.

---

## 5. Install and Start Harbor

```bash
# Clear out any previous/broken container state
sudo docker-compose down

# Generate final configs from harbor.yml
sudo ./prepare

# Build and start the full Harbor stack
sudo ./install.sh
```

### Verify the deployment

```bash
sudo docker-compose ps
```

You should see 10 containers, including `nginx` (Harbor's TLS-terminating proxy — this is the one listening on ports 80/443, despite the plain name), `harbor-core`, `harbor-db`, `harbor-portal`, `registry`, `redis`, `harbor-jobservice`, `harbor-log`, `registryctl`, each reporting `Up` or `Up (healthy)`.

> **Naming note:** the *service* name for the database in `docker-compose.yml` is `postgresql`, but the *container* name is `harbor-db`. `sudo docker-compose logs db` will fail with `no such service: db` — use `sudo docker-compose logs postgresql` instead.

Once healthy, the web UI is reachable at `https://registry.example.com` (after the hosts-file step below).

> ⚠️ The stack can silently drop containers over time — always re-check `sudo docker-compose ps` before debugging push/pull errors. See [docs/troubleshooting.md](troubleshooting.md#stack-stability) and [docs/postmortem-stack-down.md](postmortem-stack-down.md).

---

## 6. Connect Client Machines

> ⚠️ **Repeat every step in this section on each machine** that will push or pull images — the server, and every worker/workstation. Configuration doesn't propagate between machines.

### Step A — DNS override via hosts file

**On the Harbor server itself** (`/etc/hosts`):
```
127.0.0.1 registry.example.com
```

**On every client/workstation machine** (`/etc/hosts` on Linux/macOS, `C:\Windows\System32\drivers\etc\hosts` on Windows) — point to the server's actual LAN IP, **not** `127.0.0.1`:
```
192.168.1.50 registry.example.com
```

> 🔴 **Common mistake:** copying the server's `127.0.0.1` line onto a client. On a client, that resolves to itself — nothing is listening there, producing `connection refused`, which looks like a firewall problem but is actually a bad hosts entry.

### Step B — Trust the self-signed certificate

This needs to happen in **two separate places** on each client:

1. **Docker's own registry trust store** — used for image layer/blob transfers.
2. **The OS-wide CA trust store** — used for the OAuth token exchange (`/service/token`) during `docker login`/`push`/`pull`. Skipping this produces `x509: certificate signed by unknown authority` even when Docker's daemon-level trust is already set up correctly.

**On Linux, do both:**

```bash
# 1. Docker daemon trust (per-registry)
sudo mkdir -p /etc/docker/certs.d/registry.example.com
sudo cp /certs/registry.crt /etc/docker/certs.d/registry.example.com/ca.crt

# 2. OS-wide trust (covers the OAuth token endpoint)
sudo cp /certs/registry.crt /usr/local/share/ca-certificates/registry.crt
sudo update-ca-certificates

# Restart Docker to pick up both changes
sudo systemctl restart docker
```

**Alternative — Docker Desktop (Mac/Windows):**
```json
{
  "insecure-registries": ["registry.example.com"]
}
```
Settings → Docker Engine → paste the above → Apply & Restart.

> ⚠️ `insecure-registries` disables certificate verification entirely — fine for a lab, not for anything beyond it.

### Step C — Verify connectivity before touching Docker

```bash
ping -c 3 192.168.1.50
curl -k https://registry.example.com/api/v2.0/health
```

Also see [`scripts/health-check.sh`](../scripts/health-check.sh) for a scripted version of this check.

- `ping` fails → routing/subnet issue, not a Harbor problem.
- `curl` hangs/refuses → nothing listening on 443 (check the stack is up).
- `curl` succeeds → network's fine, any remaining errors are Docker/cert/auth-specific.

---

## 7. Push / Pull Workflow Reference

```bash
docker login registry.example.com -u admin -p <CHANGE_ME>
docker pull alpine:latest
docker tag alpine:latest registry.example.com/library/my-test-image:v1
docker push registry.example.com/library/my-test-image:v1
docker rmi registry.example.com/library/my-test-image:v1
docker pull registry.example.com/library/my-test-image:v1
```

`library` is Harbor's default public project; create additional projects from the web UI (**Projects → New Project**) to organize images by team or application.

---

## Security Reminders

- Change `harbor_admin_password` immediately after first login.
- Self-signed certificates and `insecure-registries` are appropriate for internal/lab networks only — use a certificate from a trusted internal or public CA for anything exposed beyond a trusted LAN.
- Rotate the certificate before its 365-day expiry.
- Never commit real IPs, hostnames, or passwords to a public repo — this guide uses placeholder values for that reason.

---

**Next:** [Troubleshooting Guide →](troubleshooting.md)
