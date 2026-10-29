#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Loads sample mail into a test mail server over IMAP.

Uses only the Python standard library. Messages are added with IMAP APPEND,
so flags and received dates are set exactly as a real client would set
them. Safety rules:
  - only connects to 127.0.0.1 and only to @citusmail.test accounts, so it can
    never touch a real mailbox;
  - refuses to run if a target mailbox already has mail (use `citusmailtest
    reset` for a clean start), so messages are never duplicated.

Usage: seed.py --port PORT [--tls --ca CA_FILE] [--plan seed.toml]
"""
from __future__ import annotations

import argparse
import base64
import imaplib
import ssl
import sys
import tomllib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.parser import BytesHeaderParser
from email.utils import parsedate_to_datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PLAN = Path(__file__).resolve().parent / "seed.toml"
FIXTURES_DIR = REPO_ROOT / "test-data" / "mail"
SERVER_HOST = "127.0.0.1"
TEST_DOMAIN = "citusmail.test"
ALLOWED_FLAGS = {"\\Seen", "\\Answered", "\\Flagged", "\\Draft", "\\Deleted"}
# Used when a fixture has no usable Date header.
FALLBACK_DATE = datetime(2026, 10, 1, tzinfo=timezone.utc)
TIMEOUT_SECONDS = 15


class SeedError(Exception):
    """A problem that stops seeding, with a message for the user."""


# --------------------------------------------------------------- the plan
@dataclass(frozen=True)
class SeedMessage:
    user: str
    mailbox: str
    file: Path
    flags: tuple[str, ...] = ()

    @property
    def address(self) -> str:
        return f"{self.user}@{TEST_DOMAIN}"


@dataclass
class SeedPlan:
    messages: list[SeedMessage]
    unused_fixtures: list[Path] = field(default_factory=list)

    @classmethod
    def load(cls, plan_path: Path, fixtures_dir: Path) -> SeedPlan:
        try:
            data = tomllib.loads(plan_path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as e:
            raise SeedError(f"cannot read {plan_path}: {e}") from e

        entries = data.get("message")
        if not isinstance(entries, list) or not entries:
            raise SeedError(f"{plan_path} has no [[message]] entries")

        messages = [cls._parse_entry(i, e, fixtures_dir) for i, e in enumerate(entries, 1)]
        used = {m.file for m in messages}
        unused = sorted(p for p in fixtures_dir.rglob("*.eml") if p.resolve() not in used)
        return cls(messages, unused)

    @staticmethod
    def _parse_entry(index: int, entry: object, fixtures_dir: Path) -> SeedMessage:
        where = f"message #{index}"
        if not isinstance(entry, dict):
            raise SeedError(f"{where}: must be a table")
        unknown = set(entry) - {"user", "mailbox", "file", "flags"}
        if unknown:
            raise SeedError(f"{where}: unknown keys {sorted(unknown)}")

        user, mailbox, file = entry.get("user"), entry.get("mailbox"), entry.get("file")
        for key, value in (("user", user), ("mailbox", mailbox), ("file", file)):
            if not isinstance(value, str) or not value:
                raise SeedError(f"{where}: '{key}' must be a non-empty string")
        if not user.isalnum():
            raise SeedError(f"{where}: user '{user}' must be a plain name like 'alice'")

        path = (fixtures_dir / file).resolve()
        if fixtures_dir.resolve() not in path.parents:
            raise SeedError(f"{where}: file '{file}' is outside {fixtures_dir}")
        if not path.is_file():
            raise SeedError(f"{where}: file '{file}' does not exist")

        flags = entry.get("flags", [])
        if not isinstance(flags, list) or not all(f in ALLOWED_FLAGS for f in flags):
            raise SeedError(f"{where}: flags must be a list from {sorted(ALLOWED_FLAGS)}")

        return SeedMessage(user, mailbox, path, tuple(flags))

    def by_user(self) -> dict[str, list[SeedMessage]]:
        grouped: dict[str, list[SeedMessage]] = {}
        for message in self.messages:
            grouped.setdefault(message.user, []).append(message)
        return grouped


# ----------------------------------------------------------- IMAP helpers
def encode_mailbox_name(name: str) -> str:
    """Encodes a mailbox name as IMAP modified UTF-7 (RFC 3501, 5.1.3)."""
    out: list[str] = []
    pending: list[str] = []

    def flush() -> None:
        if pending:
            utf16 = "".join(pending).encode("utf-16-be")
            b64 = base64.b64encode(utf16).decode("ascii").rstrip("=").replace("/", ",")
            out.append(f"&{b64}-")
            pending.clear()

    for ch in name:
        if 0x20 <= ord(ch) <= 0x7E:
            flush()
            out.append("&-" if ch == "&" else ch)
        else:
            pending.append(ch)
    flush()
    return "".join(out)


def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def to_crlf(data: bytes) -> bytes:
    """IMAP requires CRLF line endings; fixtures are stored with LF."""
    return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


def internal_date(data: bytes) -> datetime:
    """The received date to store: the fixture's Date header if valid."""
    header = BytesHeaderParser().parsebytes(data).get("Date")
    if header:
        try:
            parsed = parsedate_to_datetime(str(header))
            if parsed.tzinfo is not None:
                return parsed
        except (TypeError, ValueError):
            pass
    return FALLBACK_DATE


@dataclass(frozen=True)
class ServerEndpoint:
    port: int
    ca_file: Path | None  # None means plain-text IMAP (the "plain" server)

    def connect(self) -> imaplib.IMAP4:
        if self.ca_file is None:
            return imaplib.IMAP4(SERVER_HOST, self.port, timeout=TIMEOUT_SECONDS)
        context = ssl.create_default_context(cafile=str(self.ca_file))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        return imaplib.IMAP4_SSL(SERVER_HOST, self.port, ssl_context=context,
                                 timeout=TIMEOUT_SECONDS)


class MailboxSeeder:
    """Seeds one user's mailboxes over a single IMAP connection."""

    def __init__(self, endpoint: ServerEndpoint, address: str) -> None:
        if not address.endswith(f"@{TEST_DOMAIN}"):
            raise SeedError(f"refusing to seed non-test account {address}")
        self._endpoint = endpoint
        self._address = address
        self._imap: imaplib.IMAP4 | None = None

    def __enter__(self) -> MailboxSeeder:
        user = self._address.split("@", 1)[0]
        try:
            self._imap = self._endpoint.connect()
            self._check(self._imap.login(self._address, f"{user}-test-password"), "login")
        except (OSError, imaplib.IMAP4.error, ssl.SSLError) as e:
            raise SeedError(f"{self._address}: cannot log in: {e}") from e
        return self

    def __exit__(self, *exc: object) -> None:
        if self._imap is not None:
            try:
                self._imap.logout()
            except (OSError, imaplib.IMAP4.error):
                pass

    @property
    def imap(self) -> imaplib.IMAP4:
        assert self._imap is not None, "use MailboxSeeder as a context manager"
        return self._imap

    def ensure_empty_mailbox(self, mailbox: str) -> None:
        encoded = quote(encode_mailbox_name(mailbox))
        typ, data = self.imap.create(encoded)
        if typ != "OK" and b"ALREADYEXISTS" not in b" ".join(d or b"" for d in data):
            raise SeedError(f"{self._address}: cannot create '{mailbox}': {data}")
        typ, data = self.imap.status(encoded, "(MESSAGES)")
        self._check((typ, data), f"STATUS {mailbox}")
        if b"(MESSAGES 0)" not in data[0]:
            raise SeedError(f"{self._address}: '{mailbox}' already has mail; "
                            "run 'test-server/citusmailtest reset' for a clean start")

    def append(self, message: SeedMessage) -> None:
        raw = message.file.read_bytes()
        flags = f"({' '.join(message.flags)})" if message.flags else None
        result = self.imap.append(quote(encode_mailbox_name(message.mailbox)), flags,
                                  imaplib.Time2Internaldate(internal_date(raw)), to_crlf(raw))
        self._check(result, f"APPEND {message.file.name} to {message.mailbox}")

    def _check(self, result: tuple[str, list], action: str) -> None:
        typ, data = result
        if typ != "OK":
            raise SeedError(f"{self._address}: {action} failed: {data}")


# ------------------------------------------------------------------- main
def seed(plan: SeedPlan, endpoint: ServerEndpoint) -> int:
    count = 0
    for user, messages in plan.by_user().items():
        address = f"{user}@{TEST_DOMAIN}"
        try:
            with MailboxSeeder(endpoint, address) as seeder:
                for mailbox in dict.fromkeys(m.mailbox for m in messages):
                    seeder.ensure_empty_mailbox(mailbox)
                for message in messages:
                    seeder.append(message)
                    count += 1
        except (OSError, imaplib.IMAP4.error, ssl.SSLError) as e:
            # Any connection or protocol failure ends with a clear message.
            raise SeedError(f"{address}: {e}; see 'citusmailtest logs'") from e
    return count


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--tls", action="store_true", help="use IMAPS (implicit TLS)")
    parser.add_argument("--ca", type=Path, help="CA certificate to trust (with --tls)")
    parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    args = parser.parse_args(argv)
    if args.tls and args.ca is None:
        parser.error("--tls needs --ca")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        plan = SeedPlan.load(args.plan, FIXTURES_DIR)
        endpoint = ServerEndpoint(args.port, args.ca if args.tls else None)
        count = seed(plan, endpoint)
    except SeedError as e:
        print(f"[seed] error: {e}", file=sys.stderr)
        return 1
    for path in plan.unused_fixtures:
        print(f"[seed] note: {path.relative_to(REPO_ROOT)} is not seeded", file=sys.stderr)
    print(f"[seed] port {args.port}: added {count} messages", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
