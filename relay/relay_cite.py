#!/usr/bin/env python3
"""Citation check for the medina relay: does each source a task cites say what it is cited for?

    relay_cite.py <workspace> <task-base> [--root <dir>] [--out <dir>] [--no-git]

Reads the files the executor's result lists under `## Changed`, finds every cited URL with
the claim it is cited for, fetches each page once and checks, in code:

  dead       the host does not resolve or refuses the connection, or HTTP 404/410
  moved      a deep link that redirected to a different host, or up to a shorter path - the
             page asked for is gone even though something answered 200
  quote      a structured `quote` that does not appear in the page text
  number     a number in the claim that appears nowhere in the page text

A page that blocks robots (401/403/429...), renders in JavaScript (almost no text), or sits
on a host that answers a path that cannot exist with 200 is `unverified`, never a finding:
the check says what it could not establish rather than guessing. A claim with no number
and no quote ("limited availability") is only link-checked: asking Jev whether the page
supports it is the obvious next step, but there are no snapshotted cases to calibrate it on
yet (see relay/jev-calibration.md).

Writes <workspace>/.relay/citations/<base>.md and .json, and prints ONE line:
  NONE                        nothing cited in the changed files
  CLEAN <n>                   n citations, no findings
  FLAGGED <findings> <n>      findings among n citations
It never raises into the relay: on any error it prints `NONE cite-error: ...`.

--root reads the changed files from another tree (a .relay/mutants/<base> snapshot) and is
how relay/jev-calibration/eval_cite.py replays old tasks; --out writes the report elsewhere;
--no-git skips the committed-version baseline. Stdlib only.
"""
import html
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from pathlib import Path

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
HEADERS = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
           "Accept-Language": "en-US,en;q=0.9"}
TOLERATED = {401, 403, 405, 406, 418, 429, 451, 503, 999}
TIMEOUT = float(os.environ.get("RELAY_CITE_TIMEOUT", "20"))
DEADLINE = float(os.environ.get("RELAY_CITE_DEADLINE", "150"))
MAX_URLS = int(os.environ.get("RELAY_CITE_MAX_URLS", "120"))
MAX_BYTES = 3_000_000
THIN_PAGE = 600          # chars of visible text below which the page is treated as JS-rendered
TEXT_EXT = {".md", ".markdown", ".txt", ".rst", ".html", ".htm", ".json", ".csv", ".yaml", ".yml"}
SKIP_FILES = re.compile(r"(^|/)(package(-lock)?\.json|[^/]*lock[^/]*|tsconfig[^/]*\.json)$|"
                        r"(^|/)(__tests__|tests?|fixtures?|__fixtures__|mocks?|__mocks__|node_modules)/", re.I)
ASSET = re.compile(r"\.(png|jpe?g|gif|svg|webp|ico|css|js|mjs|woff2?|ttf|mp4|webm|mp3)(\?|#|$)", re.I)
SKIP_HOSTS = re.compile(r"(^|\.)(localhost|127\.0\.0\.1|example\.(com|org|net)|w3\.org|schema\.org|"
                        r"googleapis\.com|gstatic\.com|cdnjs\.cloudflare\.com|jsdelivr\.net|unpkg\.com|"
                        r"cdn\.tailwindcss\.com|code\.jquery\.com|github\.com|npmjs\.com|shields\.io)$", re.I)
CONTROL_PATH = "/zzz-relay-cite-control-should-not-exist-7c3e1a"

SSL = ssl.create_default_context()
SSL.check_hostname = False
SSL.verify_mode = ssl.CERT_NONE
OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(context=SSL),
                                     urllib.request.HTTPRedirectHandler())


# ------------------------------------------------------------- extraction ---
URL_RE = re.compile(r"https?://[^\s<>\"'`)\]|]+")


def clean_url(u):
    return u.rstrip(".,;:!?*_")


def wanted(u):
    try:
        p = urllib.parse.urlsplit(u)
    except ValueError:
        return False
    return (p.scheme in ("http", "https") and bool(p.hostname) and not SKIP_HOSTS.search(p.hostname)
            and not ASSET.search(p.path))


def squash(s):
    return re.sub(r"\s+", " ", html.unescape(s or "")).strip()


def from_text(path, text):
    """Markdown/plain text: the claim is the line (a table row or a list item), or the
    paragraph when the URL sits on a line of its own."""
    out, in_code = [], False
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        for m in URL_RE.finditer(line):
            u = clean_url(m.group(0))
            if not wanted(u):
                continue
            claim = URL_RE.sub(" ", line)
            claim = re.sub(r"\[([^\]]*)\]\(\s*\)", r"\1", claim)
            if SOURCE_LINE.match(line):
                claim = section_text(lines, i)
            elif len(re.sub(r"[\W_]", "", claim)) < 15:     # a bare link line: use the paragraph
                j = i - 1
                while j >= 0 and lines[j].strip() and len(claim) < 600:
                    claim = lines[j] + " " + claim
                    j -= 1
            out.append({"file": path, "line": i + 1, "url": u, "claim": squash(claim)[:600], "quote": None})
    return out


SOURCE_LINE = re.compile(r"^[\s>*_-]*(\*\*|__)?\s*(sources?|data|via)\b\s*(\*\*|__)?\s*:", re.I)


def section_text(lines, i):
    """A `Source:` line credits the section it closes or opens, not itself: the text from
    the previous heading to the next one, which is where the figures it sources sit."""
    a = i
    while a > 0 and not lines[a - 1].lstrip().startswith("#") and i - a < 40:
        a -= 1
    b = i + 1
    while b < len(lines) and not lines[b].lstrip().startswith("#") and b - i < 40:
        b += 1
    return URL_RE.sub(" ", " ".join(lines[a:b]))[:1500]


class _Blocks(HTMLParser):
    """Collects the text of each block element that holds an <a href>, so a link's claim is
    the bullet, cell or caption it sits in."""
    BLOCK = {"p", "li", "td", "th", "figcaption", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6",
             "dd", "dt", "caption", "div", "section", "article", "footer", "aside", "figure"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.found, self.skip = [], [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "noscript"):
            self.skip += 1
        if tag in self.BLOCK:
            self.stack.append({"text": [], "links": [], "line": self.getpos()[0]})
        if tag == "a" and self.stack:
            href = dict(attrs).get("href") or ""
            if href.startswith("http"):
                self.stack[-1]["links"].append(href)

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript"):
            self.skip = max(0, self.skip - 1)
        if tag in self.BLOCK and self.stack:
            b = self.stack.pop()
            text = squash(" ".join(b["text"]))
            if self.stack:                       # parents see their children's text too
                self.stack[-1]["text"].append(text)
            # A caption or a "Source:" line credits the figure or card around it - that
            # is where the numbers it sources are drawn - so its links go up one level.
            if self.stack and b["links"] and (tag == "figcaption" or SOURCE_LINE.match(text)):
                self.stack[-1]["links"] += b["links"]
                self.stack[-1].setdefault("line_of", {}).update({u: b["line"] for u in b["links"]})
                return
            for u in b["links"]:
                self.found.append((b.get("line_of", {}).get(u, b["line"]), u, text))

    def handle_data(self, data):
        if not self.skip and self.stack:
            self.stack[-1]["text"].append(data)


def from_html(path, text):
    p = _Blocks()
    try:
        p.feed(text)
        p.close()
    except Exception:  # noqa: BLE001 - malformed HTML: fall back to the text reading
        return from_text(path, re.sub(r"<[^>]+>", " ", text))
    out, seen = [], set()
    for line, u, claim in p.found:        # innermost block first, so the tightest claim wins
        u = clean_url(u)
        if wanted(u) and (u, line) not in seen:
            seen.add((u, line))
            out.append({"file": path, "line": line, "url": u, "claim": claim[:600], "quote": None})
    return out


def from_json(path, text):
    """A dict with a `url` is a source. Its claim is the field it sources (`price_src` sources
    `price`; a `src` inside {value, src} sources that value), named after the record."""
    try:
        data = json.loads(text)
    except ValueError:
        return from_text(path, text)
    out = []

    def walk(node, keys, parent, record):
        if isinstance(node, dict):
            if isinstance(node.get("name"), str):
                record = node["name"]
            u = node.get("url")
            if isinstance(u, str) and wanted(u):
                key = keys[-1] if keys else ""
                field = re.sub(r"_?src$|_?source$", "", key) if key else ""
                val = None
                if isinstance(parent, dict):
                    val = parent.get(field) if field and field in parent else parent.get("value")
                    if field == "" and "value" in parent:
                        val = parent["value"]
                label = ".".join(k for k in keys[:-1] if not k.isdigit()) if key in ("src", "source") else field
                # Only a numeric field is a figure the source must state. A string field -
                # a phone, an address, opening hours - is an identifier: its digits are not
                # checked (directory pages often render them in JavaScript), only its link.
                shown = json.dumps(val) if isinstance(val, (int, float)) and not isinstance(val, bool) else "-"
                claim = f"{record or ''}: {label} = {shown}"
                q = node.get("quote")
                out.append({"file": path, "line": 0, "url": clean_url(u), "claim": squash(claim)[:600],
                            "quote": q if isinstance(q, str) and q.strip() else None})
            for k, v in node.items():
                walk(v, keys + [str(k)], node, record)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, keys + [str(i)], parent, record)
        elif isinstance(node, str):
            for m in URL_RE.finditer(node):
                u = clean_url(m.group(0))
                if wanted(u) and not (isinstance(parent, dict) and parent.get("url") == node):
                    out.append({"file": path, "line": 0, "url": u, "claim": squash(URL_RE.sub(" ", node))[:600],
                                "quote": None})
    walk(data, [], None, None)
    return out


def changed_files(result_md):
    m = re.search(r"^##\s+Changed[^\n]*\n(.*?)(?=^##\s|\Z)", result_md, re.S | re.M)
    files = []
    for line in (m.group(1) if m else "").splitlines():
        for f in re.findall(r"`([^`\s]+\.[A-Za-z0-9]+)`", line) or re.findall(r"^\s*[-*]\s+([^\s`]+\.[A-Za-z0-9]+)", line):
            if f not in files:
                files.append(f)
    return files


def extract(root, files):
    cites = []
    for f in files:
        p = Path(root) / f
        if Path(f).suffix.lower() not in TEXT_EXT or SKIP_FILES.search(f) or not p.is_file():
            continue
        if f.startswith(".relay/"):
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        ext = p.suffix.lower()
        cites += (from_html if ext in (".html", ".htm") else from_json if ext == ".json" else from_text)(f, text)
    return cites


def key(c):
    return (c["url"], norm(c["claim"]))


def baseline_keys(ws, files, out, base, use_git):
    """Citations the task did not add: the ones already in the committed version of each
    file, and the ones an earlier task's check already recorded. Each task edits the same
    deck or doc, and without this every check re-reports the whole file's history."""
    known = set()
    for j in Path(out).glob("*.json"):
        if j.stem == base:
            continue
        try:
            known |= {key(c) for c in json.loads(j.read_text(encoding="utf-8")).get("citations", [])}
        except (OSError, ValueError, KeyError, TypeError):
            pass
    if use_git:
        import subprocess
        tmp = Path(out) / ".head"
        for f in files:
            try:
                r = subprocess.run(["git", "-C", str(ws), "show", f"HEAD:{f}"], capture_output=True, timeout=20)
            except (OSError, subprocess.SubprocessError):
                break
            if r.returncode != 0:
                continue
            p = tmp / f
            try:
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(r.stdout)
            except OSError:
                continue
        if tmp.is_dir():
            known |= {key(c) for c in extract(tmp, files)}
            import shutil
            shutil.rmtree(tmp, ignore_errors=True)
    return known


# --------------------------------------------------------------- fetching ---
def visible_text(raw, ctype):
    if "html" not in ctype and not raw.lstrip().startswith("<"):
        return squash(raw)
    raw = re.sub(r"(?is)<(script|style|noscript|template)\b.*?</\1>", " ", raw)
    raw = re.sub(r"(?is)<!--.*?-->", " ", raw)
    # Keep attribute text a reader sees as content: meta descriptions, image alts, table data in titles.
    attrs = " ".join(re.findall(r'(?i)(?:content|alt|title|aria-label)="([^"]{3,400})"', raw))
    return squash(re.sub(r"<[^>]+>", " ", raw) + " " + attrs)


def get(url):
    """('code', status, final_url, text) or ('err', reason, '', '')."""
    last = ("err", "unknown failure", "", "")
    for _ in range(2):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with OPENER.open(req, timeout=TIMEOUT) as r:
                body = r.read(MAX_BYTES)
                ctype = r.headers.get("Content-Type", "")
                charset = r.headers.get_content_charset() or "utf-8"
                text = "" if "pdf" in ctype else visible_text(body.decode(charset, "replace"), ctype)
                return ("code", r.status, r.geturl(), text if "pdf" not in ctype else "\x00pdf")
        except urllib.error.HTTPError as e:
            return ("code", e.code, "", "")
        except urllib.error.URLError as e:
            last = ("err", f"{e.reason}", "", "")
        except Exception as e:  # noqa: BLE001
            last = ("err", f"{type(e).__name__}: {e}", "", "")
    return last


def landed_elsewhere(requested, final):
    if not final:
        return False
    a, b = urllib.parse.urlsplit(requested), urllib.parse.urlsplit(final)
    ha, hb = (a.hostname or "").removeprefix("www."), (b.hostname or "").removeprefix("www.")
    pa, pb = a.path.rstrip("/"), b.path.rstrip("/")
    if ha == hb and pa == pb:
        return False
    if ha != hb and not (hb.endswith("." + ha) or ha.endswith("." + hb)):
        return a.path.count("/") >= 1 and pa != ""
    return pa.count("/") >= 2 and len(pb) < len(pa)


_control = {}
_lock = threading.Lock()


def control_status(url):
    """What the host answers for a path that cannot exist. A 404/410 means its codes mean
    something; anything else means a 200 or a 403 from it proves nothing about a page."""
    p = urllib.parse.urlsplit(url)
    origin = f"{p.scheme}://{p.netloc}"
    with _lock:
        if origin in _control:
            return _control[origin]
    kind, val, final, _ = get(origin + CONTROL_PATH)
    meaningful = kind == "code" and (val in (404, 410) or (final and landed_elsewhere(origin + CONTROL_PATH, final)))
    with _lock:
        _control[origin] = meaningful
    return meaningful


def fetch(url):
    kind, val, final, text = get(url)
    if kind == "err":
        if re.search(r"name resolution|Name or service not known|nodename nor servname|getaddrinfo|"
                     r"No address associated|Connection refused", val, re.I):
            return {"state": "dead", "detail": val, "text": ""}
        return {"state": "unverified", "detail": f"no answer ({val[:80]})", "text": ""}
    if val in (404, 410):
        return {"state": "dead", "detail": f"HTTP {val}", "text": ""}
    if landed_elsewhere(url, final):
        return {"state": "moved", "detail": f"redirects to {final}", "text": ""}
    if val in TOLERATED or val >= 400:
        return {"state": "unverified", "detail": f"HTTP {val} (blocks robots)", "text": ""}
    if text == "\x00pdf":
        return {"state": "unverified", "detail": "PDF - text not checked", "text": ""}
    if len(text) < THIN_PAGE:
        return {"state": "unverified", "detail": f"page renders in JavaScript ({len(text)} chars of text)", "text": ""}
    if not control_status(url):
        return {"state": "soft", "detail": "host answers made-up paths too; page existence unproven", "text": text}
    return {"state": "ok", "detail": f"HTTP {val}", "text": text}


# --------------------------------------------------------------- matching ---
def norm(s):
    s = html.unescape(s or "").lower()
    s = s.translate(str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"',
                                   "–": "-", "—": "-", " ": " ", "−": "-"}))
    s = re.sub(r"(?<=\d),(?=\d{3}\b)", "", s)           # 1,703 -> 1703
    return re.sub(r"\s+", " ", s).strip()


def words(s):
    return re.findall(r"[a-z0-9]+(?:\.[0-9]+)?", norm(s))


PHONE_RE = re.compile(r"(\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b")
NUM_RE = re.compile(r"(?<![\w.])\$?(\d+(?:\.\d+)?)(\s?%|x\b|k\b)?", re.I)


def claim_numbers(claim):
    """Numbers a reader takes as facts from this source. Years, list ordinals, small counts
    and anything inside a URL are left out - they are not what a citation is for."""
    nums = []
    text = norm(URL_RE.sub(" ", claim))
    text = PHONE_RE.sub(" ", text)
    text = re.sub(r"\b([a-z]{2}) \d{5}(-\d{4})?\b", r"\1 ", text)      # NY 11550
    for m in NUM_RE.finditer(text):
        n, unit = m.group(1), (m.group(2) or "").strip().lower()
        before, after = text[max(0, m.start() - 6):m.start()], text[m.end():m.end() + 2]
        # Codes, not quantities: SOC 11-3121, area 000036, A100, #12, v2.3.1
        if (re.search(r"[a-z#/]$|\d-$", before) or re.match(r"-\d|\.\d|[a-z]", after)
                or (n.startswith("0") and len(n) > 2 and "." not in n)
                or re.search(r"\b(soc|area|naics|code|id|no\.?|v)\s*$", before)):
            continue
        if re.fullmatch(r"(19|20)\d\d", n) and not unit:
            continue
        if not unit and "." not in n and int(n) < 10:
            continue
        if n not in [x[0] for x in nums]:
            nums.append((n, unit))
    return nums


def number_on_page(n, unit, page):
    """True if the page states n. Tolerates 64% vs 64 percent, 1703 vs 1,703 (already
    normalised), 0.30 vs 0.3, $92,000 vs 92000 vs 92k."""
    variants = {n}
    if "." in n:
        variants.add(n.rstrip("0").rstrip("."))
    else:
        variants.add(n + ".00")
        if len(n) >= 4 and n.endswith("000"):
            variants.add(n[:-3] + "k")
    for v in variants:
        if re.search(rf"(?<![\d.]){re.escape(v)}(?![\d])", page):
            return True
    return False


def quote_on_page(q, page):
    nq = norm(q).strip(" .\"'")
    if nq and nq in page:
        return True
    qw = words(nq)
    if len(qw) < 3:
        return bool(qw) and all(re.search(rf"\b{re.escape(w)}\b", page) for w in qw)
    # A quote re-flowed by the page's markup still has its words, in order, close together.
    pos = 0
    for w in qw:
        m = re.compile(rf"\b{re.escape(w)}\b").search(page, pos)
        if not m or (pos and m.start() - pos > 200):
            return False
        pos = m.end()
    return True


# ----------------------------------------------------------------- report ---
def check(ws, base, root=None, out=None, use_git=True):
    ws = Path(ws)
    root = Path(root) if root else ws
    result = ws / ".relay" / "results" / f"{base}.md"
    try:
        result_md = result.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "NONE", {"reason": "no result file"}
    out = Path(out) if out else ws / ".relay" / "citations"
    files = changed_files(result_md)
    cites = extract(root, files)
    known = baseline_keys(ws, files, out, base, use_git)
    old = sum(1 for c in cites if key(c) in known)
    cites = [c for c in cites if key(c) not in known]
    if not cites:
        return "NONE", {"reason": f"no new citations in the changed files ({old} unchanged)", "citations": []}
    urls = list(dict.fromkeys(c["url"] for c in cites))[:MAX_URLS]
    pages, t0 = {}, time.time()
    # Not a `with` block: leaving one waits for every fetch still in flight, which would
    # turn DEADLINE into a suggestion. main() exits hard once the report is written.
    ex = ThreadPoolExecutor(max_workers=12)
    futs = {u: ex.submit(fetch, u) for u in urls}
    for u, f in futs.items():
        left = DEADLINE - (time.time() - t0)
        try:
            pages[u] = f.result(timeout=max(1, left))
        except Exception as e:  # noqa: BLE001 - a slow host is unverified, not a finding
            pages[u] = {"state": "unverified", "detail": f"not checked in time ({type(e).__name__})", "text": ""}
    ex.shutdown(wait=False, cancel_futures=True)

    findings = []
    for c in cites:
        pg = pages.get(c["url"], {"state": "unverified", "detail": "over the URL cap", "text": ""})
        c["page"], c["detail"], c["checks"] = pg["state"], pg["detail"], []
        if pg["state"] in ("dead", "moved"):
            c["checks"].append(pg["state"])
            continue
        if not pg["text"]:
            continue
        page = norm(pg["text"])
        if c["quote"] and not quote_on_page(c["quote"], page):
            c["checks"].append("quote")
        missing = [n + u for n, u in claim_numbers(c["claim"]) if not number_on_page(n, u, page)]
        if missing:
            c["missing"] = missing
            c["checks"].append("number")
    for c in cites:
        if c["checks"]:
            findings.append(c)
    decision = f"FLAGGED {len(findings)} {len(cites)}" if findings else f"CLEAN {len(cites)}"
    info = {"citations": cites, "urls": len(urls),
            "unverified": sum(1 for c in cites if c["page"] == "unverified")}
    info["unchanged"] = old
    write_report(out, base, decision, info)
    return decision, info


def write_report(d, base, decision, info):
    d = Path(d)
    try:
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{base}.json").write_text(json.dumps({"decision": decision, **info}, indent=1), encoding="utf-8")
        flagged = [c for c in info["citations"] if c["checks"]]
        unv = [c for c in info["citations"] if c["page"] == "unverified"]
        why = {"dead": "the link is dead", "moved": "the link redirects away from the cited page",
               "quote": "the quoted text is not on the page", "number": "a number in the claim is not on the page"}
        lines = [f"# Citation check: {base}", "",
                 f"{decision} - {len(info['citations'])} citations across {info['urls']} URLs, "
                 f"{len(unv)} could not be checked by machine.",
                 "", "Machine check, not a verdict: open the page before acting on any row.", ""]
        if flagged:
            lines += ["## Findings", "", "| # | Where | URL | Finding | Claim |", "|---|---|---|---|---|"]
            for i, c in enumerate(flagged, 1):
                f = "; ".join(why[k] for k in c["checks"])
                if c.get("missing"):
                    f += f" ({', '.join(c['missing'])})"
                if c["checks"] in (["dead"], ["moved"]):
                    f += f" - {c['detail']}"
                where = f"`{c['file']}:{c['line']}`" if c["line"] else f"`{c['file']}`"
                cl = c["claim"][:160].replace("|", "/")
                q = f" - quote: \"{c['quote'][:80]}\"" if "quote" in c["checks"] else ""
                lines.append(f"| L{i} | {where} | {c['url']} | {f} | {cl}{q} |")
            lines.append("")
        if unv:
            lines += ["## Not machine-checkable", ""]
            for u in dict.fromkeys(f"- {c['url']} - {c['detail']}" for c in unv):
                lines.append(u)
            lines.append("")
        (d / f"{base}.md").write_text("\n".join(lines), encoding="utf-8")
    except OSError:
        pass


def main(argv):
    opt = {k: argv[argv.index(k) + 1] for k in ("--root", "--out") if k in argv[:-1]}
    args = [a for a in argv[1:] if not a.startswith("--") and a not in opt.values()]
    if len(args) < 2:
        print(__doc__)
        return 2
    try:
        decision, info = check(args[0], args[1], opt.get("--root"), opt.get("--out"), "--no-git" not in argv)
        print(decision if decision != "NONE" else "NONE " + info.get("reason", ""))
    except Exception as e:  # noqa: BLE001 - never break the relay
        print(f"NONE cite-error: {type(e).__name__}: {str(e)[:160]}")
    return 0


if __name__ == "__main__":
    rc = main(sys.argv)
    sys.stdout.flush()
    os._exit(rc)        # do not wait on fetches abandoned at the deadline
