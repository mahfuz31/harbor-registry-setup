#!/usr/bin/env bash
#
# health-check.sh
# Verifies basic network reachability and TLS health for a Harbor registry
# from a client machine, before attempting docker login/push/pull.
#
# Usage:
#   ./health-check.sh <hostname> <lan-ip>
#
# Example:
#   ./health-check.sh registry.example.com 192.168.1.50

set -uo pipefail

HOSTNAME="${1:?Usage: $0 <hostname> <lan-ip>}"
LAN_IP="${2:?Usage: $0 <hostname> <lan-ip>}"

echo "==> 1. Checking basic network reachability (ping ${LAN_IP})"
if ping -c 3 -W 2 "${LAN_IP}" > /dev/null 2>&1; then
  echo "    OK — host is reachable at the network layer."
else
  echo "    FAIL — ${LAN_IP} did not respond to ping."
  echo "    This is a routing/subnet issue, not a Harbor or Docker problem."
  echo "    Confirm both machines are on the same reachable network."
  exit 1
fi

echo "==> 2. Checking Harbor API health endpoint (https://${HOSTNAME}/api/v2.0/health)"
HTTP_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${HOSTNAME}/api/v2.0/health" || echo "000")

if [ "${HTTP_STATUS}" = "200" ]; then
  echo "    OK — Harbor is up and responding on port 443."
elif [ "${HTTP_STATUS}" = "000" ]; then
  echo "    FAIL — could not connect at all (timeout / connection refused)."
  echo "    Likely causes:"
  echo "      - Nothing listening on port 443 (check 'sudo docker-compose ps' on the server)"
  echo "      - Wrong hosts-file entry on this client (should point to the server's real LAN IP, not 127.0.0.1)"
  echo "      - Firewall blocking port 443 on the server"
  exit 1
else
  echo "    WARN — got HTTP ${HTTP_STATUS}. Server is reachable but may not be fully healthy."
fi

echo "==> 3. Checking hosts file resolution for ${HOSTNAME}"
RESOLVED_IP=$(getent hosts "${HOSTNAME}" | awk '{ print $1 }' | head -n1)
if [ "${RESOLVED_IP}" = "${LAN_IP}" ]; then
  echo "    OK — ${HOSTNAME} resolves to ${LAN_IP} as expected."
elif [ "${RESOLVED_IP}" = "127.0.0.1" ]; then
  echo "    FAIL — ${HOSTNAME} resolves to 127.0.0.1 on this machine."
  echo "    That entry is only correct on the Harbor server itself."
  echo "    Fix /etc/hosts on this client to point to ${LAN_IP} instead."
  exit 1
else
  echo "    WARN — ${HOSTNAME} resolves to ${RESOLVED_IP:-<nothing>}, expected ${LAN_IP}."
fi

echo ""
echo "All checks passed — safe to proceed with docker login/push/pull."
