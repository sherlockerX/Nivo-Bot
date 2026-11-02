"""Where an address is — from a database on disk, so no third party ever sees a visitor's IP.

The admin page shows an address next to every sign-in, request and event (0.10). Since 0.11
it also says *where* that is: country, province and city, read from ip2region's ``xdb`` file
(lionsoul2014/ip2region, Apache-2.0; its data is public, Chinese-language, down to the city
for China and to the country elsewhere), which the relay downloads once into its data
directory (``CLOUD_GEOIP_DB``, next to the database) from ``CLOUD_GEOIP_URL`` and keeps in
memory — eleven megabytes, a lookup in microseconds. Nothing is sent anywhere; without the
file (offline, or ``CLOUD_GEOIP=0``) every place is simply unknown and the page says so.
``CLOUD_GEOIP_V6_URL`` adds the IPv6 file for relays reached over IPv6.

The ``xdb`` format, as read here: a 256-byte header (structure version at 0, address family
at 16); a vector index of 256×256 cells of two little-endian uint32s — the byte range of the
segment index for the first two octets; segment index entries of start, end, data length
(uint16) and data pointer (uint32); and the region strings, UTF-8,
``国家|区域|省份|城市|ISP`` with ``0`` for an unknown field.
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import re
import struct
import time
from dataclasses import dataclass
from pathlib import Path

import httpx

log = logging.getLogger("nanomuse_cloud.geo")

DEFAULT_URL = "https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/ip2region_v4.xdb"
DEFAULT_V6_URL = "https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/ip2region_v6.xdb"
HEADER_LEN = 256
VECTOR_COLS = 256
VECTOR_CELL = 8
_RETRY_S = 1800  # a download that failed is tried again after this long


@dataclass(frozen=True)
class Place:
    country: str = ""
    code: str = ""  # ISO 3166-1 alpha-2 when the data has it (CN, US…)
    province: str = ""
    city: str = ""
    isp: str = ""
    local: bool = False  # a private, loopback or link-local address: this machine's own network

    @property
    def text(self) -> str:
        """One line for a table cell: ``中国 · 广东省 · 深圳市`` / ``United States · California`` / ``本地网络``."""
        if self.local:
            return "本地网络"
        parts = [p for p in (self.country, self.province, self.city) if p]
        # a city named like its province (直辖市: 北京市|北京市) is said once
        if len(parts) >= 3 and parts[-1] == parts[-2]:
            parts = parts[:-1]
        return " · ".join(parts)

    def as_dict(self) -> dict:
        return {
            "country": self.country,
            "code": self.code,
            "province": self.province,
            "city": self.city,
            "isp": self.isp,
            "local": self.local,
            "text": self.text,
        }


def parse_region(raw: str) -> Place:
    """The 2025 data: ``中国|浙江省|杭州市|阿里|CN`` — country, province, city, ISP, country
    code; ``0`` for a field the data does not have. Older files: ``中国|华东|浙江省|杭州市|阿里``
    (a greater region second, no code) or four fields without either."""
    fields = [("" if f.strip() in ("0", "") else f.strip()) for f in raw.split("|")]
    code = ""
    if len(fields) >= 5:
        if re.fullmatch(r"[A-Z]{2}", fields[4]):
            country, province, city, isp, code = fields[:5]
        else:
            country, _region, province, city, isp = fields[:5]
    elif len(fields) == 4:
        country, province, city, isp = fields
    elif len(fields) == 3:
        country, province, city = fields
        isp = ""
    else:
        country = fields[0] if fields else ""
        province = city = isp = ""
    return Place(country=country, code=code, province=province, city=city, isp=isp)


class Xdb:
    """One xdb file, whole in memory; `search` is the official binding's algorithm.

    Structure 2.0 files are IPv4; 3.0 files say which family they hold (header byte 16).
    An IPv4 entry is 14 bytes — start and end (uint32, little-endian), data length (uint16),
    data pointer (uint32); an IPv6 entry 38 — start and end as 16 big-endian bytes, then the
    same two fields."""

    def __init__(self, data: bytes):
        if len(data) < HEADER_LEN + VECTOR_COLS * VECTOR_COLS * VECTOR_CELL:
            raise ValueError("not an xdb file")
        structure, ip_version = struct.unpack_from("<H", data, 0)[0], struct.unpack_from("<H", data, 16)[0]
        if structure < 3:
            ip_version = 4
        if ip_version not in (4, 6):
            raise ValueError("not an xdb file")
        self.data = data
        self.family = ip_version
        self.ip_len = 4 if ip_version == 4 else 16
        self.entry = 14 if ip_version == 4 else 38

    @classmethod
    def load(cls, path: Path) -> Xdb:
        return cls(path.read_bytes())

    def search(self, packed: bytes) -> str:
        """The region string for an address given as its packed bytes (4 or 16), or ""."""
        if len(packed) != self.ip_len:
            return ""
        d = self.data
        idx = HEADER_LEN + (packed[0] * VECTOR_COLS + packed[1]) * VECTOR_CELL
        s_ptr, e_ptr = struct.unpack_from("<II", d, idx)
        if not s_ptr or not e_ptr:
            return ""
        n = self.ip_len
        if n == 4:
            ip4 = int.from_bytes(packed, "big")
        lo, hi = 0, (e_ptr - s_ptr) // self.entry
        while lo <= hi:
            mid = (lo + hi) >> 1
            p = s_ptr + mid * self.entry
            if p + self.entry > len(d):
                break
            if n == 4:
                sip, eip = struct.unpack_from("<II", d, p)
                below, above = ip4 < sip, ip4 > eip
            else:
                below, above = packed < d[p : p + n], packed > d[p + n : p + 2 * n]
            if below:
                hi = mid - 1
            elif above:
                lo = mid + 1
            else:
                data_len, data_ptr = struct.unpack_from("<HI", d, p + 2 * n)
                if not data_len or data_ptr + data_len > len(d):
                    return ""
                return d[data_ptr : data_ptr + data_len].decode("utf-8", "replace")
        return ""


@dataclass
class _File:
    """One database file and where it comes from."""

    path: Path
    url: str
    xdb: Xdb | None = None
    error: str = ""
    failed_at: float = 0.0
    task: asyncio.Task | None = None

    def open(self) -> None:
        try:
            self.xdb = Xdb.load(self.path)
            self.error = ""
            log.info("geo: %s loaded (IPv%d, %d KB)", self.path.name, self.xdb.family, len(self.xdb.data) // 1024)
        except (OSError, ValueError) as exc:
            self.xdb = None
            self.error = f"{type(exc).__name__}: {exc}"[:200]
            log.warning("geo: %s could not be read (%s)", self.path, self.error)

    @property
    def fetching(self) -> bool:
        return self.task is not None and not self.task.done()


class Geo:
    """Places for addresses, with the database fetched when it is not there yet.

    `path` is the IPv4 file (required for any place at all); `v6_url` adds the IPv6 file
    next to it when set — three times the size, needed only where the relay is reached
    over IPv6."""

    def __init__(self, path: str, url: str = DEFAULT_URL, v6_url: str = "", enabled: bool = True):
        self.enabled = enabled and bool(path)
        self.files: dict[int, _File] = {}
        if self.enabled:
            p4 = Path(path)
            self.files[4] = _File(p4, url)
            if v6_url:
                self.files[6] = _File(p4.with_name(p4.stem + "_v6" + p4.suffix), v6_url)
            for f in self.files.values():
                if f.path.exists():
                    f.open()
        self._cache: dict[str, Place | None] = {}

    @property
    def ready(self) -> bool:
        return 4 in self.files and self.files[4].xdb is not None

    @property
    def error(self) -> str:
        return "; ".join(f.error for f in self.files.values() if f.error)

    def status(self) -> dict:
        return {
            "enabled": self.enabled,
            "ready": self.ready,
            "families": sorted(k for k, f in self.files.items() if f.xdb is not None),
            "error": self.error,
            "fetching": any(f.fetching for f in self.files.values()),
            "file": str(self.files[4].path) if 4 in self.files else "",
        }

    def ensure(self, http: httpx.AsyncClient | None = None) -> None:
        """Fetch what is missing, in the background (once; again after a while if it failed).
        `http` is for tests; the relay's own client talks to the provider only."""
        if not self.enabled:
            return
        for f in self.files.values():
            if f.xdb is not None or f.fetching:
                continue
            if f.failed_at and time.time() - f.failed_at < _RETRY_S:
                continue
            f.task = asyncio.create_task(self._fetch(http, f))

    async def _fetch(self, http: httpx.AsyncClient | None, f: _File) -> None:
        try:
            if http is None:
                async with httpx.AsyncClient(timeout=300.0, follow_redirects=True) as own:
                    r = await own.get(f.url)
            else:
                r = await http.get(f.url, timeout=300.0, follow_redirects=True)
            r.raise_for_status()
            Xdb(r.content)  # check before writing
            f.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = f.path.with_suffix(".part")
            tmp.write_bytes(r.content)
            tmp.replace(f.path)
        except (httpx.HTTPError, OSError, ValueError) as exc:
            f.failed_at = time.time()
            f.error = f"{type(exc).__name__}: {exc}"[:200]
            log.warning("geo: %s not fetched (%s); places stay unknown for now", f.url, f.error)
            return
        f.open()
        self._cache.clear()

    async def wait(self) -> None:
        """For tests and the CLI: until the fetches that are running have finished."""
        for f in self.files.values():
            if f.task is not None:
                await f.task

    def place(self, ip: str) -> Place | None:
        """The place of an address, or None when it is not known (no file, nonsense)."""
        ip = (ip or "").strip()
        if not ip:
            return None
        if ip in self._cache:
            return self._cache[ip]
        found = self._lookup(ip)
        if len(self._cache) > 50_000:
            self._cache.clear()
        self._cache[ip] = found
        return found

    def _lookup(self, ip: str) -> Place | None:
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            return None
        if addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_unspecified:
            return Place(local=True)
        if addr.version == 6 and isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
            addr = addr.ipv4_mapped
        f = self.files.get(addr.version)
        if f is None or f.xdb is None:
            return None
        raw = f.xdb.search(addr.packed)
        if not raw:
            return None
        place = parse_region(raw)
        return place if place.country else None

    def places(self, ips: set[str]) -> dict[str, dict]:
        """``{ip: place}`` for the addresses a page shows, the unknown ones left out."""
        out: dict[str, dict] = {}
        for ip in ips:
            p = self.place(ip)
            if p is not None:
                out[ip] = p.as_dict()
        return out


_IP_KEYS = frozenset({"ip", "first_ip", "last_ip"})


def collect_ips(obj: object, into: set[str] | None = None) -> set[str]:
    """Every address a JSON-ish answer carries under ``ip`` / ``first_ip`` / ``last_ip``."""
    found = set() if into is None else into
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in _IP_KEYS and isinstance(v, str) and v:
                found.add(v)
            elif isinstance(v, (dict, list)):
                collect_ips(v, found)
    elif isinstance(obj, list):
        for v in obj:
            collect_ips(v, found)
    return found


def group_places(rows: list[tuple[str, int]], geo: Geo) -> list[dict]:
    """``[(ip, n), …]`` → counts by country and province, the unknown ones under ``""``,
    biggest first — the admin page's "where from" table."""
    totals: dict[tuple[str, str], dict] = {}
    for ip, n in rows:
        p = geo.place(ip)
        if p is None:
            key, code = ("", ""), ""
        elif p.local:
            key, code = ("本地网络", ""), ""
        else:
            key, code = (p.country, p.province), p.code
        cell = totals.setdefault(key, {"country": key[0], "code": code, "province": key[1], "n": 0, "ips": 0})
        cell["n"] += int(n)
        cell["ips"] += 1
    return sorted(totals.values(), key=lambda c: (-c["n"], c["country"], c["province"]))
