===============================================================================
  POSTFIX + SPAMASSASSIN MAIL GATEWAY - Spamhaus DQS
===============================================================================

Automated setup for a mail filtering gateway that receives incoming email,
filters it through multiple layers of spam protection (Spamhaus DQS DNSBL,
SpamAssassin content analysis, HBL hash-based blocklists, and dangerous
attachment blocking), then relays clean mail to destination SMTP servers
based on per-domain routing rules.

Designed for use as a front-line mail gateway that sits between the internet
and your internal mail servers, providing enterprise-grade spam filtering
with Spamhaus real-time data.

Author: Gilberto Dewey (https://github.com/gdewey)
Built with the assistance of Claude (Anthropic)


REQUIREMENTS
------------
- Ubuntu 24.04 LTS
- Root access
- Spamhaus DQS key (https://www.spamhaustech.com)
- Port 25 open on firewall

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

   Answers are saved to .env for future runs. When re-running the
   installer, previous values appear as defaults and can be accepted
   by pressing Enter.


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
The gateway runs 4 independent services:

  +-------------------+----------------------------------------------+
  | Service           | Purpose                                      |
  +-------------------+----------------------------------------------+
  | postfix           | MTA - receives and relays mail               |
  | spamd             | SpamAssassin daemon - content filtering       |
  | spamass-milter    | Connects Postfix to SpamAssassin             |
  | mail-logger       | Real-time log parser, per-domain CSV output  |
  +-------------------+----------------------------------------------+

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

  CSV format:
    timestamp,sender,recipient,status,reason

  Statuses:
    relay  - Mail accepted and delivered to destination server
    block  - Rejected (DNSBL, SpamAssassin, dangerous attachment, etc.)
    spam   - Tagged as spam but still delivered (score between 5 and 15)
    defer  - Temporary delivery failure, will retry
    bounce - Permanent delivery failure

  Per-domain subdirectories are created automatically when the first
  mail arrives for that domain.


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

  Test Spamhaus integration:
    Go to http://blt.spamhaus.com and send a test email


FILE STRUCTURE
--------------
  /opt/mail-gateway/              (or wherever the project is copied)
  ├── install.sh                  Interactive installation script
  ├── update-domains.sh           Update domains without reinstalling
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
  /opt/mail-gateway/scripts/      Mail logger
  /var/log/spamhaus/              Per-domain logs (activity.log)
  /var/lib/mail-gateway/          Logger state (read position tracking)
