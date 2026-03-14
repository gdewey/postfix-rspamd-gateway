#!/bin/bash
###############################################################################
# install.sh - Postfix + SpamAssassin Mail Gateway with Spamhaus DQS
#
# Installs and configures:
#   - Postfix (mail relay/gateway with postscreen + Spamhaus DNSBL)
#   - SpamAssassin (content filtering with Spamhaus DQS plugin + HBL)
#   - spamass-milter (connects Postfix to SpamAssassin)
#
# Reads domains.conf for domain-to-relay SMTP mappings.
# Designed for Ubuntu 24.04 LTS.
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_step()  { echo -e "\n${GREEN}${BOLD}[$1/$TOTAL_STEPS]${NC} ${GREEN}$2${NC}"; }
log_info()  { echo -e "  ${CYAN}->  ${NC}$1"; }
log_warn()  { echo -e "  ${YELLOW}WARNING:${NC} $1"; }
log_error() { echo -e "  ${RED}ERROR:${NC} $1"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root (sudo ./install.sh)${NC}"
    exit 1
fi

if ! grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
    echo -e "${YELLOW}This script is designed for Ubuntu 24.04 LTS.${NC}"
    read -rp "Continue anyway? (y/n): " cont
    [[ "${cont,,}" != "y" ]] && exit 1
fi

TOTAL_STEPS=7

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} Postfix + SpamAssassin Mail Gateway${NC}"
echo -e "${BOLD} with Spamhaus DQS${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Interactive questions (load defaults from .env if exists)
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"

DEFAULT_DQS_KEY=""
DEFAULT_HOSTNAME=""
DEFAULT_HBL="n"

if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    DEFAULT_DQS_KEY="${DQS_KEY:-}"
    DEFAULT_HOSTNAME="${HOSTNAME_GW:-}"
    DEFAULT_HBL="${HBL_ENABLED:-n}"
    log_info "Previous configuration loaded from .env"
    echo ""
fi

echo -e "${BOLD}--- Configuration ---${NC}"
echo -e "  ${CYAN}Press Enter to keep default shown in ()${NC}"
echo ""

if [[ -n "$DEFAULT_DQS_KEY" ]]; then
    read -rp "  Spamhaus DQS key (${DEFAULT_DQS_KEY:0:6}...${DEFAULT_DQS_KEY: -4}): " DQS_KEY
    DQS_KEY="${DQS_KEY:-$DEFAULT_DQS_KEY}"
else
    read -rp "  Spamhaus DQS key: " DQS_KEY
fi
if [[ -z "$DQS_KEY" ]]; then
    log_error "DQS key cannot be empty."
    exit 1
fi
if ! [[ "$DQS_KEY" =~ ^[a-zA-Z0-9]+$ ]] || [[ ${#DQS_KEY} -lt 10 ]]; then
    log_error "DQS key must be alphanumeric and at least 10 characters."
    exit 1
fi

if [[ -n "$DEFAULT_HOSTNAME" ]]; then
    read -rp "  Gateway hostname FQDN (${DEFAULT_HOSTNAME}): " HOSTNAME_GW
    HOSTNAME_GW="${HOSTNAME_GW:-$DEFAULT_HOSTNAME}"
else
    read -rp "  Gateway hostname (FQDN, e.g. gateway.example.com): " HOSTNAME_GW
fi
if [[ -z "$HOSTNAME_GW" ]]; then
    log_error "Hostname cannot be empty."
    exit 1
fi

read -rp "  Is your DQS key HBL enabled? (${DEFAULT_HBL}): " HBL_INPUT
HBL_INPUT="${HBL_INPUT:-$DEFAULT_HBL}"
HBL_ENABLED="n"
[[ "${HBL_INPUT,,}" == "y" || "${HBL_INPUT,,}" == "yes" ]] && HBL_ENABLED="y"

echo ""
echo -e "  DQS key:    ${CYAN}${DQS_KEY:0:6}...${DQS_KEY: -4}${NC}"
echo -e "  Hostname:   ${CYAN}${HOSTNAME_GW}${NC}"
echo -e "  HBL:        ${CYAN}${HBL_ENABLED}${NC}"
echo ""
read -rp "  Proceed with installation? (y/n): " confirm
[[ "${confirm,,}" != "y" ]] && { echo "Aborted."; exit 0; }

# Save configuration for future runs
cat > "$ENV_FILE" <<ENVEOF
DQS_KEY="${DQS_KEY}"
HOSTNAME_GW="${HOSTNAME_GW}"
HBL_ENABLED="${HBL_ENABLED}"
ENVEOF
chmod 600 "$ENV_FILE"
log_info "Configuration saved to .env"

# ---------------------------------------------------------------------------
# Stop existing services before installing (avoids dpkg conflicts)
# ---------------------------------------------------------------------------
RUNNING_SERVICES=""
for svc in mail-logger spamass-milter spamassassin postfix; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        RUNNING_SERVICES="${RUNNING_SERVICES} ${svc}"
    fi
done

if [[ -n "$RUNNING_SERVICES" ]]; then
    echo ""
    echo -e "  ${YELLOW}Active services detected:${NC}${RUNNING_SERVICES}"
    read -rp "  Stop them to proceed with installation? (y/n): " stop_svcs
    if [[ "${stop_svcs,,}" == "y" ]]; then
        for svc in $RUNNING_SERVICES; do
            systemctl stop "$svc" 2>/dev/null || true
        done
        # Kill any orphan spamass-milter processes
        pkill -x spamass-milter 2>/dev/null || true
        sleep 1
        log_info "Services stopped."
    else
        log_error "Cannot install while services are running. Aborted."
        exit 1
    fi
else
    # Kill orphan processes even if systemd doesn't know about them
    pkill -x spamass-milter 2>/dev/null || true
fi

# Fix any broken dpkg state from a previous failed run
dpkg --configure -a 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 2: Install packages
# ---------------------------------------------------------------------------
log_step 1 "Installing packages..."

export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "postfix postfix/mailname string ${HOSTNAME_GW}"
debconf-set-selections <<< "postfix postfix/main_mailer_type string Internet Site"

apt-get update -qq || { log_error "apt-get update failed"; exit 1; }
apt-get install -y \
    postfix \
    spamassassin \
    spamc \
    spamass-milter \
    libmail-spf-perl \
    libmail-dkim-perl \
    git \
    ssl-cert \
    || { log_error "apt-get install failed"; exit 1; }

log_info "Packages installed."

# ---------------------------------------------------------------------------
# Step 3: Configure Postfix
# ---------------------------------------------------------------------------
log_step 2 "Configuring Postfix..."

cp "${SCRIPT_DIR}/configs/postfix/main.cf"          /etc/postfix/main.cf
cp "${SCRIPT_DIR}/configs/postfix/master.cf"         /etc/postfix/master.cf
cp "${SCRIPT_DIR}/configs/postfix/dnsbl-reply-map"   /etc/postfix/dnsbl-reply-map
cp "${SCRIPT_DIR}/configs/postfix/dnsbl_reply"       /etc/postfix/dnsbl_reply
cp "${SCRIPT_DIR}/configs/postfix/header_checks"     /etc/postfix/header_checks

sed -i "s/__DQS_KEY__/${DQS_KEY}/g"    /etc/postfix/main.cf
sed -i "s/__HOSTNAME__/${HOSTNAME_GW}/g" /etc/postfix/main.cf
sed -i "s/__DQS_KEY__/${DQS_KEY}/g"    /etc/postfix/dnsbl-reply-map
sed -i "s/__DQS_KEY__/${DQS_KEY}/g"    /etc/postfix/dnsbl_reply

postmap hash:/etc/postfix/dnsbl-reply-map

log_info "Postfix configuration deployed."

# ---------------------------------------------------------------------------
# Step 4: Configure SpamAssassin + Spamhaus DQS plugin
# ---------------------------------------------------------------------------
log_step 3 "Configuring SpamAssassin + Spamhaus DQS..."

cp "${SCRIPT_DIR}/configs/spamassassin/local.cf" /etc/spamassassin/local.cf

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

git clone --quiet https://github.com/spamhaus/spamassassin-dqs.git "${TEMP_DIR}/spamassassin-dqs"

SA_VERSION=$(spamassassin --version 2>/dev/null | grep -oP 'version \K[0-9]+\.[0-9]+' | head -1)
SA_MAJOR=$(echo "$SA_VERSION" | cut -d. -f1)

if [[ "$SA_MAJOR" -ge 4 ]]; then
    SA_DIR="4.0.0+"
else
    SA_DIR="3.4.1+"
fi
log_info "SpamAssassin ${SA_VERSION} detected -> using ${SA_DIR} plugin set."

PLUGIN_DIR="${TEMP_DIR}/spamassassin-dqs/${SA_DIR}"

sed -i "s/your_DQS_key/${DQS_KEY}/g" "${PLUGIN_DIR}/sh.cf"

cp "${PLUGIN_DIR}/sh.cf"        /etc/spamassassin/
cp "${PLUGIN_DIR}/sh_scores.cf" /etc/spamassassin/

if [[ "$HBL_ENABLED" == "y" ]]; then
    sed -i "s/your_DQS_key/${DQS_KEY}/g" "${PLUGIN_DIR}/sh_hbl.cf"
    cp "${PLUGIN_DIR}/sh_hbl.cf"        /etc/spamassassin/
    cp "${PLUGIN_DIR}/sh_hbl_scores.cf" /etc/spamassassin/

    SH_PM=""
    SH_PRE=""
    if [[ -f "${PLUGIN_DIR}/SH.pm" ]]; then
        SH_PM="${PLUGIN_DIR}/SH.pm"
        SH_PRE="${PLUGIN_DIR}/sh.pre"
    elif [[ -f "${TEMP_DIR}/spamassassin-dqs/3.4.1+/SH.pm" ]]; then
        SH_PM="${TEMP_DIR}/spamassassin-dqs/3.4.1+/SH.pm"
        SH_PRE="${TEMP_DIR}/spamassassin-dqs/3.4.1+/sh.pre"
    fi

    if [[ -n "$SH_PM" ]]; then
        cp "$SH_PM" /etc/spamassassin/
    fi
    if [[ -n "$SH_PRE" && -f "$SH_PRE" ]]; then
        sed -i "s|<config_directory>|/etc/spamassassin|g" "$SH_PRE"
        cp "$SH_PRE" /etc/spamassassin/
    fi

    log_info "HBL support: ENABLED"
else
    if [[ -f /etc/spamassassin/v342.pre ]]; then
        sed -i 's/^# *loadplugin Mail::SpamAssassin::Plugin::HashBL/loadplugin Mail::SpamAssassin::Plugin::HashBL/' \
            /etc/spamassassin/v342.pre
    fi
    log_info "HBL support: disabled (native HashBL plugin enabled)"
fi

mkdir -p /var/lib/spamassassin/.spamassassin
chown debian-spamd:debian-spamd /var/lib/spamassassin/.spamassassin 2>/dev/null || true

log_info "SpamAssassin configuration deployed."

# ---------------------------------------------------------------------------
# Step 5: Generate transport maps from domains.conf
# ---------------------------------------------------------------------------
log_step 4 "Generating transport maps from domains.conf..."

DOMAINS_CONF="${SCRIPT_DIR}/domains.conf"
TRANSPORT="/etc/postfix/transport"
RELAY_DOMAINS="/etc/postfix/relay_domains"

> "${TRANSPORT}"
> "${RELAY_DOMAINS}"

DOMAIN_COUNT=0

if [[ -f "${DOMAINS_CONF}" ]]; then
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
        DOMAIN_COUNT=$((DOMAIN_COUNT + 1))
    done < "${DOMAINS_CONF}"
fi

if [[ $DOMAIN_COUNT -gt 0 ]]; then
    postmap hash:"${TRANSPORT}"
    postmap hash:"${RELAY_DOMAINS}"
    log_info "${DOMAIN_COUNT} domain(s) configured for relay."
else
    touch "${TRANSPORT}" "${RELAY_DOMAINS}"
    postmap hash:"${TRANSPORT}"
    postmap hash:"${RELAY_DOMAINS}"
    log_warn "No domains found in domains.conf (all entries are commented out)."
    log_warn "Edit ${DOMAINS_CONF} and run: ${SCRIPT_DIR}/update-domains.sh"
fi

# ---------------------------------------------------------------------------
# Step 6: Configure milter and start services
# ---------------------------------------------------------------------------
log_step 5 "Deploying mail-logger (per-domain CSV logs)..."

mkdir -p /opt/mail-gateway/scripts
cp "${SCRIPT_DIR}/scripts/mail-logger.py" /opt/mail-gateway/scripts/mail-logger.py
chmod +x /opt/mail-gateway/scripts/mail-logger.py
cp "${SCRIPT_DIR}/scripts/mail-logger.service" /etc/systemd/system/mail-logger.service

mkdir -p /var/log/spamhaus
mkdir -p /var/lib/mail-gateway

log_info "Mail logger installed at /opt/mail-gateway/scripts/mail-logger.py"
log_info "Per-domain logs at /var/log/spamhaus/<domain>/activity.log"

log_step 6 "Configuring spamass-milter..."

mkdir -p /var/spool/postfix/spamass
chown spamass-milter:postfix /var/spool/postfix/spamass
chmod 710 /var/spool/postfix/spamass

cat > /etc/default/spamass-milter <<'EOF'
OPTIONS="-u spamass-milter -p /var/spool/postfix/spamass/spamass.sock -m -r 15"
EOF

log_info "Milter socket: /var/spool/postfix/spamass/spamass.sock"

log_step 7 "Starting services..."

sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/spamassassin 2>/dev/null || true

systemctl enable spamassassin  --quiet 2>/dev/null
systemctl restart spamassassin

systemctl enable spamass-milter --quiet 2>/dev/null
systemctl restart spamass-milter

systemctl enable postfix --quiet 2>/dev/null
systemctl restart postfix

systemctl daemon-reload
systemctl enable mail-logger --quiet 2>/dev/null
systemctl restart mail-logger

log_info "All services started."

# ---------------------------------------------------------------------------
# Ensure update-domains.sh is executable
# ---------------------------------------------------------------------------
chmod +x "${SCRIPT_DIR}/update-domains.sh"

# ---------------------------------------------------------------------------
# Verify: services, configs, directories
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} Verification${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

ERRORS=0

for svc in postfix spamassassin spamass-milter mail-logger; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "  ${GREEN}OK${NC}  ${svc} is running"
    else
        echo -e "  ${RED}FAIL${NC}  ${svc} is NOT running"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""

if postfix check 2>/dev/null; then
    echo -e "  ${GREEN}OK${NC}  postfix check passed"
else
    echo -e "  ${RED}FAIL${NC}  postfix check found errors"
    ERRORS=$((ERRORS + 1))
fi

SA_LINT=$(spamassassin --lint 2>&1)
if [[ -z "$SA_LINT" ]]; then
    echo -e "  ${GREEN}OK${NC}  spamassassin --lint passed"
else
    echo -e "  ${YELLOW}WARN${NC}  spamassassin --lint returned warnings"
    echo "        $SA_LINT" | head -3
fi

if ss -tlnp 2>/dev/null | grep -q ':25 '; then
    echo -e "  ${GREEN}OK${NC}  Port 25 is listening"
else
    echo -e "  ${RED}FAIL${NC}  Port 25 is NOT listening"
    ERRORS=$((ERRORS + 1))
fi

if [[ -S /var/spool/postfix/spamass/spamass.sock ]]; then
    echo -e "  ${GREEN}OK${NC}  Milter socket exists"
else
    echo -e "  ${YELLOW}WARN${NC}  Milter socket not found yet (may take a few seconds)"
fi

if [[ -d /var/log/spamhaus ]]; then
    echo -e "  ${GREEN}OK${NC}  Log directory /var/log/spamhaus/ exists"
else
    mkdir -p /var/log/spamhaus
    echo -e "  ${GREEN}OK${NC}  Log directory /var/log/spamhaus/ created"
fi

echo ""

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All checks passed!${NC}"
else
    echo -e "${RED}${BOLD}  ${ERRORS} check(s) failed. Review the output above.${NC}"
fi

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} Configuration Summary${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo -e "  Gateway hostname:  ${CYAN}${HOSTNAME_GW}${NC}"
echo -e "  DQS key:           ${CYAN}${DQS_KEY:0:6}...${DQS_KEY: -4}${NC}"
echo -e "  HBL enabled:       ${CYAN}${HBL_ENABLED}${NC}"
echo -e "  Relay domains:     ${CYAN}${DOMAIN_COUNT}${NC}"
echo -e "  Logs:              ${CYAN}/var/log/spamhaus/<domain>/activity.log${NC}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Edit ${SCRIPT_DIR}/domains.conf to add your relay domains"
echo "  2. Run:  sudo ${SCRIPT_DIR}/update-domains.sh"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  Verify SpamAssassin:  spamassassin --lint"
echo "  Check Postfix config: postfix check"
echo "  View mail logs:       journalctl -u postfix -f"
echo "  View SA logs:         journalctl -u spamassassin -f"
echo "  View logger status:   systemctl status mail-logger"
echo "  Browse domain logs:   ls /var/log/spamhaus/"
echo ""
