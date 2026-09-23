#!/usr/bin/env python3
"""One-shot SRun authentication helper for GDOU-AutoConnect.

This file reads the portal password only from standard input.  Its command
line, output and exceptions deliberately never contain credential material.
"""

from __future__ import annotations

import argparse
import html
import hashlib
import hmac
import ipaddress
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from html.parser import HTMLParser
from typing import Callable, Mapping, Optional


BASE_URL = "http://10.129.1.1"
CAPTIVE_PROBE_URL = "http://captive.apple.com/hotspot-detect.html"
N = "200"
TYPE = "1"
ENC_VER = "srun_bx1"
ALPHABET = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"
MAX_RESPONSE = 65536

EXIT_OK = 0
EXIT_FAILURE = 1
EXIT_ALREADY_ONLINE = 10
EXIT_DEVICE_LIMIT = 20
EXIT_SELF_LOGOUT = 30


class TransportFailure(Exception):
    """A deliberately redacted network failure."""
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class StageFailure(Exception):
    """A safe, user-visible authentication stage and failure category."""
    def __init__(self, stage: str, code: str):
        self.stage = stage
        self.code = code
        super().__init__(stage, code)


class AcIdUnavailable(Exception):
    """The Captive Portal did not provide a safe, verified access-controller ID."""


@dataclass(frozen=True)
class HttpResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class MetaRefreshParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.contents: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, Optional[str]]]) -> None:
        if tag.lower() != "meta":
            return
        values = {key.lower(): value or "" for key, value in attrs}
        if values.get("http-equiv", "").lower() == "refresh":
            self.contents.append(values.get("content", ""))


def javascript_units(value: str) -> list[int]:
    """Return the UTF-16 code units consumed by JavaScript charCodeAt()."""
    raw = value.encode("utf-16le", "surrogatepass")
    return [raw[index] | (raw[index + 1] << 8) for index in range(0, len(raw), 2)]


def sencode(value: str, include_length: bool) -> list[int]:
    chars = javascript_units(value)
    words: list[int] = []
    for index in range(0, len(chars), 4):
        word = 0
        for offset in range(4):
            if index + offset < len(chars):
                word |= chars[index + offset] << (8 * offset)
        words.append(word & 0xFFFFFFFF)
    if include_length:
        words.append(len(chars))
    return words


def lencode(words: list[int]) -> bytes:
    return b"".join((word & 0xFFFFFFFF).to_bytes(4, "little") for word in words)


def xencode(value: str, key: str) -> bytes:
    """The SRun Portal.js xxtea-compatible xencode implementation."""
    if not value:
        return b""
    vector = sencode(value, True)
    key_words = sencode(key, False)
    key_words.extend([0] * (4 - len(key_words)))
    key_words = key_words[:4]
    n = len(vector) - 1
    z = vector[n]
    rounds = 6 + 52 // (n + 1)
    total = 0
    delta = 0x9E3779B9
    mask = 0xFFFFFFFF
    while rounds:
        rounds -= 1
        total = (total + delta) & mask
        e = (total >> 2) & 3
        for position in range(n):
            y = vector[position + 1]
            mix = ((z >> 5) ^ ((y << 2) & mask))
            mix = (mix + (((y >> 3) ^ ((z << 4) & mask)) ^ (total ^ y))) & mask
            mix = (mix + (key_words[(position & 3) ^ e] ^ z)) & mask
            z = vector[position] = (vector[position] + mix) & mask
        y = vector[0]
        mix = ((z >> 5) ^ ((y << 2) & mask))
        mix = (mix + (((y >> 3) ^ ((z << 4) & mask)) ^ (total ^ y))) & mask
        mix = (mix + (key_words[(n & 3) ^ e] ^ z)) & mask
        z = vector[n] = (vector[n] + mix) & mask
    return lencode(vector)


def custom_b64(payload: bytes) -> str:
    result: list[str] = []
    for index in range(0, len(payload) - len(payload) % 3, 3):
        number = (payload[index] << 16) | (payload[index + 1] << 8) | payload[index + 2]
        result.extend((ALPHABET[number >> 18], ALPHABET[(number >> 12) & 63],
                       ALPHABET[(number >> 6) & 63], ALPHABET[number & 63]))
    remaining = len(payload) % 3
    if remaining == 1:
        number = payload[-1] << 16
        result.extend((ALPHABET[number >> 18], ALPHABET[(number >> 12) & 63], "=", "="))
    elif remaining == 2:
        number = (payload[-2] << 16) | (payload[-1] << 8)
        result.extend((ALPHABET[number >> 18], ALPHABET[(number >> 12) & 63],
                       ALPHABET[(number >> 6) & 63], "="))
    return "".join(result)


def build_info(username: str, password: str, client_ip: str, challenge: str, ac_id: str) -> str:
    # Compact JSON matches JSON.stringify's default separators for these fields.
    payload = json.dumps({"username": username, "password": password, "ip": client_ip,
                          "acid": ac_id, "enc_ver": ENC_VER}, ensure_ascii=False,
                         separators=(",", ":"))
    return "{SRBX1}" + custom_b64(xencode(payload, challenge))


def build_login_params(username: str, password: str, client_ip: str, challenge: str,
                       ac_id: str) -> dict[str, str]:
    hmd5 = hmac.new(challenge.encode("utf-8"), password.encode("utf-8"), hashlib.md5).hexdigest()
    info = build_info(username, password, client_ip, challenge, ac_id)
    checksum_source = "".join((challenge, username, challenge, hmd5, challenge, ac_id,
                               challenge, client_ip, challenge, N, challenge, TYPE,
                               challenge, info))
    return {
        "action": "login", "username": username, "password": "{MD5}" + hmd5,
        "os": "Mac OS", "name": "Macintosh", "double_stack": "0",
        "chksum": hashlib.sha1(checksum_source.encode("utf-8")).hexdigest(),
        "info": info, "ac_id": ac_id, "ip": client_ip, "n": N, "type": TYPE,
        "callback": "srun_cb", "_": str(int(time.time() * 1000)),
    }


def parse_jsonp(raw: bytes) -> Mapping[str, object]:
    text = raw.decode("utf-8", "strict").strip()
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("not JSON or JSONP")
    parsed = json.loads(text[start:end + 1])
    if not isinstance(parsed, dict):
        raise ValueError("response is not an object")
    return parsed


def response_kind(raw: bytes) -> str:
    """Classify a body without returning any of its potentially sensitive text."""
    stripped = raw.lstrip().lower()
    if stripped.startswith(b"<"):
        return "HTML_RESPONSE"
    if stripped.startswith(b"{") or stripped.startswith(b"[") or b"(" in stripped[:128]:
        return "JSON_OR_JSONP"
    return "INVALID_RESPONSE"


def parse_stage(stage: str, raw: bytes) -> Mapping[str, object]:
    kind = response_kind(raw)
    if kind == "HTML_RESPONSE":
        raise StageFailure(stage, "HTML_RESPONSE")
    if kind != "JSON_OR_JSONP":
        raise StageFailure(stage, "INVALID_RESPONSE")
    try:
        return parse_jsonp(raw)
    except (UnicodeError, ValueError, json.JSONDecodeError):
        raise StageFailure(stage, "INVALID_JSONP") from None


def valid_ip(value: object) -> Optional[str]:
    if not isinstance(value, str):
        return None
    try:
        parsed = ipaddress.ip_address(value)
    except ValueError:
        return None
    return str(parsed) if parsed.version == 4 and not parsed.is_unspecified else None


def transport(path: str, params: Mapping[str, str]) -> bytes:
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(BASE_URL + path + "?" + query,
                                    headers={"User-Agent": "GDOU-AutoConnect/3 macOS"}, method="GET")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=5) as response:
            payload = response.read(MAX_RESPONSE + 1)
    except urllib.error.HTTPError as response:
        # NoRedirect turns 3xx into HTTPError. Do not parse redirect HTML or
        # follow it: diagnosis must expose the status without exposing URL.
        raise TransportFailure(f"HTTP_{response.code}") from None
    except urllib.error.URLError as error:
        reason = error.reason
        if isinstance(reason, TimeoutError) or "timed out" in str(reason).lower():
            raise TransportFailure("TIMEOUT") from None
        if isinstance(reason, ConnectionRefusedError) or "connection refused" in str(reason).lower():
            raise TransportFailure("CONNECTION_REFUSED") from None
        raise TransportFailure("NETWORK_ERROR") from None
    except TimeoutError:
        raise TransportFailure("TIMEOUT") from None
    except OSError:
        raise TransportFailure("NETWORK_ERROR") from None
    if len(payload) > MAX_RESPONSE:
        raise TransportFailure("RESPONSE_TOO_LARGE")
    return payload


def http_get_no_redirect(url: str) -> HttpResponse:
    """Fetch a small page while preserving redirects for explicit validation."""
    request = urllib.request.Request(url, headers={"User-Agent": "GDOU-AutoConnect/3 macOS"}, method="GET")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=5) as response:
            status, headers, payload = response.status, response.headers, response.read(MAX_RESPONSE + 1)
    except urllib.error.HTTPError as response:
        status, headers, payload = response.code, response.headers, response.read(MAX_RESPONSE + 1)
    except urllib.error.URLError as error:
        reason = error.reason
        if isinstance(reason, TimeoutError) or "timed out" in str(reason).lower():
            raise TransportFailure("TIMEOUT") from None
        raise TransportFailure("NETWORK_ERROR") from None
    except (TimeoutError, OSError):
        raise TransportFailure("NETWORK_ERROR") from None
    if len(payload) > MAX_RESPONSE:
        raise TransportFailure("RESPONSE_TOO_LARGE")
    return HttpResponse(status, headers, payload)


def ac_id_from_location(location: object) -> Optional[str]:
    """Accept only an absolute redirect to the configured SRun IPv4 host."""
    if not isinstance(location, str):
        return None
    try:
        parsed = urllib.parse.urlsplit(location)
        port = parsed.port
    except ValueError:
        return None
    if (parsed.scheme != "http" or parsed.hostname != "10.129.1.1" or
            parsed.username is not None or parsed.password is not None or port not in (None, 80)):
        return None
    matched = re.fullmatch(r"/index_([0-9]+)\.html", parsed.path)
    return matched.group(1) if matched else None


def ac_id_from_meta_refresh(body: bytes) -> Optional[str]:
    """Extract the exact ac_id from a Portal index page's meta refresh."""
    try:
        parser = MetaRefreshParser()
        parser.feed(body.decode("utf-8", "strict"))
        parser.close()
    except (UnicodeError, ValueError):
        return None
    for content in parser.contents:
        match = re.search(r"(?:^|;)\s*url\s*=\s*([^;]+)", html.unescape(content), re.IGNORECASE)
        if not match:
            continue
        parsed = urllib.parse.urlsplit(match.group(1).strip().strip("\"'"))
        values = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        ac_ids = values.get("ac_id")
        if parsed.path == "/srun_portal_pc" and ac_ids and len(ac_ids) == 1 and ac_ids[0].isdigit():
            return ac_ids[0]
    return None


def discover_ac_id(fetch: Callable[[str], HttpResponse] = http_get_no_redirect,
                   diagnostic: Optional[Callable[[str], None]] = None) -> Optional[str]:
    """Discover and cross-check the current AP's ac_id without following URLs."""
    try:
        redirect = fetch(CAPTIVE_PROBE_URL)
    except TransportFailure:
        if diagnostic:
            diagnostic("diagnostic captive_redirect=NO")
        return None
    ac_id = ac_id_from_location(redirect.headers.get("Location", ""))
    if diagnostic:
        diagnostic("diagnostic captive_redirect=" + ("YES" if ac_id else "NO"))
        diagnostic("diagnostic dynamic_ac_id=" + ("YES" if ac_id else "NO"))
    if not ac_id:
        return None
    try:
        page = fetch(f"{BASE_URL}/index_{ac_id}.html")
    except TransportFailure:
        if diagnostic:
            diagnostic("diagnostic ac_id_verified=NO")
        return None
    verified = page.status == 200 and ac_id_from_meta_refresh(page.body) == ac_id
    if diagnostic:
        diagnostic("diagnostic ac_id_verified=" + ("YES" if verified else "NO"))
    return ac_id if verified else None


def get_challenge(username: str, local_ip: str, send: Callable[[str, Mapping[str, str]], bytes],
                  diagnostic: Optional[Callable[[str], None]] = None) -> tuple[str, str]:
    """Try local IP once; only then permit one server-side IP inference attempt."""
    attempts = [local_ip] if local_ip else [""]
    if local_ip:
        attempts.append("")
    if diagnostic:
        diagnostic("diagnostic local_ip=" + ("YES" if local_ip else "NO"))
    last_failure: Optional[StageFailure] = None
    for index, requested_ip in enumerate(attempts):
        label = "local_ip_challenge" if index == 0 and local_ip else "fallback_challenge"
        try:
            raw = send("/cgi-bin/get_challenge", {
                "username": username, "ip": requested_ip, "callback": "srun_cb",
                "_": str(int(time.time() * 1000)),
            })
            if diagnostic:
                diagnostic("diagnostic stage=PARSE_CHALLENGE response=" + response_kind(raw))
            result = parse_stage("PARSE_CHALLENGE", raw)
        except TransportFailure as error:
            last_failure = StageFailure("GET_CHALLENGE", error.code)
            if diagnostic:
                diagnostic(f"diagnostic {label}=NO")
            continue
        except (OSError, TimeoutError):
            last_failure = StageFailure("GET_CHALLENGE", "NETWORK_ERROR")
            if diagnostic:
                diagnostic(f"diagnostic {label}=NO")
            continue
        except StageFailure as error:
            last_failure = error
            if diagnostic:
                diagnostic(f"diagnostic {label}=NO")
            continue
        challenge = result.get("challenge")
        server_ip = valid_ip(result.get("client_ip"))
        if diagnostic:
            diagnostic(f"diagnostic {label}=" + ("YES" if isinstance(challenge, str) and challenge else "NO"))
            diagnostic("diagnostic challenge_client_ip_present=" + ("YES" if server_ip else "NO"))
            diagnostic("diagnostic local_ip_equals_client_ip=" +
                       ("YES" if local_ip and server_ip and local_ip == server_ip else "NO"))
        if isinstance(challenge, str) and 1 <= len(challenge) <= 256:
            chosen_ip = server_ip or valid_ip(requested_ip)
            if chosen_ip:
                if diagnostic:
                    diagnostic("diagnostic stage=GET_CHALLENGE result=CHALLENGE_RECEIVED")
                return challenge, chosen_ip
    raise last_failure or StageFailure("PARSE_CHALLENGE", "INVALID_RESPONSE")


def response_exit_code(response: Mapping[str, object]) -> int:
    error = response.get("error")
    success = response.get("suc_msg")
    code = response.get("ecode")
    # SRun may return error=ok/res=ok while suc_msg says that this IP is
    # already online.  That is a session state, not proof of Internet access.
    if success == "ip_already_online_error":
        return EXIT_ALREADY_ONLINE
    if error == "ok" or success == "login_ok":
        return EXIT_OK
    if code == "E2620":
        return EXIT_DEVICE_LIMIT
    return EXIT_FAILURE


def authenticate(username: str, password: str, local_ip: str,
                 send: Callable[[str, Mapping[str, str]], bytes] = transport,
                 diagnostic: Optional[Callable[[str], None]] = None,
                 ac_id: Optional[str] = None,
                 discover: Callable[..., Optional[str]] = discover_ac_id) -> int:
    ac_id = ac_id or discover(diagnostic=diagnostic)
    if not ac_id or not ac_id.isdigit():
        raise AcIdUnavailable()
    challenge, client_ip = get_challenge(username, local_ip, send, diagnostic)
    try:
        params = build_login_params(username, password, client_ip, challenge, ac_id)
    except (UnicodeError, ValueError, TypeError):
        raise StageFailure("BUILD_LOGIN", "BUILD_FAILED") from None
    if diagnostic:
        diagnostic("diagnostic stage=BUILD_LOGIN result=OK")
    try:
        raw = send("/cgi-bin/srun_portal", params)
    except TransportFailure as error:
        raise StageFailure("SEND_LOGIN", error.code) from None
    except (OSError, TimeoutError):
        raise StageFailure("SEND_LOGIN", "NETWORK_ERROR") from None
    if diagnostic:
        diagnostic("diagnostic stage=SEND_LOGIN result=RESPONSE_RECEIVED")
        diagnostic("diagnostic stage=PARSE_LOGIN response=" + response_kind(raw))
    response = parse_stage("PARSE_LOGIN", raw)
    if diagnostic:
        for key in ("error", "error_msg", "ecode", "suc_msg", "res", "msg", "ploy_msg"):
            value = response.get(key)
            # These are the sole server fields permitted by the diagnostic
            # contract. Keep each value single-line and bounded.
            if isinstance(value, str) and "\n" not in value and "\r" not in value:
                diagnostic(f"diagnostic {key}={value[:160]}")
    return response_exit_code(response)


def current_session_for_ip(username: str, client_ip: str,
                           send: Callable[[str, Mapping[str, str]], bytes] = transport) -> Optional[dict[str, str]]:
    """Return this source IP's SRun session only when every identity matches.

    Portal.js queries rad_user_info without selecting an arbitrary IP.  We do
    the same, then require its returned IPv4 and account to exactly match the
    local Mac inputs.  An incomplete or unexpected response is never enough
    to authorize a logout.
    """
    response = parse_jsonp(send("/cgi-bin/rad_user_info", {
        "callback": "srun_cb", "_": str(int(time.time() * 1000)),
    }))
    if response.get("error") != "ok" or valid_ip(response.get("ip")) != client_ip:
        return None
    account = response.get("user_name")
    domain = response.get("domain")
    if not isinstance(account, str) or not account:
        return None
    session_username = account + ("@" + domain if isinstance(domain, str) and domain else "")
    if session_username != username:
        return None
    return {"username": session_username, "ip": client_ip}


def self_logout(username: str, client_ip: str,
                send: Callable[[str, Mapping[str, str]], bytes] = transport,
                ac_id: Optional[str] = None,
                discover: Callable[..., Optional[str]] = discover_ac_id) -> int:
    """Log out only the current Mac IP's verified normal SRun session.

    This deliberately uses Portal.js's normal ``srun_portal?action=logout``
    implementation.  It never calls rad_user_dm, which is the portal's
    separate device-management endpoint.
    """
    ac_id = ac_id or discover()
    if not ac_id or not ac_id.isdigit():
        raise AcIdUnavailable()
    session = current_session_for_ip(username, client_ip, send)
    if session is None:
        return EXIT_FAILURE
    response = parse_jsonp(send("/cgi-bin/srun_portal", {
        "action": "logout", "username": session["username"], "ip": session["ip"],
        "ac_id": ac_id, "callback": "srun_cb", "_": str(int(time.time() * 1000)),
    }))
    return EXIT_SELF_LOGOUT if response.get("error") == "ok" else EXIT_FAILURE


def portal_probe() -> bool:
    return discover_ac_id() is not None


def read_password() -> str:
    value = sys.stdin.buffer.read()
    if value.endswith(b"\n"):
        value = value[:-1]
    return value.decode("utf-8", "strict")


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--username")
    parser.add_argument("--ip", default="")
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--self-logout", action="store_true")
    parser.add_argument("--diagnose", action="store_true")
    args = parser.parse_args()
    if args.probe:
        reachable = portal_probe()
        print("SRun portal reachable" if reachable else "SRun portal unavailable")
        return EXIT_OK if reachable else EXIT_FAILURE
    if not args.username or (args.ip and not valid_ip(args.ip)):
        print("Authentication failed: local IP unavailable.")
        return EXIT_FAILURE
    if args.self_logout:
        if not valid_ip(args.ip):
            print("Current IP session could not be verified or logged out")
            return EXIT_FAILURE
        try:
            result = self_logout(args.username, args.ip)
        except AcIdUnavailable:
            print("Authentication failed: AC ID unavailable.")
            return EXIT_FAILURE
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            result = EXIT_FAILURE
        print("Current IP session logged out" if result == EXIT_SELF_LOGOUT
              else "Current IP session could not be verified or logged out")
        return result
    ac_id: Optional[str] = None
    if args.diagnose:
        ac_id = discover_ac_id(diagnostic=print)
        if not ac_id:
            print("Authentication failed: AC ID unavailable.")
            return EXIT_FAILURE
        print("diagnostic stage=PORTAL_PROBE result=REACHABLE")
        print("diagnostic configured_username_present=" + ("YES" if args.username else "NO"))
        print("diagnostic local_ip_present=" + ("YES" if args.ip else "NO"))
        # This client does not obtain a Portal-page domain value. A supplied
        # username remains opaque; no suffix is invented or appended.
        print("diagnostic domain_present=NO")
        print(f"diagnostic n={N}")
        print(f"diagnostic type={TYPE}")
    try:
        password = read_password()
    except UnicodeError:
        print("Authentication failed: credential unavailable.")
        return EXIT_FAILURE
    if not password:
        print("Authentication failed: credential unavailable.")
        return EXIT_FAILURE
    try:
        result = authenticate(args.username, password, args.ip,
                              diagnostic=print if args.diagnose else None, ac_id=ac_id)
    except AcIdUnavailable:
        print("Authentication failed: AC ID unavailable.")
        return EXIT_FAILURE
    except StageFailure as error:
        print(f"Authentication failed at stage={error.stage} error={error.code}")
        return EXIT_FAILURE
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError, TransportFailure):
        print("Authentication failed at stage=SEND_LOGIN error=NETWORK_ERROR")
        return EXIT_FAILURE
    if result == EXIT_OK:
        print("Authentication successful")
    elif result == EXIT_ALREADY_ONLINE:
        print("Authentication reports this IP is already online")
    elif result == EXIT_DEVICE_LIMIT:
        print("Campus authentication failed: online device limit reached.")
    else:
        print("Authentication failed: portal rejected login.")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
