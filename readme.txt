===============================================================================
  POSTFIX + SPAMASSASSIN MAIL GATEWAY - Spamhaus DQS
===============================================================================

Automated setup for a mail filtering gateway that receives incoming email,
filters it through multiple layers of spam protection (Spamhaus DQS DNSBL,
SpamAssassin content analysis, HBL hash-based blocklists, and dangerous
attachment blocking), then relays clean mail to destination SMTP servers
based on per-domain routing rules.

Optionally enables TLS encryption with a Let's Encrypt certificate
(via certbot) so the gateway uses trusted STARTTLS for server-to-server
communication, with automatic certificate renewal.

Designed for use as a front-line mail gateway that sits between the internet
and your internal mail servers, providing enterprise-grade spam filtering
with Spamhaus real-time data.

Author: Guillermo Dewey (https://ofik.com)



REQUIREMENTS
------------
- Ubuntu 24.04 LTS
- Root access
- Spamhaus DQS key (https://www.spamhaustech.com)
- Port 25 open on firewall
- Port 80 open on firewall (only if using Let's Encrypt TLS)

DNS requirements (configure BEFORE installing):
- A record:   gateway.yourdomain.com -> server IP
- PTR record: server IP -> gateway.yourdomain.com
  (PTR is configured in your VPS/hosting provider panel)
- Both must point to the same hostname (FCrDNS)


INSTALLATION
------------
1. Copy the entire directory to your server:

     scp -r postfix-rspamd/ root@server:/opt/mail-gateway/

2. Edit domains.conf with your domains and relay servers:

     vim /opt/mail-gateway/domains.conf

3. Run the installer:

     cd /opt/mail-gateway
     sudo ./install.sh

   The script will ask for:
     - Spamhaus DQS key
     - Gateway hostname (FQDN)
     - Whether the key has HBL enabled (y/n)
     - Whether to enable SPF checking (y/n)
       If enabled, mail that fails SPF is rejected at SMTP level.
       If disabled, SPF is still evaluated by SpamAssassin scoring.
     - Whether to enable recipient verification (y/n)
       If enabled, the gateway probes destination servers to verify
       recipients exist before accepting mail. Prevents backscatter.
       Only enable if destination servers reject unknown users.
     - Whether to enable TLS with Let's Encrypt (y/n)
       If enabled, certbot requests a certificate for the gateway
       hostname. Requires port 80 open. If disabled or if the
       request fails, a self-signed certificate is used instead.

   Answers are saved to .env for future runs. When re-running the
   installer, previous values appear as defaults and can be accepted
   by pressing Enter.


DESTINATION SERVER CONFIGURATION
--------------------------------
The destination SMTP servers (configured in domains.conf) should be set up
to work properly with this gateway:

1. Only accept mail from the gateway IP: configure your destination server
   to reject connections on port 25 from any IP other than the gateway.
   This ensures all incoming mail is filtered before delivery.

2. Disable SPF checking on the destination server: since the gateway
   relays mail on behalf of external senders, the destination server
   will see the gateway IP as the sender, not the original server.
   SPF checks on the destination will fail because the gateway IP is
   not in the sender's SPF record. The gateway already handles SPF
   validation (if enabled), so the destination server does not need it.

3. Point MX records to the gateway: the MX record for each domain in
   domains.conf should point to the gateway hostname, not the
   destination server. This routes all incoming mail through the
   gateway for filtering before delivery.


RE-INSTALL / UPDATE
-------------------
The installer is idempotent. It can be run multiple times safely:

     sudo ./install.sh

It detects active services and asks to stop them before proceeding.
Previous configuration is loaded from .env.


UPDATING DOMAINS (without reinstalling)
----------------------------------------
1. Edit domains.conf
2. Run:

     sudo ./update-domains.sh

This regenerates the Postfix transport maps and reloads the config.
No service restart required.


SERVICES
--------
The gateway runs 4 independent services (5 if Let's Encrypt is enabled):

  +-------------------+----------------------------------------------+
  | Service           | Purpose                                      |
  +-------------------+----------------------------------------------+
  | postfix           | MTA - receives and relays mail (TLS enabled) |
  | spamd             | SpamAssassin daemon - content filtering       |
  | spamass-milter    | Connects Postfix to SpamAssassin             |
  | mail-logger       | Real-time log parser, per-domain CSV output  |
  | certbot.timer *   | Auto-renews Let's Encrypt TLS certificate    |
  +-------------------+----------------------------------------------+

  * certbot.timer is only present when Let's Encrypt TLS is enabled.
    It runs "certbot renew" twice daily and reloads Postfix on renewal.

  Note: on Ubuntu 24.04 the SpamAssassin service is called "spamd".
  On older versions it may be called "spamassassin". The installer
  detects the correct name automatically.

Service commands:

  Start:
    sudo systemctl start postfix
    sudo systemctl start spamd
    sudo systemctl start spamass-milter
    sudo systemctl start mail-logger

  Stop:
    sudo systemctl stop mail-logger
    sudo systemctl stop spamass-milter
    sudo systemctl stop spamd
    sudo systemctl stop postfix

  Restart:
    sudo systemctl restart postfix
    sudo systemctl restart spamd
    sudo systemctl restart spamass-milter
    sudo systemctl restart mail-logger

  Check status:
    sudo systemctl status postfix
    sudo systemctl status spamd
    sudo systemctl status spamass-milter
    sudo systemctl status mail-logger
    sudo systemctl status certbot.timer    (if Let's Encrypt enabled)

  Quick status for all:
    for s in postfix spamd spamass-milter mail-logger; do
      printf "%-20s %s\n" "$s" "$(systemctl is-active $s)"
    done

  All services start automatically on server reboot.


LOGS
----
  System logs (Postfix/SA):
    journalctl -u postfix -f
    journalctl -u spamd -f

  Per-domain logs:
    ls /var/log/spamhaus/
    cat /var/log/spamhaus/example.com/activity.log

  Consolidated log (all domains in a single file):
    cat /var/log/spamhaus/general_activity.log

  CSV format (per-domain):
    timestamp,sender,recipient,status,reason

  CSV format (consolidated, adds domain column):
    timestamp,domain,sender,recipient,status,reason

  Statuses:
    relay  - Mail accepted and delivered to destination server
    block  - Rejected (DNSBL, SpamAssassin, dangerous attachment, etc.)
    spam   - Tagged as spam but still delivered (score between 5 and 15)
    defer  - Temporary delivery failure, will retry
    bounce - Permanent delivery failure

  Per-domain subdirectories are created automatically when the first
  mail arrives for that domain.


TLS / LET'S ENCRYPT
--------------------
The installer can optionally request a TLS certificate from Let's
Encrypt using certbot. This replaces the default self-signed (snakeoil)
certificate and enables trusted STARTTLS encryption between mail servers.

Requirements:
  - Port 80 must be open and reachable from the internet
  - DNS A record for the gateway hostname must point to the server IP

Certificate location:
  /etc/letsencrypt/live/<hostname>/fullchain.pem   (certificate)
  /etc/letsencrypt/live/<hostname>/privkey.pem     (private key)

Automatic renewal:
  Certbot installs a systemd timer (certbot.timer) that runs
  "certbot renew" automatically twice a day. A deploy hook at
  /etc/letsencrypt/renewal-hooks/deploy/postfix-reload.sh reloads
  Postfix whenever the certificate is renewed.

  Check renewal timer status:
    systemctl status certbot.timer

Manual commands:
  View certificate status:    certbot certificates
  Test renewal (dry run):     certbot renew --dry-run
  Force renewal:              certbot renew --force-renewal
  Renew and reload Postfix:   certbot renew

If Let's Encrypt is not enabled during installation (or if the
certificate request fails), Postfix uses the self-signed snakeoil
certificate. TLS is still active (opportunistic), but other servers
may not trust the certificate. Re-run the installer to switch to
Let's Encrypt at any time.


RECIPIENT VERIFICATION
----------------------
The installer can optionally enable recipient verification. When
enabled, the gateway probes the destination SMTP server with a
RCPT TO command before accepting mail. If the destination rejects
the recipient (550 User unknown), the gateway immediately rejects
the original message. This prevents backscatter: without it, the
gateway accepts mail for non-existent users, tries to deliver it,
gets a bounce from the destination, and generates a bounce message
to the (likely forged) sender address.

Prerequisite:
  The destination server must reject unknown recipients at the SMTP
  RCPT TO stage (respond 550). If the destination is configured as
  a catch-all (accepts all addresses), verification provides no
  benefit and should be left disabled.

  Test your destination server before enabling:
    telnet destination-server 25
    EHLO test
    MAIL FROM:<test@test.com>
    RCPT TO:<nonexistent-user-xyz@yourdomain.com>
    (must respond 550 - if it responds 250, do not enable)

How it works:
  1. Mail arrives at gateway for user@yourdomain.com
  2. Gateway opens a separate SMTP connection to the destination
  3. Sends RCPT TO:<user@yourdomain.com> to check if user exists
  4. If destination responds 250: accept the original mail
  5. If destination responds 550: reject the original mail
  6. Result is cached to avoid repeated probes

Cache settings (configured in main.cf when enabled):
  address_verify_positive_expire_time = 7d   (valid user cached 7 days)
  address_verify_negative_expire_time = 3d   (invalid user cached 3 days)
  address_verify_negative_refresh_time = 3h  (retry invalid after 3 hours)

  If you add or remove mailboxes on the destination server, the cache
  may hold stale results for up to these durations. To flush the cache:
    postmap -d user@domain btree:/var/lib/postfix/verify

Note: the first message to a new recipient adds a small delay (2-10s)
while the gateway probes the destination. Subsequent messages for the
same recipient use the cache with no added latency.


TESTING
-------
  Interactive test (prompts for sender and recipient, sends via localhost):

     sudo ./test.sh

  This sends a test email through the gateway and shows:
  - SMTP server response (accepted, rejected, blocked)
  - Postfix log entries for the message
  - Per-domain activity log entry
  - Queue status (delivered, deferred, bounced)

  No MX records needed. Useful for verifying the gateway works before
  pointing DNS to the server.


VERIFICATION
------------
  Verify SpamAssassin configuration:
    spamassassin --lint

  Verify Postfix configuration:
    postfix check

  Verify you are not an open relay (must respond "Relay access denied"):
    telnet localhost 25
    EHLO test
    MAIL FROM:<test@test.com>
    RCPT TO:<user@unconfigured-domain.com>

  Verify recipient verification (if enabled, must respond "Recipient address rejected"):
    telnet localhost 25
    EHLO test
    MAIL FROM:<test@test.com>
    RCPT TO:<nonexistent-user-xyz@configured-domain.com>

  Test Spamhaus integration:
    Go to http://blt.spamhaus.com and send a test email


FILE STRUCTURE
--------------
  /opt/mail-gateway/              (or wherever the project is copied)
  ├── install.sh                  Interactive installation script
  ├── update-domains.sh           Update domains without reinstalling
  ├── test.sh                     Interactive gateway test (send via localhost)
  ├── domains.conf                Domain -> relay SMTP mapping
  ├── .env                        Saved config (generated on install)
  ├── readme.txt                  This file
  ├── configs/
  │   ├── postfix/
  │   │   ├── main.cf             Postfix main configuration
  │   │   ├── master.cf           Postfix services (postscreen enabled)
  │   │   ├── dnsbl-reply-map     Spamhaus rejection messages
  │   │   ├── dnsbl_reply         Postscreen DNSBL reply map
  │   │   └── header_checks       Dangerous attachment blocking
  │   └── spamassassin/
  │       └── local.cf            SpamAssassin configuration
  └── scripts/
      ├── mail-logger.py          Real-time log parser daemon
      └── mail-logger.service     Systemd service for the logger

  Files deployed on the server:
  /etc/postfix/                   Postfix config (with DQS key applied)
  /etc/spamassassin/              SA config + Spamhaus DQS plugin
  /etc/letsencrypt/               TLS certificates (if Let's Encrypt enabled)
  /opt/mail-gateway/scripts/      Mail logger
  /var/log/spamhaus/              Per-domain logs (activity.log)
  /var/lib/mail-gateway/          Logger state (read position tracking)
