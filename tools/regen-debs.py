#!/usr/bin/env python3
"""
Пересобирает вшитый локальный apt-репо в ../deb для e3372-proxmox.

Разрешает dependency-closure пакетов TARGETS для Debian trixie / amd64,
качает .deb напрямую из зеркала, генерит Packages/Packages.gz/Release/manifest.txt.
Базовые пакеты (Priority required/important/standard) не качаются — они и так
есть в системе; apt при установке возьмёт их из dpkg-статуса.

Запуск:  python3 tools/regen-debs.py
"""
import lzma, urllib.request, os, sys, re, gzip, hashlib, email.utils, time

MIRROR  = "http://deb.debian.org/debian"
SUITE, ARCH = "trixie", "amd64"
TARGETS = ["usb-modeswitch", "usb-modeswitch-data", "networkd-dispatcher"]
SKIP_PRIORITY = {"required", "important", "standard"}
DEBDIR = os.path.join(os.path.dirname(__file__), "..", "deb")

def fetch(url):
    print("  GET", url, file=sys.stderr)
    with urllib.request.urlopen(url, timeout=90) as r:
        return r.read()

def parse_index():
    raw = fetch(f"{MIRROR}/dists/{SUITE}/main/binary-{ARCH}/Packages.xz")
    text = lzma.decompress(raw).decode("utf-8", "replace")
    pkgs = {}
    for block in text.split("\n\n"):
        if not block.strip():
            continue
        d, key = {}, None
        for line in block.split("\n"):
            if line and not line[0].isspace() and ":" in line:
                key, _, val = line.partition(":")
                d[key.strip()] = val.strip()
        d["_stanza"] = block.strip()
        name = d.get("Package")
        if name and name not in pkgs:
            pkgs[name] = d
    return pkgs

def dep_names(field):
    out = []
    for alt in (field or "").split(","):
        alt = alt.strip()
        if not alt:
            continue
        m = re.match(r"^([a-z0-9][a-z0-9+.\-]*)", alt.split("|")[0].strip())
        if m:
            out.append(m.group(1))
    return out

def resolve(pkgs):
    resolved, queue = set(), list(TARGETS)
    while queue:
        n = queue.pop()
        if n in resolved:
            continue
        p = pkgs.get(n)
        if not p:
            prov = next((k for k, v in pkgs.items() if n in dep_names(v.get("Provides"))), None)
            if prov:
                queue.append(prov)
            continue
        resolved.add(n)
        for dn in dep_names(p.get("Pre-Depends")) + dep_names(p.get("Depends")):
            queue.append(dn)
    return resolved

def field_replace(stanza, updates, drop):
    lines, seen = [], set()
    for line in stanza.split("\n"):
        if ":" in line and not line[0].isspace():
            k = line.split(":", 1)[0]
            if k in drop:
                continue
            if k in updates:
                lines.append(f"{k}: {updates[k]}"); seen.add(k); continue
        lines.append(line)
    for k, v in updates.items():
        if k not in seen:
            lines.append(f"{k}: {v}")
    return "\n".join(lines)

def main():
    os.makedirs(DEBDIR, exist_ok=True)
    for old in os.listdir(DEBDIR):
        if old.endswith(".deb"):
            os.remove(os.path.join(DEBDIR, old))
    pkgs = parse_index()
    closure = resolve(pkgs)
    want = [n for n in sorted(closure)
            if n in TARGETS or pkgs[n].get("Priority", "optional") not in SKIP_PRIORITY]

    stanzas, manifest = [], []
    for n in want:
        p = pkgs[n]
        fn = p["Filename"]
        base = os.path.basename(fn)
        data = fetch(f"{MIRROR}/{fn}")
        open(os.path.join(DEBDIR, base), "wb").write(data)
        st = field_replace(p["_stanza"], {
            "Filename": f"./{base}", "Size": str(len(data)),
            "SHA256": hashlib.sha256(data).hexdigest(),
            "MD5sum": hashlib.md5(data).hexdigest(),
        }, drop={"SHA1", "SHA512"})
        stanzas.append(st); manifest.append(base)

    packages = ("\n\n".join(stanzas) + "\n").encode()
    open(os.path.join(DEBDIR, "Packages"), "wb").write(packages)
    gzip.open(os.path.join(DEBDIR, "Packages.gz"), "wb").write(packages)
    pgz = open(os.path.join(DEBDIR, "Packages.gz"), "rb").read()
    def h(b): return hashlib.md5(b).hexdigest(), hashlib.sha256(b).hexdigest(), len(b)
    m1, s1, l1 = h(packages); m2, s2, l2 = h(pgz)
    open(os.path.join(DEBDIR, "Release"), "w").write(
        "Origin: e3372-proxmox\nLabel: e3372-proxmox\nSuite: ./\nArchitectures: "+ARCH+"\n"
        f"Date: {email.utils.formatdate(time.time(), usegmt=True)}\n"
        f"MD5Sum:\n {m1} {l1} Packages\n {m2} {l2} Packages.gz\n"
        f"SHA256:\n {s1} {l1} Packages\n {s2} {l2} Packages.gz\n")
    open(os.path.join(DEBDIR, "manifest.txt"), "w").write("\n".join(manifest) + "\n")
    print(f"OK: {len(manifest)} debs → {os.path.normpath(DEBDIR)}", file=sys.stderr)

if __name__ == "__main__":
    main()
