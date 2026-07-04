# Troubleshooting Guide

Every error in this guide was hit for real while setting up Harbor on a LAN with multiple client machines. Each entry includes the exact symptom, root cause, and fix.

---

## TLS / Certificate Errors

### `x509: certificate signed by unknown authority` on `docker login` or `docker push`

**Cause:** The client hasn't imported the self-signed cert into Docker's registry-specific trust store.

**Fix:**
```bash
sudo mkdir -p /etc/docker/certs.d/registry.example.com
sudo cp /certs/registry.crt /etc/docker/certs.d/registry.example.com/ca.crt
sudo systemctl restart docker
```

---

### `failed to fetch oauth token: ... x509: certificate signed by unknown authority` — **even after** the fix above

**Cause:** This one is subtle. Docker's per-registry trust store (`/etc/docker/certs.d/`) covers image layer/blob transfers, but the **OAuth token exchange** (`POST https://<host>/service/token`) during login/push/pull is validated against the **operating system's CA trust store**, not Docker's. Configuring one without the other leaves this call failing.

**Fix:**
```bash
sudo cp /certs/registry.crt /usr/local/share/ca-certificates/registry.crt
sudo update-ca-certificates
sudo systemctl restart docker
```

**How to confirm it's fixed:** the error should disappear entirely (not just change wording) once both trust stores are updated.

**If it still fails after both fixes:** the client might be trusting a *stale* copy of the cert (e.g. if the server's cert was regenerated). Compare fingerprints:
```bash
# What the server is presenting right now
openssl s_client -connect registry.example.com:443 -servername registry.example.com </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256

# What this client currently trusts
openssl x509 -in /etc/docker/certs.d/registry.example.com/ca.crt -noout -fingerprint -sha256
```
Mismatched fingerprints → re-copy the current cert and repeat both trust steps.

---

## Networking / DNS Errors

### `dial tcp 127.0.0.1:443: connect: connection refused`

**Cause:** The client machine's `/etc/hosts` has the **server's** entry (`127.0.0.1 registry.example.com`) instead of the server's real LAN IP. On a client, `127.0.0.1` resolves to that client itself — nothing is listening on port 443 there.

**Fix:** On every client (not the server), set:
```
192.168.1.50 registry.example.com
```
Never copy the server's `127.0.0.1` hosts entry onto a client machine.

---

### `dial tcp <server-IP>:443: connect: connection refused` (hosts file is correct)

**Cause:** Nothing is listening on port 443 on the server at all — this is a server-side problem, not a client/DNS one. Usually means the Harbor stack (specifically the `nginx` proxy container) isn't running.

**Fix:** See [Stack Stability](#stack-stability) below. Also rule out a firewall:
```bash
sudo ufw status
```

---

### Verifying connectivity before debugging further

Before chasing Docker-specific errors, confirm the client can reach the server at all:
```bash
ping -c 3 192.168.1.50
curl -k https://registry.example.com/api/v2.0/health
```
- `ping` fails → subnet/routing issue, unrelated to Harbor.
- `curl` refuses/hangs → nothing listening on 443 server-side.
- `curl` succeeds → the network path is fine; focus on Docker/cert/auth.

---

## Docker Compose / Service Errors

### `sudo docker-compose logs db` → `no such service: db`

**Cause:** Naming mismatch between the *service* name and the *container* name in `docker-compose.yml`. The database service is named `postgresql`; the container it creates is named `harbor-db`.

**Fix:**
```bash
sudo docker-compose logs postgresql
```
Same applies to the proxy: the service/container is just `nginx`, not `harbor-proxy`.

---

### `invalid reference format` on `docker push` or `docker tag`

**Cause:** A typo in the image tag — usually a stray `:` or `-`, e.g. `image:-tag` or `image::tag`.

**Fix:** Check the tag string carefully; this is a client-side syntax issue, not a registry problem.

---

### `401` entries appearing in `nginx` / proxy logs during push or pull

**Not an error.** Docker's push/pull flow always issues an unauthenticated request first, receives a `401` with a `WWW-Authenticate` header, then retries with a bearer token. Seeing one `401` per blob/manifest on the first attempt is expected behavior, not a failure.

---

## Stack Stability

### The Harbor stack silently drops from 10 containers to 1 (`harbor-log` only)

This was the most surprising failure encountered — no crash message pointed at an obvious root cause, and it happened more than once mid-session.

**Symptom:**
```bash
sudo docker-compose ps
# only harbor-log shows as Up — everything else is gone
```

**Recovery — a full cycle is more reliable than `up -d` alone:**
```bash
sudo docker-compose down
sudo docker-compose up -d
sudo docker-compose ps   # confirm all 10 containers report Up
```
In practice, running `up -d` on its own did **not** reliably bring back a partially-collapsed stack — a full `down` first was necessary.

**Checks to find the actual root cause:**
```bash
free -h                  # rule out OOM
df -h                    # rule out disk full
dmesg | tail -30         # check for kernel-level OOM kills
sudo docker-compose logs harbor-core --tail=50
sudo docker-compose logs nginx --tail=50
sudo docker-compose logs postgresql --tail=50
```

**Prevention:** check `docker-compose.yml` for a `restart:` policy on each service. If missing, add `restart: always` (or `unless-stopped`) so the stack self-heals after a crash or host reboot instead of requiring a manual `down && up -d`.

See [postmortem-stack-down.md](postmortem-stack-down.md) for the full incident timeline.

---

## Quick Reference Table

| Symptom | Root Cause | Section |
|---|---|---|
| `x509: unknown authority` on login/push | Docker registry trust store not configured | [TLS Errors](#tls--certificate-errors) |
| Same error, persists after trust store fix | OS-wide CA store not configured | [TLS Errors](#tls--certificate-errors) |
| `connection refused` on `127.0.0.1:443` | Client has server's hosts entry instead of its own | [Networking Errors](#networking--dns-errors) |
| `connection refused` on real server IP | Harbor stack down / firewall | [Stack Stability](#stack-stability) |
| `no such service: db` | Wrong service name — use `postgresql` | [Compose Errors](#docker-compose--service-errors) |
| `invalid reference format` | Tag typo | [Compose Errors](#docker-compose--service-errors) |
| `401` in proxy logs | Normal OAuth handshake, not an error | [Compose Errors](#docker-compose--service-errors) |
| Stack drops to 1 container | Unclear — OOM/disk suspected | [Stack Stability](#stack-stability) |
