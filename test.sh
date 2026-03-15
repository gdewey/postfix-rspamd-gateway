#!/bin/bash
###############################################################################
# test.sh - Interactive mail gateway test
#
# Prompts for sender and recipient email addresses, then sends a test
# message via SMTP to localhost:25. Shows the SMTP response, Postfix
# logs for the queued message, per-domain activity log, and queue status.
#
# Useful for verifying the gateway works before pointing MX records.
#
# Usage: sudo ./test.sh
###############################################################################

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo $0${NC}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_CONF="${SCRIPT_DIR}/domains.conf"

CONFIGURED_DOMAINS=()
if [[ -f "$DOMAINS_CONF" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        d=$(echo "$line" | awk '{print $1}')
        [[ -n "$d" ]] && CONFIGURED_DOMAINS+=("$d")
    done < "$DOMAINS_CONF"
fi

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} Mail Gateway Test${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

if [[ ${#CONFIGURED_DOMAINS[@]} -gt 0 ]]; then
    echo -e "  Configured domains:"
    for d in "${CONFIGURED_DOMAINS[@]}"; do
        echo -e "    ${CYAN}${d}${NC}"
    done
    DEFAULT_RCPT="test@${CONFIGURED_DOMAINS[0]}"
else
    echo -e "  ${YELLOW}No domains configured in domains.conf${NC}"
    DEFAULT_RCPT=""
fi

echo ""
read -rp "  Sender email (test@gmail.com): " SENDER
SENDER="${SENDER:-test@gmail.com}"

if [[ -n "$DEFAULT_RCPT" ]]; then
    read -rp "  Recipient email (${DEFAULT_RCPT}): " RECIPIENT
    RECIPIENT="${RECIPIENT:-$DEFAULT_RCPT}"
else
    read -rp "  Recipient email: " RECIPIENT
fi

if [[ -z "$RECIPIENT" ]]; then
    echo -e "${RED}Recipient cannot be empty.${NC}"
    exit 1
fi

RCPT_DOMAIN="${RECIPIENT#*@}"

echo ""
echo -e "  Sending: ${CYAN}${SENDER}${NC} -> ${CYAN}${RECIPIENT}${NC}"
echo ""

SMTP_RESPONSE=$(cat <<SMTP_SESSION | nc -q 5 localhost 25 2>&1
EHLO test.local
MAIL FROM:<${SENDER}>
RCPT TO:<${RECIPIENT}>
DATA
From: ${SENDER}
To: ${RECIPIENT}
Subject: Gateway test $(date +%H:%M:%S)
Date: $(date -R)

This is an automated test from test.sh at $(date).
.
QUIT
SMTP_SESSION
)

echo -e "${BOLD}--- SMTP Response ---${NC}"
echo "$SMTP_RESPONSE"
echo ""

if echo "$SMTP_RESPONSE" | grep -q "queued"; then
    QUEUE_ID=$(echo "$SMTP_RESPONSE" | grep -oP 'queued as \K[A-F0-9]+')
    echo -e "  ${GREEN}ACCEPTED${NC} - Queued as ${QUEUE_ID}"
    echo ""

    sleep 2

    echo -e "${BOLD}--- Postfix Log ---${NC}"
    grep "${QUEUE_ID}" /var/log/mail.log 2>/dev/null || echo "  (no log entries yet)"
    echo ""

    LOG_FILE="/var/log/spamhaus/${RCPT_DOMAIN}/activity.log"
    echo -e "${BOLD}--- Domain Log ---${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -5 "$LOG_FILE"
    else
        echo "  (no activity.log yet for ${RCPT_DOMAIN})"
    fi

elif echo "$SMTP_RESPONSE" | grep -q "Relay access denied"; then
    echo -e "  ${RED}REJECTED${NC} - Relay access denied"
    echo "  Domain '${RCPT_DOMAIN}' is not in domains.conf"

elif echo "$SMTP_RESPONSE" | grep -q "blocked using"; then
    echo -e "  ${RED}BLOCKED${NC} - Spamhaus DNSBL rejection"
    echo "$SMTP_RESPONSE" | grep "blocked"

elif echo "$SMTP_RESPONSE" | grep -q "Service unavailable"; then
    echo -e "  ${RED}BLOCKED${NC} - Service unavailable (RBL/DNSBL)"

else
    echo -e "  ${YELLOW}UNKNOWN${NC} - Review SMTP response above"
fi

echo ""

echo -e "${BOLD}--- Queue Status ---${NC}"
QUEUE=$(postqueue -p 2>/dev/null)
if [[ "$QUEUE" == "Mail queue is empty" ]]; then
    echo "  Queue is empty (mail delivered or bounced)"
else
    echo "$QUEUE"
fi

echo ""
