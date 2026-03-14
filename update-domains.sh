#!/bin/bash
###############################################################################
# update-domains.sh - Regenerate Postfix transport maps from domains.conf
#
# Run this after editing domains.conf to apply changes without reinstalling.
# Usage: sudo ./update-domains.sh
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_CONF="${SCRIPT_DIR}/domains.conf"
TRANSPORT="/etc/postfix/transport"
RELAY_DOMAINS="/etc/postfix/relay_domains"

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root -> sudo $0"
    exit 1
fi

if [[ ! -f "${DOMAINS_CONF}" ]]; then
    echo "Error: ${DOMAINS_CONF} not found."
    exit 1
fi

> "${TRANSPORT}"
> "${RELAY_DOMAINS}"
COUNT=0

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    domain=$(echo "$line" | awk '{print $1}')
    relay=$(echo "$line"  | awk '{print $2}')
    port=$(echo "$line"   | awk '{print $3}')
    [[ -z "$domain" || -z "$relay" ]] && continue
    port="${port:-25}"
    echo "${domain}    smtp:[${relay}]:${port}" >> "${TRANSPORT}"
    echo "${domain}    OK" >> "${RELAY_DOMAINS}"
    COUNT=$((COUNT + 1))
done < "${DOMAINS_CONF}"

postmap hash:"${TRANSPORT}"
postmap hash:"${RELAY_DOMAINS}"
postfix reload >/dev/null 2>&1

if [[ $COUNT -eq 0 ]]; then
    echo "Warning: no active domains found. All entries in domains.conf are commented out."
else
    echo "${COUNT} domain(s) configured. Postfix reloaded."
fi
