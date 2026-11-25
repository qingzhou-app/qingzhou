#!/usr/bin/env python3
"""Extract the `CN` category from Apps/Tunnel-Shared/Resources/geosite.dat
into Sources/QingzhouCore/Resources/geosite-cn.txt.

Usage:
  python3 scripts/extract-geosite-cn.py          # regenerate geosite-cn.txt
  python3 scripts/extract-geosite-cn.py --check  # exit non-zero if out of sync
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def read_varint(buf: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while offset < len(buf):
        b = buf[offset]
        offset += 1
        value |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return value, offset
        shift += 7
    raise ValueError("Truncated varint in protobuf")


def skip_field(buf: bytes, offset: int, wire_type: int) -> int:
    if wire_type == 0:
        _, offset = read_varint(buf, offset)
        return offset
    if wire_type == 1:
        return offset + 8
    if wire_type == 2:
        length, offset = read_varint(buf, offset)
        return offset + length
    if wire_type == 5:
        return offset + 4
    raise ValueError(f"Unsupported protobuf wire type: {wire_type}")


def parse_domain_message(buf: bytes) -> tuple[int, str]:
    domain_type = 0
    value = ""
    offset = 0
    while offset < len(buf):
        tag, offset = read_varint(buf, offset)
        field_num = tag >> 3
        wire_type = tag & 0x7
        if field_num == 1 and wire_type == 0:
            domain_type, offset = read_varint(buf, offset)
        elif field_num == 2 and wire_type == 2:
            length, offset = read_varint(buf, offset)
            value = buf[offset : offset + length].decode("utf-8")
            offset += length
        else:
            offset = skip_field(buf, offset, wire_type)
    return domain_type, value


def parse_geosite_message(buf: bytes) -> tuple[str, list[tuple[int, str]]]:
    country_code = ""
    domains: list[tuple[int, str]] = []
    offset = 0
    while offset < len(buf):
        tag, offset = read_varint(buf, offset)
        field_num = tag >> 3
        wire_type = tag & 0x7
        if field_num == 1 and wire_type == 2:
            length, offset = read_varint(buf, offset)
            country_code = buf[offset : offset + length].decode("utf-8")
            offset += length
        elif field_num == 2 and wire_type == 2:
            length, offset = read_varint(buf, offset)
            domains.append(parse_domain_message(buf[offset : offset + length]))
            offset += length
        else:
            offset = skip_field(buf, offset, wire_type)
    return country_code, domains


def extract_cn_entries(geosite_dat: bytes) -> tuple[list[str], list[str], list[str], list[str]]:
    offset = 0
    cn_domains: list[tuple[int, str]] | None = None
    while offset < len(geosite_dat):
        tag, offset = read_varint(geosite_dat, offset)
        field_num = tag >> 3
        wire_type = tag & 0x7
        if field_num == 1 and wire_type == 2:
            length, offset = read_varint(geosite_dat, offset)
            code, entries = parse_geosite_message(geosite_dat[offset : offset + length])
            offset += length
            if code.upper() == "CN":
                cn_domains = entries
                break
        else:
            offset = skip_field(geosite_dat, offset, wire_type)

    if cn_domains is None:
        raise ValueError("Category 'CN' not found in geosite.dat")

    plains: list[str] = []
    regexes: list[str] = []
    roots: list[str] = []
    fulls: list[str] = []

    for dtype, value in cn_domains:
        if dtype == 0:
            plains.append(value.lower())
        elif dtype == 1:
            regexes.append(value)
        elif dtype == 2:
            roots.append(value.lower())
        elif dtype == 3:
            fulls.append(value.lower())
        else:
            raise ValueError(f"Unknown Domain.Type {dtype} for value {value!r}")

    return sorted(set(roots)), sorted(set(fulls)), sorted(set(regexes)), sorted(set(plains))


def render_output(roots: list[str], fulls: list[str], regexes: list[str], plains: list[str]) -> str:
    lines = [
        "# Auto-generated from Apps/Tunnel-Shared/Resources/geosite.dat (category: CN)",
        "# Regenerate via: python3 scripts/extract-geosite-cn.py",
        f"# Counts: domain={len(roots)}, full={len(fulls)}, regexp={len(regexes)}, plain={len(plains)}",
        "",
    ]
    for r in roots:
        lines.append(f"domain:{r}")
    for f in fulls:
        lines.append(f"full:{f}")
    for rx in regexes:
        lines.append(f"regexp:{rx}")
    for p in plains:
        lines.append(f"plain:{p}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract geosite:cn rules for QingzhouCore.")
    parser.add_argument("--check", action="store_true", help="Verify geosite-cn.txt matches geosite.dat")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    dat_path = repo_root / "Apps" / "Tunnel-Shared" / "Resources" / "geosite.dat"
    out_path = repo_root / "Sources" / "QingzhouCore" / "Resources" / "geosite-cn.txt"

    if not dat_path.is_file():
        print(f"ERROR: missing {dat_path}", file=sys.stderr)
        return 1

    roots, fulls, regexes, plains = extract_cn_entries(dat_path.read_bytes())
    expected = render_output(roots, fulls, regexes, plains)

    if args.check:
        if not out_path.is_file():
            print(f"ERROR: missing {out_path}; run python3 scripts/extract-geosite-cn.py", file=sys.stderr)
            return 1
        actual = out_path.read_text(encoding="utf-8")
        if actual != expected:
            print(f"ERROR: {out_path} is out of sync with {dat_path}; run python3 scripts/extract-geosite-cn.py", file=sys.stderr)
            return 1
        print(f"OK: {out_path.relative_to(repo_root)} matches geosite.dat (domain={len(roots)}, full={len(fulls)}, regexp={len(regexes)})")
        return 0

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(expected, encoding="utf-8")
    print(f"Wrote {out_path.relative_to(repo_root)} (domain={len(roots)}, full={len(fulls)}, regexp={len(regexes)}, plain={len(plains)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
