#!/usr/bin/env python3
"""
mail-logger.py - Real-time Postfix mail log parser for the gateway.

Watches /var/log/mail.log and writes per-domain log files to:
    /var/log/spamhaus/<recipient_domain>/activity.log

Log format (CSV):
    timestamp,sender,recipient,status,reason

Statuses:
    relay  - Message accepted and delivered to destination SMTP
    block  - Rejected at SMTP level (DNSBL, RBL, milter, attachment, etc.)
    spam   - Tagged as spam by SpamAssassin but still relayed (score < reject threshold)
    defer  - Delivery temporarily failed, will retry
    bounce - Delivery permanently failed

Usage:
    python3 mail-logger.py              # foreground (tail from end)
    python3 mail-logger.py --catchup    # process existing log first, then tail
"""

import os
import sys
import re
import csv
import time
import signal
import argparse
from datetime import datetime
from collections import defaultdict

LOG_FILE = "/var/log/mail.log"
OUTPUT_DIR = "/var/log/spamhaus"
STATE_FILE = "/var/lib/mail-gateway/last_position"
MAX_QUEUE_ENTRIES = 50000

queue_data = {}


def get_domain(email):
    if "@" in email:
        return email.split("@", 1)[1].strip().lower().rstrip(">")
    return "unknown"


def write_log_entry(domain, timestamp, sender, recipient, status, reason=""):
    domain = re.sub(r"[^a-zA-Z0-9._-]", "_", domain)
    domain_dir = os.path.join(OUTPUT_DIR, domain)
    os.makedirs(domain_dir, exist_ok=True)

    log_file = os.path.join(domain_dir, "activity.log")
    file_exists = os.path.exists(log_file) and os.path.getsize(log_file) > 0

    with open(log_file, "a", newline="") as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(["timestamp", "sender", "recipient", "status", "reason"])
        writer.writerow([timestamp, sender, recipient, status, reason])


def clean_email(addr):
    return addr.strip("<>").strip()


def parse_line(line):
    if "postfix/" not in line:
        return

    ts_match = re.match(r"^(\w+\s+\d+\s+\d+:\d+:\d+)", line)
    if not ts_match:
        return
    timestamp = ts_match.group(1)

    # --- NOQUEUE: reject from smtpd (RBL, RHSBL, policy, etc.) ---
    noqueue = re.search(
        r"postfix/smtpd\[\d+\]: NOQUEUE: reject: RCPT from\s+\S+: "
        r"(.+?);\s+from=<([^>]*)>\s+to=<([^>]*)>",
        line,
    )
    if noqueue:
        reason = noqueue.group(1).strip()
        sender = clean_email(noqueue.group(2)) or "unknown"
        recipient = clean_email(noqueue.group(3)) or "unknown"
        domain = get_domain(recipient)
        write_log_entry(domain, timestamp, sender, recipient, "block", reason)
        return

    # --- milter-reject (SpamAssassin score >= reject threshold) ---
    milter_rej = re.search(
        r"postfix/cleanup\[\d+\]: [A-F0-9]+: milter-reject: .+? from\s+\S+:\s+"
        r"(.+?);\s+from=<([^>]*)>\s+to=<([^>]*)>",
        line,
    )
    if milter_rej:
        reason = milter_rej.group(1).strip()
        sender = clean_email(milter_rej.group(2)) or "unknown"
        recipient = clean_email(milter_rej.group(3)) or "unknown"
        domain = get_domain(recipient)
        write_log_entry(
            domain, timestamp, sender, recipient, "block", f"SpamAssassin: {reason}"
        )
        return

    # --- header_checks REJECT (dangerous attachment) ---
    hdr_rej = re.search(
        r"postfix/cleanup\[\d+\]: [A-F0-9]+: reject: header .+?: (.+?);\s+"
        r"from=<([^>]*)>\s+to=<([^>]*)>",
        line,
    )
    if hdr_rej:
        reason = hdr_rej.group(1).strip()
        sender = clean_email(hdr_rej.group(2)) or "unknown"
        recipient = clean_email(hdr_rej.group(3)) or "unknown"
        domain = get_domain(recipient)
        write_log_entry(
            domain, timestamp, sender, recipient, "block", f"Attachment: {reason}"
        )
        return

    # --- qmgr: track sender for a queue ID ---
    qmgr_from = re.search(
        r"postfix/qmgr\[\d+\]: ([A-F0-9]+): from=<([^>]*)>,", line
    )
    if qmgr_from:
        qid = qmgr_from.group(1)
        sender = clean_email(qmgr_from.group(2))
        if qid not in queue_data:
            queue_data[qid] = {}
        queue_data[qid]["from"] = sender
        queue_data[qid]["timestamp"] = timestamp
        return

    # --- smtpd: extract X-Spam-Status from milter additions ---
    spam_tag = re.search(
        r"postfix/cleanup\[\d+\]: ([A-F0-9]+): .+?X-Spam-Status: Yes", line
    )
    if spam_tag:
        qid = spam_tag.group(1)
        if qid not in queue_data:
            queue_data[qid] = {}
        queue_data[qid]["spam"] = True
        return

    # --- smtp/relay: delivery result ---
    smtp_to = re.search(
        r"postfix/(smtp|relay)\[\d+\]: ([A-F0-9]+): "
        r"to=<([^>]*)>,\s+relay=([^,]+),\s+.+?status=(\w+)\s+\((.+?)\)",
        line,
    )
    if smtp_to:
        qid = smtp_to.group(2)
        recipient = clean_email(smtp_to.group(3))
        relay_host = smtp_to.group(4).strip()
        status_word = smtp_to.group(5)
        status_detail = smtp_to.group(6).strip()

        qinfo = queue_data.get(qid, {})
        sender = qinfo.get("from", "unknown")
        ts = qinfo.get("timestamp", timestamp)
        is_spam = qinfo.get("spam", False)
        domain = get_domain(recipient)

        if status_word == "sent":
            if is_spam:
                write_log_entry(
                    domain,
                    ts,
                    sender,
                    recipient,
                    "spam",
                    f"Tagged as spam, relayed via {relay_host}",
                )
            else:
                write_log_entry(
                    domain,
                    ts,
                    sender,
                    recipient,
                    "relay",
                    f"Delivered via {relay_host}",
                )
        elif status_word == "deferred":
            write_log_entry(domain, ts, sender, recipient, "defer", status_detail)
        elif status_word == "bounced":
            write_log_entry(domain, ts, sender, recipient, "bounce", status_detail)
        return

    # --- qmgr: removed -> clean up ---
    removed = re.search(r"postfix/qmgr\[\d+\]: ([A-F0-9]+): removed", line)
    if removed:
        queue_data.pop(removed.group(1), None)
        return


def save_position(pos, inode):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        f.write(f"{inode}\n{pos}\n")


def load_position():
    try:
        with open(STATE_FILE, "r") as f:
            lines = f.read().strip().split("\n")
            return int(lines[0]), int(lines[1])
    except (FileNotFoundError, ValueError, IndexError):
        return 0, 0


def cleanup_queue():
    if len(queue_data) > MAX_QUEUE_ENTRIES:
        keys = sorted(queue_data.keys())[: MAX_QUEUE_ENTRIES // 2]
        for k in keys:
            del queue_data[k]


def tail_log(catchup=False):
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    saved_inode, saved_pos = load_position() if catchup else (0, 0)
    counter = 0

    while True:
        try:
            stat = os.stat(LOG_FILE)
            current_inode = stat.st_ino
        except FileNotFoundError:
            time.sleep(2)
            continue

        try:
            with open(LOG_FILE, "r") as f:
                if catchup and current_inode == saved_inode and saved_pos > 0:
                    f.seek(saved_pos)
                    catchup = False
                elif not catchup:
                    f.seek(0, 2)

                while True:
                    line = f.readline()
                    if line:
                        parse_line(line.strip())
                        counter += 1
                        if counter % 500 == 0:
                            save_position(f.tell(), current_inode)
                            cleanup_queue()
                    else:
                        save_position(f.tell(), current_inode)
                        try:
                            new_stat = os.stat(LOG_FILE)
                            if new_stat.st_ino != current_inode:
                                break
                        except FileNotFoundError:
                            time.sleep(1)
                            break
                        time.sleep(0.2)
        except FileNotFoundError:
            time.sleep(2)


def main():
    parser = argparse.ArgumentParser(description="Postfix mail gateway log parser")
    parser.add_argument(
        "--catchup",
        action="store_true",
        help="Process existing log from last position before tailing",
    )
    args = parser.parse_args()

    def handle_signal(sig, frame):
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    tail_log(catchup=args.catchup)


if __name__ == "__main__":
    main()
