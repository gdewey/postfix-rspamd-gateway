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
DEFAULT_SPF="n"
DEFAULT_RCPT_VERIFY="n"
DEFAULT_SRS="n"
DEFAULT_LETSENCRYPT="n"
DEFAULT_LE_EMAIL=""

if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    DEFAULT_DQS_KEY="${DQS_KEY:-}"
    DEFAULT_HOSTNAME="${HOSTNAME_GW:-}"
    DEFAULT_HBL="${HBL_ENABLED:-n}"
    DEFAULT_SPF="${SPF_ENABLED:-n}"
    DEFAULT_RCPT_VERIFY="${RCPT_VERIFY_ENABLED:-n}"
    DEFAULT_SRS="${SRS_ENABLED:-n}"
    DEFAULT_LETSENCRYPT="${LETSENCRYPT_ENABLED:-n}"
    DEFAULT_LE_EMAIL="${LETSENCRYPT_EMAIL:-}"
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

read -rp "  Enable SPF check? Reject mail that fails SPF (${DEFAULT_SPF}): " SPF_INPUT
SPF_INPUT="${SPF_INPUT:-$DEFAULT_SPF}"
SPF_ENABLED="n"
[[ "${SPF_INPUT,,}" == "y" || "${SPF_INPUT,,}" == "yes" ]] && SPF_ENABLED="y"

read -rp "  Enable recipient verification? Verify users exist on destination server (${DEFAULT_RCPT_VERIFY}): " RCPT_VERIFY_INPUT
RCPT_VERIFY_INPUT="${RCPT_VERIFY_INPUT:-$DEFAULT_RCPT_VERIFY}"
RCPT_VERIFY_ENABLED="n"
[[ "${RCPT_VERIFY_INPUT,,}" == "y" || "${RCPT_VERIFY_INPUT,,}" == "yes" ]] && RCPT_VERIFY_ENABLED="y"

read -rp "  Enable SRS? Rewrite envelope sender for SPF compliance at destination (${DEFAULT_SRS}): " SRS_INPUT
SRS_INPUT="${SRS_INPUT:-$DEFAULT_SRS}"
SRS_ENABLED="n"
[[ "${SRS_INPUT,,}" == "y" || "${SRS_INPUT,,}" == "yes" ]] && SRS_ENABLED="y"

read -rp "  Enable TLS with Let's Encrypt certificate? (${DEFAULT_LETSENCRYPT}): " LE_INPUT
LE_INPUT="${LE_INPUT:-$DEFAULT_LETSENCRYPT}"
LETSENCRYPT_ENABLED="n"
LETSENCRYPT_EMAIL=""
if [[ "${LE_INPUT,,}" == "y" || "${LE_INPUT,,}" == "yes" ]]; then
    LETSENCRYPT_ENABLED="y"
    echo ""
    echo -e "  ${YELLOW}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${YELLOW}NOTE:${NC} Let's Encrypt requires ${BOLD}port 80${NC} to be open and"
    echo -e "  reachable from the internet for the HTTP-01 challenge."
    echo -e "  Make sure your firewall allows inbound TCP port 80."
    echo -e "  ${YELLOW}────────────────────────────────────────────────────────────${NC}"
    echo ""
    if [[ -n "$DEFAULT_LE_EMAIL" ]]; then
        read -rp "  Email for Let's Encrypt notifications (${DEFAULT_LE_EMAIL}): " LETSENCRYPT_EMAIL
        LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$DEFAULT_LE_EMAIL}"
    else
        read -rp "  Email for Let's Encrypt notifications: " LETSENCRYPT_EMAIL
    fi
    if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
        log_error "Email cannot be empty when using Let's Encrypt."
        exit 1
    fi
fi

echo ""
echo -e "  DQS key:    ${CYAN}${DQS_KEY:0:6}...${DQS_KEY: -4}${NC}"
echo -e "  Hostname:   ${CYAN}${HOSTNAME_GW}${NC}"
echo -e "  HBL:        ${CYAN}${HBL_ENABLED}${NC}"
echo -e "  SPF check:  ${CYAN}${SPF_ENABLED}${NC}"
echo -e "  Rcpt verify:${CYAN} ${RCPT_VERIFY_ENABLED}${NC}"
echo -e "  SRS:        ${CYAN}${SRS_ENABLED}${NC}"
if [[ "$LETSENCRYPT_ENABLED" == "y" ]]; then
    echo -e "  TLS:        ${CYAN}Let's Encrypt${NC}"
    echo -e "  LE email:   ${CYAN}${LETSENCRYPT_EMAIL}${NC}"
else
    echo -e "  TLS:        ${CYAN}Self-signed (snakeoil)${NC}"
fi
echo ""
read -rp "  Proceed with installation? (y/n): " confirm
[[ "${confirm,,}" != "y" ]] && { echo "Aborted."; exit 0; }

# Save configuration for future runs
cat > "$ENV_FILE" <<ENVEOF
# Spamhaus DQS key (alphanumeric, min 10 chars)
DQS_KEY="${DQS_KEY}"

# Gateway fully qualified domain name
HOSTNAME_GW="${HOSTNAME_GW}"

# Hash Blocklist support (requires HBL-enabled DQS key)
HBL_ENABLED="${HBL_ENABLED}"

# Reject mail that fails SPF at SMTP level (y/n)
# If disabled, SPF is still evaluated by SpamAssassin scoring.
SPF_ENABLED="${SPF_ENABLED}"

# Recipient verification: probe destination server to check if
# the recipient exists before accepting mail (y/n)
# Prevents backscatter for non-existent users.
# Only enable if destination servers reject unknown recipients (550).
# If destination is catch-all (accepts everything), leave disabled.
RCPT_VERIFY_ENABLED="${RCPT_VERIFY_ENABLED}"

# SRS (Sender Rewriting Scheme) via postsrsd (y/n)
# Rewrites envelope sender so relayed mail passes SPF at destination.
# Requires an SPF record for the gateway hostname (v=spf1 a -all).
SRS_ENABLED="${SRS_ENABLED}"

# TLS certificate via Let's Encrypt (y/n)
# Requires port 80 open. Falls back to self-signed if disabled.
LETSENCRYPT_ENABLED="${LETSENCRYPT_ENABLED}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"
ENVEOF
chmod 600 "$ENV_FILE"
log_info "Configuration saved to .env"

TOTAL_STEPS=7
[[ "$SRS_ENABLED" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$LETSENCRYPT_ENABLED" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP=0

# ---------------------------------------------------------------------------
# Stop existing services before installing (avoids dpkg conflicts)
# ---------------------------------------------------------------------------
RUNNING_SERVICES=""
for svc in mail-logger postsrsd spamass-milter spamd spamassassin postfix; do
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
        log_info "Services stopped."
    else
        log_error "Cannot install while services are running. Aborted."
        exit 1
    fi
fi

# Force-kill any orphan spamass-milter processes and clean up stale files
if pgrep -x spamass-milter >/dev/null 2>&1; then
    kill -9 $(pgrep -x spamass-milter) 2>/dev/null || true
    sleep 1
    log_info "Killed orphan spamass-milter process."
fi
rm -f /var/run/spamass/spamass.pid 2>/dev/null || true
rm -f /var/spool/postfix/spamass/spamass.sock 2>/dev/null || true

# Fix any broken dpkg state from a previous failed run
dpkg --configure -a 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 2: Install packages
# ---------------------------------------------------------------------------
STEP=$((STEP + 1))
log_step $STEP "Installing packages..."

export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "postfix postfix/mailname string ${HOSTNAME_GW}"
debconf-set-selections <<< "postfix postfix/main_mailer_type string Internet Site"

apt-get update -qq || { log_error "apt-get update failed"; exit 1; }
PACKAGES=(postfix spamassassin spamc spamass-milter libmail-spf-perl libmail-dkim-perl git ssl-cert)
if [[ "$SPF_ENABLED" == "y" ]]; then
    PACKAGES+=(postfix-policyd-spf-python)
fi
if [[ "$SRS_ENABLED" == "y" ]]; then
    PACKAGES+=(postsrsd)
fi
if [[ "$LETSENCRYPT_ENABLED" == "y" ]]; then
    PACKAGES+=(certbot)
fi
apt-get install -y "${PACKAGES[@]}" \
    || { log_error "apt-get install failed"; exit 1; }

log_info "Packages installed."

# ---------------------------------------------------------------------------
# Request Let's Encrypt TLS certificate (only when enabled)
# ---------------------------------------------------------------------------
USE_LETSENCRYPT_CERT="n"
if [[ "$LETSENCRYPT_ENABLED" == "y" ]]; then
    STEP=$((STEP + 1))
    log_step $STEP "Requesting TLS certificate (Let's Encrypt)..."

    LE_CERT="/etc/letsencrypt/live/${HOSTNAME_GW}/fullchain.pem"
    LE_KEY="/etc/letsencrypt/live/${HOSTNAME_GW}/privkey.pem"

    if [[ -f "$LE_CERT" && -f "$LE_KEY" ]] && openssl x509 -checkend 86400 -noout -in "$LE_CERT" 2>/dev/null; then
        CERT_EXPIRY=$(openssl x509 -enddate -noout -in "$LE_CERT" 2>/dev/null | cut -d= -f2)
        log_info "Valid certificate found (expires: ${CERT_EXPIRY})"
        log_info "Skipping request. To force renewal: certbot renew --force-renewal"
        USE_LETSENCRYPT_CERT="y"
    else
        # Check that port 80 is not already in use by another service
        if ss -tlnp 2>/dev/null | grep -q ':80 '; then
            PORT80_PROC=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1)
            log_error "Port 80 is already in use:"
            log_error "  ${PORT80_PROC}"
            log_warn "Stop the service using port 80 and re-run the installer."
            log_warn "Falling back to self-signed certificate."
        else
            echo ""
            log_info "Requesting certificate for ${HOSTNAME_GW}..."
            echo ""
            if certbot certonly --standalone \
                -d "${HOSTNAME_GW}" \
                --non-interactive \
                --agree-tos \
                -m "${LETSENCRYPT_EMAIL}"; then
                echo ""
                log_info "Certificate obtained successfully."
                USE_LETSENCRYPT_CERT="y"
            else
                echo ""
                log_error "Certbot failed to obtain a certificate."
                log_warn "Possible causes:"
                log_warn "  - Port 80 is not reachable from the internet"
                log_warn "  - DNS for ${HOSTNAME_GW} does not point to this server"
                log_warn "  - Rate limit reached (too many requests)"
                log_warn "Falling back to self-signed certificate."
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Configure Postfix
# ---------------------------------------------------------------------------
STEP=$((STEP + 1))
log_step $STEP "Configuring Postfix..."

cp "${SCRIPT_DIR}/configs/postfix/main.cf"          /etc/postfix/main.cf
cp "${SCRIPT_DIR}/configs/postfix/master.cf"         /etc/postfix/master.cf
cp "${SCRIPT_DIR}/configs/postfix/dnsbl-reply-map"   /etc/postfix/dnsbl-reply-map
cp "${SCRIPT_DIR}/configs/postfix/dnsbl_reply"       /etc/postfix/dnsbl_reply
cp "${SCRIPT_DIR}/configs/postfix/header_checks"     /etc/postfix/header_checks

sed -i "s/__DQS_KEY__/${DQS_KEY}/g"    /etc/postfix/main.cf
sed -i "s/__HOSTNAME__/${HOSTNAME_GW}/g" /etc/postfix/main.cf
sed -i "s/__DQS_KEY__/${DQS_KEY}/g"    /etc/postfix/dnsbl-reply-map
sed -i "s/__DQS_KEY__/${DQS_KEY}/g"    /etc/postfix/dnsbl_reply

if [[ "$USE_LETSENCRYPT_CERT" == "y" ]]; then
    sed -i "s|__TLS_CERT__|/etc/letsencrypt/live/${HOSTNAME_GW}/fullchain.pem|" /etc/postfix/main.cf
    sed -i "s|__TLS_KEY__|/etc/letsencrypt/live/${HOSTNAME_GW}/privkey.pem|"    /etc/postfix/main.cf
    log_info "TLS: Let's Encrypt certificate"
else
    sed -i "s|__TLS_CERT__|/etc/ssl/certs/ssl-cert-snakeoil.pem|"   /etc/postfix/main.cf
    sed -i "s|__TLS_KEY__|/etc/ssl/private/ssl-cert-snakeoil.key|"   /etc/postfix/main.cf
    log_info "TLS: self-signed certificate (snakeoil)"
fi

if [[ "$SPF_ENABLED" == "y" ]]; then
    sed -i 's/__SPF_CHECK__/check_policy_service unix:private\/policyd-spf,/' /etc/postfix/main.cf
    sed -i 's/__SPF_TIMEOUT__/policyd-spf_time_limit = 3600/' /etc/postfix/main.cf

    if ! grep -q "policyd-spf" /etc/postfix/master.cf; then
        cat >> /etc/postfix/master.cf <<'SPFEOF'

# --- SPF policy check ---
policyd-spf  unix  -       n       n       -       0       spawn
        user=policyd-spf argv=/usr/bin/policyd-spf
SPFEOF
    fi
    log_info "SPF check: ENABLED (reject on fail)"
else
    sed -i '/__SPF_CHECK__/d' /etc/postfix/main.cf
    sed -i '/__SPF_TIMEOUT__/d' /etc/postfix/main.cf
    log_info "SPF check: disabled (handled by SpamAssassin scoring only)"
fi

if [[ "$RCPT_VERIFY_ENABLED" == "y" ]]; then
    sed -i 's/__RCPT_VERIFY__/reject_unverified_recipient,/' /etc/postfix/main.cf
    sed -i '/__RCPT_VERIFY_CONFIG__/{
        r /dev/stdin
        d
    }' /etc/postfix/main.cf <<'RCPTEOF'
address_verify_map = btree:/var/lib/postfix/verify
unverified_recipient_reject_code = 550
address_verify_positive_expire_time = 7d
address_verify_negative_expire_time = 3d
address_verify_negative_refresh_time = 3h
RCPTEOF
    log_info "Recipient verification: ENABLED (probe destination server)"
else
    sed -i '/__RCPT_VERIFY__/d' /etc/postfix/main.cf
    sed -i '/__RCPT_VERIFY_CONFIG__/d' /etc/postfix/main.cf
    log_info "Recipient verification: disabled"
fi

if [[ "$SRS_ENABLED" == "y" ]]; then
    sed -i '/__SRS_CONFIG__/{
        r /dev/stdin
        d
    }' /etc/postfix/main.cf <<'SRSEOF'
sender_canonical_maps = tcp:localhost:10001
sender_canonical_classes = envelope_sender
recipient_canonical_maps = tcp:localhost:10002
recipient_canonical_classes = envelope_recipient,bounce_recipient
SRSEOF
    sed -i 's/__SRS_RELAY_HOSTNAME__/$myhostname/' /etc/postfix/main.cf

    cat > /etc/default/postsrsd <<POSTSRSDEOF
SRS_DOMAIN=${HOSTNAME_GW}
SRS_EXCLUDE_DOMAINS=${HOSTNAME_GW}
SRS_SECRET=/etc/postsrsd.secret
SRS_SEPARATOR==
SRS_FORWARD_PORT=10001
SRS_REVERSE_PORT=10002
POSTSRSDEOF
    log_info "SRS: ENABLED (postsrsd rewriting envelope senders)"
else
    sed -i '/__SRS_CONFIG__/d' /etc/postfix/main.cf
    sed -i 's/ __SRS_RELAY_HOSTNAME__//' /etc/postfix/main.cf
    log_info "SRS: disabled"
fi

postmap hash:/etc/postfix/dnsbl-reply-map

if [[ "$USE_LETSENCRYPT_CERT" == "y" ]]; then
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/postfix-reload.sh <<'HOOKEOF'
#!/bin/bash
systemctl reload postfix
HOOKEOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/postfix-reload.sh
    log_info "Auto-renewal hook installed (postfix reload on cert renewal)"
fi

log_info "Postfix configuration deployed."

# ---------------------------------------------------------------------------
# Step 4: Configure SpamAssassin + Spamhaus DQS plugin
# ---------------------------------------------------------------------------
STEP=$((STEP + 1))
log_step $STEP "Configuring SpamAssassin + Spamhaus DQS..."

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
STEP=$((STEP + 1))
log_step $STEP "Generating transport maps from domains.conf..."

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
STEP=$((STEP + 1))
log_step $STEP "Deploying mail-logger (per-domain CSV logs)..."

mkdir -p /opt/mail-gateway/scripts
cp "${SCRIPT_DIR}/scripts/mail-logger.py" /opt/mail-gateway/scripts/mail-logger.py
chmod +x /opt/mail-gateway/scripts/mail-logger.py
cp "${SCRIPT_DIR}/scripts/mail-logger.service" /etc/systemd/system/mail-logger.service

mkdir -p /var/log/spamhaus
mkdir -p /var/lib/mail-gateway

log_info "Mail logger installed at /opt/mail-gateway/scripts/mail-logger.py"
log_info "Per-domain logs at /var/log/spamhaus/<domain>/activity.log"

STEP=$((STEP + 1))
log_step $STEP "Configuring spamass-milter..."

mkdir -p /var/spool/postfix/spamass
chown spamass-milter:postfix /var/spool/postfix/spamass
chmod 710 /var/spool/postfix/spamass

cat > /etc/default/spamass-milter <<'EOF'
OPTIONS="-u spamass-milter -p /var/spool/postfix/spamass/spamass.sock -m -r 15"
EOF

log_info "Milter socket: /var/spool/postfix/spamass/spamass.sock"

STEP=$((STEP + 1))
log_step $STEP "Starting services..."

sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/spamassassin 2>/dev/null || true
systemctl daemon-reload

# Ubuntu 24.04 uses "spamd" service name, older versions use "spamassassin"
if systemctl list-unit-files spamd.service >/dev/null 2>&1; then
    SA_SERVICE="spamd"
else
    SA_SERVICE="spamassassin"
fi

SVC_LIST="$SA_SERVICE spamass-milter postfix mail-logger"
[[ "$SRS_ENABLED" == "y" ]] && SVC_LIST="postsrsd ${SVC_LIST}"

START_ERRORS=0
for svc in $SVC_LIST; do
    systemctl enable "$svc" --quiet 2>/dev/null || true
    if systemctl restart "$svc" 2>/dev/null; then
        log_info "${svc} started."
    else
        log_warn "${svc} failed to start. Check: journalctl -u ${svc} --no-pager -n 20"
        START_ERRORS=$((START_ERRORS + 1))
    fi
done

if [[ $START_ERRORS -eq 0 ]]; then
    log_info "All services started."
else
    log_warn "${START_ERRORS} service(s) failed to start. Review warnings above."
fi

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

VERIFY_SVC_LIST="postfix $SA_SERVICE spamass-milter mail-logger"
[[ "$SRS_ENABLED" == "y" ]] && VERIFY_SVC_LIST="${VERIFY_SVC_LIST} postsrsd"

for svc in $VERIFY_SVC_LIST; do
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

if [[ "$USE_LETSENCRYPT_CERT" == "y" ]]; then
    if [[ -f "/etc/letsencrypt/live/${HOSTNAME_GW}/fullchain.pem" ]]; then
        CERT_EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${HOSTNAME_GW}/fullchain.pem" 2>/dev/null | cut -d= -f2)
        echo -e "  ${GREEN}OK${NC}  TLS certificate (Let's Encrypt, expires: ${CERT_EXPIRY})"
    else
        echo -e "  ${RED}FAIL${NC}  TLS certificate not found at /etc/letsencrypt/live/${HOSTNAME_GW}/"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo -e "  ${GREEN}OK${NC}  TLS certificate (self-signed snakeoil)"
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
echo -e "  SPF check:         ${CYAN}${SPF_ENABLED}${NC}"
echo -e "  Rcpt verify:       ${CYAN}${RCPT_VERIFY_ENABLED}${NC}"
echo -e "  SRS:               ${CYAN}${SRS_ENABLED}${NC}"
if [[ "$USE_LETSENCRYPT_CERT" == "y" ]]; then
    echo -e "  TLS certificate:   ${CYAN}Let's Encrypt (/etc/letsencrypt/live/${HOSTNAME_GW}/)${NC}"
else
    echo -e "  TLS certificate:   ${CYAN}Self-signed (snakeoil)${NC}"
fi
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
if [[ "$USE_LETSENCRYPT_CERT" == "y" ]]; then
    echo "  Renew TLS cert:      certbot renew"
    echo "  Cert status:         certbot certificates"
fi
if [[ "$SRS_ENABLED" == "y" ]]; then
    echo ""
    echo -e "${BOLD}SRS DNS requirement:${NC}"
    echo "  Ensure the gateway hostname has an SPF record:"
    echo "    ${HOSTNAME_GW}.  IN TXT  \"v=spf1 a -all\""
    echo "  Without this, destination servers cannot validate SPF for"
    echo "  SRS-rewritten addresses and the rewriting provides no benefit."
fi
echo ""
