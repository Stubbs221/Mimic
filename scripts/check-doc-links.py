#!/usr/bin/env python3
# Created by Василий Маслов on 06.10.2026.
"""Check local Markdown/HTML links in Git's public file set, without network access."""
import argparse
from collections import Counter
from html import unescape
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent


def prose(text, strip_inline=True):
    """Exclude fenced and inline code so documentation examples are not treated as links."""
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            lines.append("")
        else:
            lines.append(line if fence is None else "")
    text = "\n".join(lines)
    return re.sub(r"(`+).*?\1", "", text) if strip_inline else text


def anchors(text):
    """Recognize ordinary GitHub heading slugs, duplicate suffixes, and explicit HTML IDs."""
    values = set(re.findall(r'\b(?:id|name)=[\"\']([^\"\']+)', text))
    counts = Counter()
    for heading in re.findall(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$", prose(text, strip_inline=False), re.MULTILINE):
        slug = unescape(re.sub(r"<[^>]*>", "", heading)).lower()
        slug = re.sub(r"[^\w\-\s]", "", slug).replace(" ", "-")
        values.add(slug if counts[slug] == 0 else f"{slug}-{counts[slug]}")
        counts[slug] += 1
    return values


def destinations(text):
    """Read inline links/images, reference definitions and HTML src/href attributes."""
    text = prose(text)
    for match in re.finditer(r"!?\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+[^)]*)?\)", text):
        yield match.group(1) or match.group(2)
    yield from re.findall(r"^\s{0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?", text, re.MULTILINE)
    yield from re.findall(r'\b(?:src|href)=[\"\']([^\"\']+)', text)


def check(files):
    errors = []
    checked = 0
    for source in files:
        for destination in destinations(source.read_text(encoding="utf-8")):
            parsed = urlsplit(unescape(destination))
            if parsed.scheme or parsed.netloc:
                continue
            target = (ROOT if parsed.path.startswith("/") else source.parent) / unquote(parsed.path).lstrip("/") if parsed.path else source
            checked += 1
            if not target.exists():
                errors.append(f"{source.relative_to(ROOT)}: missing {destination}")
            elif parsed.fragment and target.suffix.lower() == ".md" and unquote(parsed.fragment) not in anchors(target.read_text(encoding="utf-8")):
                errors.append(f"{source.relative_to(ROOT)}: missing anchor {destination}")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"{'FAIL' if errors else 'PASS'}: {checked} local links in {len(files)} Markdown files")
    return bool(errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="Optional Markdown paths relative to the repository")
    args = parser.parse_args()
    paths = args.paths or subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.md"], cwd=ROOT
    ).decode().rstrip("\0").split("\0")
    files = sorted({ROOT / path for path in paths if path})
    return check(files)


if __name__ == "__main__":
    sys.exit(main())
