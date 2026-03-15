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
else
    echo -e "  ${YELLOW}No domains configured in domains.conf${NC}"
fi

echo ""
read -rp "  Sender email: " SENDER
if [[ -z "$SENDER" ]]; then
    echo -e "${RED}Sender cannot be empty.${NC}"
    exit 1
fi

read -rp "  Recipient email: " RECIPIENT
if [[ -z "$RECIPIENT" ]]; then
    echo -e "${RED}Recipient cannot be empty.${NC}"
    exit 1
fi

RCPT_DOMAIN="${RECIPIENT#*@}"

echo ""
echo -e "  Sending: ${CYAN}${SENDER}${NC} -> ${CYAN}${RECIPIENT}${NC}"
echo ""

SMTP_OUTPUT=$(python3 -c "
import smtplib
import sys
from email.mime.text import MIMEText
from datetime import datetime

sender = '${SENDER}'
recipient = '${RECIPIENT}'

msg = MIMEText('This is an automated test from test.sh at ' + str(datetime.now()))
msg['Subject'] = 'Gateway test ' + datetime.now().strftime('%H:%M:%S')
msg['From'] = sender
msg['To'] = recipient

try:
    with smtplib.SMTP('localhost', 25) as s:
        s.set_debuglevel(0)
        response = s.sendmail(sender, [recipient], msg.as_string())
        print('QUEUED')
except smtplib.SMTPRecipientsRefused as e:
    for addr, (code, msg_str) in e.recipients.items():
        print(f'REJECTED {code} {msg_str.decode()}')
except smtplib.SMTPSenderRefused as e:
    print(f'SENDER_REFUSED {e.smtp_code} {e.smtp_error.decode()}')
except smtplib.SMTPDataError as e:
    print(f'DATA_ERROR {e.smtp_code} {e.smtp_error.decode()}')
except Exception as e:
    print(f'ERROR {e}')
" 2>&1)

echo -e "${BOLD}--- Result ---${NC}"

if [[ "$SMTP_OUTPUT" == "QUEUED" ]]; then
    echo -e "  ${GREEN}ACCEPTED${NC} - Message queued for delivery"
    echo ""

    sleep 2

    echo -e "${BOLD}--- Postfix Log ---${NC}"
    grep "to=<${RECIPIENT}>" /var/log/mail.log 2>/dev/null | tail -3 || echo "  (no log entries yet)"
    echo ""

    LOG_FILE="/var/log/spamhaus/${RCPT_DOMAIN}/activity.log"
    echo -e "${BOLD}--- Domain Log ---${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -5 "$LOG_FILE"
    else
        echo "  (no activity.log yet for ${RCPT_DOMAIN})"
    fi

elif [[ "$SMTP_OUTPUT" == REJECTED* ]]; then
    REASON="${SMTP_OUTPUT#REJECTED }"
    echo -e "  ${RED}REJECTED${NC} - ${REASON}"

    if echo "$REASON" | grep -qi "relay access denied"; then
        echo -e "\n  Domain '${RCPT_DOMAIN}' is not in domains.conf"
    elif echo "$REASON" | grep -qi "blocked using"; then
        echo -e "\n  Sender blocked by Spamhaus DNSBL"
    fi

elif [[ "$SMTP_OUTPUT" == SENDER_REFUSED* ]]; then
    REASON="${SMTP_OUTPUT#SENDER_REFUSED }"
    echo -e "  ${RED}SENDER REFUSED${NC} - ${REASON}"

elif [[ "$SMTP_OUTPUT" == DATA_ERROR* ]]; then
    REASON="${SMTP_OUTPUT#DATA_ERROR }"
    echo -e "  ${RED}DATA ERROR${NC} - ${REASON}"

elif [[ "$SMTP_OUTPUT" == ERROR* ]]; then
    REASON="${SMTP_OUTPUT#ERROR }"
    echo -e "  ${RED}ERROR${NC} - ${REASON}"

else
    echo -e "  ${YELLOW}UNKNOWN${NC} - ${SMTP_OUTPUT}"
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
