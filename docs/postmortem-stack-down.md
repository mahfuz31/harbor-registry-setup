# Postmortem: Harbor Stack Silently Dropped to a Single Container

**Date:** 2026-07-03
**Severity:** Medium — registry unavailable to all clients; no image data lost
**Status:** Resolved (workaround in place; root cause not fully confirmed)

---

## Summary

During routine push/pull testing from a client machine, `docker push` began failing with `connection refused` on port 443. Investigation on the Harbor server showed only one of the stack's ten containers (`harbor-log`) was still running — the rest had stopped or been removed with no corresponding alert or obvious crash trigger. A full `docker-compose down` followed by `docker-compose up -d` restored the complete stack and resolved the issue.

---

## Timeline

| Time | Event |
|---|---|
| T+0 | `docker push` from a client fails: `dial tcp <server-IP>:443: connect: connection refused` |
| T+2m | Confirmed client-side hosts file and cert trust were already correctly configured (ruled out client misconfiguration) |
| T+5m | Ran `sudo docker-compose ps` on the server — only `harbor-log` reported `Up`; all other containers (core, db, registry, nginx, portal, redis, jobservice, registryctl) were missing |
| T+7m | Checked `sudo ufw status` — firewall was inactive, ruling out a network-policy cause |
| T+8m | Ran `ping` from the client to the server — succeeded, confirming basic network reachability was fine |
| T+10m | Attempted `sudo docker-compose up -d` alone — did not fully restore the stack to a healthy state |
| T+12m | Ran `sudo docker-compose down` followed by `sudo docker-compose up -d` — all 10 containers came back `Up`/`Up (healthy)` |
| T+14m | Retried `docker push` — succeeded |

---

## Root Cause

**Not conclusively determined.** No single log line pointed to an explicit crash reason for the missing containers. The two leading hypotheses, in order of likelihood, going into the follow-up investigation:

1. **Resource exhaustion** (memory or disk) causing the container runtime or a dependent service (most likely `postgresql`, which several other containers depend on) to be killed, which cascaded to dependent containers.
2. **An uncaptured `docker-compose down` or `prepare`/`install.sh` re-run** earlier in the session may have partially torn down the stack without a corresponding full `up -d` afterward — user-driven rather than a runtime crash.

Because `dmesg`, `free -h`, and `df -h` weren't captured **before** the recovery action was taken, there isn't hard evidence to confirm either hypothesis after the fact. This is captured as a process gap below.

---

## Resolution

```bash
cd ~/harbor/harbor
sudo docker-compose down
sudo docker-compose up -d
sudo docker-compose ps   # confirmed all 10 containers Up/healthy
```

A plain `sudo docker-compose up -d` (without the preceding `down`) was tried first and did **not** fully recover the stack — this is worth noting since it's the more intuitive first thing to try.

---

## Impact

- Registry was unreachable for push/pull operations for the duration of the incident (~15 minutes, self-inflicted testing environment — no external users affected).
- No data loss: Postgres and registry storage volumes were untouched; all previously pushed images remained intact after recovery.

---

## Follow-Up Actions

- [ ] Add `restart: always` (or `unless-stopped`) to each service in `docker-compose.yml` so the stack self-heals after a crash or host reboot without manual intervention.
- [ ] Capture `free -h`, `df -h`, and `dmesg | tail -50` **immediately** upon noticing a stack failure, before taking any recovery action, to preserve evidence for root-causing.
- [ ] Set up basic container health monitoring/alerting (even a simple cron-based `docker-compose ps` check + notification) so a partial stack failure is caught proactively rather than discovered via a failed push.
- [ ] Review whether any manual `docker-compose down`/`prepare`/`install.sh` commands were run earlier in the session that could explain the partial teardown, to rule out hypothesis #2.
- [ ] If resource exhaustion is confirmed as the cause on a future occurrence, evaluate increasing the host's memory/disk allocation or tuning Harbor's component resource limits.

---

## Lessons Learned

- **`docker-compose ps` should be the first check**, not a later one, whenever registry operations start failing — it immediately distinguishes "the app is down" from "networking/auth is broken," which are otherwise easy to conflate from the client side.
- **Recovery commands should be run in the order that's actually reliable, not the order that's intuitive.** `up -d` alone felt like the natural first step but didn't work; `down` then `up -d` did.
- **Evidence-gathering commands are cheap and should run before remediation**, not after — this is the single biggest gap in how this incident was handled, and the reason root cause remains unconfirmed.
