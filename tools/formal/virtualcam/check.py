#!/usr/bin/env python3
"""Model-check the virtual camera queue with TLC and compare with the expected results.

Usage (from the repo root):
  python tools/formal/virtualcam/check.py            # the three checks
  python tools/formal/virtualcam/check.py --mutants  # also show each rule failing on a broken copy
  python tools/formal/virtualcam/check.py --fetch    # first run: download the pinned TLC jar

Exit 0: every result as expected. 1: a result differs. 2: setup or tool error.
How to read the results: .claude/skills/verify-virtualcam-queue/SKILL.md
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SKILL = REPO / ".claude" / "skills" / "verify-virtualcam-queue" / "SKILL.md"
TLA_VERSION = "1.7.4"
TLA_URL = "https://github.com/tlaplus/tlaplus/releases/download/v%s/tla2tools.jar" % TLA_VERSION
TLA_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
TIMEOUT = 300  # AGENTS.md: each test at most 300 s
SUCCESS = "Model checking completed. No error has been found."

# name, spec, config, expected (None = every rule holds, else the rule TLC reports broken),
# patch (None, or model text and its replacement).
CHECKS = [
    ("safety", "VirtualCameraQueue", "Safety.cfg", None, None),
    ("recovery-all-running", "VirtualCameraRecovery", "AllRunning.cfg", None, None),
    # F1 (SKILL.md), fixed by #188: a paused consumer lets go of a closed queue.
    ("recovery-paused-reader", "VirtualCameraRecovery", "PausedReader.cfg", None, None),
]

# Each mirrors one code change in the model; the check must then break the rule.
# (code change, check, model text, replacement, rule expected to break)
MUTANTS = [
    ("VirtualCamera.cpp:214-221 publishes any finished slot, not the first recorded",
     "safety", "Oldest(i) == \\A j \\in Slots : Submitted(j) => slot[i].order <= slot[j].order",
     "Oldest(i) == TRUE", "NoStepBack"),
    ("shared-memory-queue.c:193 copies a slot without checking its sequence",
     "safety", "SlotStillHolds(f, k) == f.s = k", "SlotStillHolds(f, k) == f.s # 0", "NoStepBack"),
    ("VirtualCamera.cpp:228 publishes a slot of another session",
     "safety", "SameSession(i) == slot[i].ep = wgen", "SameSession(i) == TRUE", "OneSessionPerQueue"),
    ("shared-memory-queue.c:115 reuses a mapping that already exists",
     "safety", "CreateSucceeds(alive) == ~alive", "CreateSucceeds(alive) == TRUE", "ProducerFits"),
    ("virtualcam-filter.cpp:304-308 keeps a STOPPING queue open",
     "recovery-all-running", 'IF hstate = "stopping" /\\ prev[r] # "stopping"', "IF FALSE", "Recovery"),
    ("virtualcam-filter.cpp:246-254 a paused consumer keeps a STOPPING queue open (before #188)",
     "recovery-paused-reader", 'ReaderPausedRelease(r) ==\n    /\\ rstatus[r] = "paused"',
     'ReaderPausedRelease(r) ==\n    /\\ FALSE /\\ rstatus[r] = "paused"', "Recovery"),
]


def default_root(kind):
    """AGENTS.md: research artifacts under E:/项目/Veyra on Windows, never in the repo."""
    if os.name == "nt":
        return Path("E:/项目/Veyra") / kind
    return Path.home() / ".cache" / "veyra" / kind


def jar_path():
    env = os.environ.get("VEYRA_TLA2TOOLS")
    return Path(env) if env else default_root("deps") / "tla2tools" / TLA_VERSION / "tla2tools.jar"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def ensure_jar(fetch):
    jar = jar_path()
    if not jar.is_file():
        if not fetch:
            sys.exit("TLC jar missing at %s. Rerun with --fetch (downloads %s) or set VEYRA_TLA2TOOLS." % (jar, TLA_URL))
        jar.parent.mkdir(parents=True, exist_ok=True)
        part = jar.with_suffix(".part")
        print("downloading %s" % TLA_URL)
        urllib.request.urlretrieve(TLA_URL, str(part))
        part.replace(jar)
    got = sha256(jar)
    if got != TLA_SHA256:
        sys.exit("TLC jar %s has SHA-256 %s, expected %s (tla2tools %s)." % (jar, got, TLA_SHA256, TLA_VERSION))
    return jar


def java_cmd():
    home = os.environ.get("JAVA_HOME")
    java = Path(home) / "bin" / ("java.exe" if os.name == "nt" else "java") if home else None
    java = str(java) if java and java.is_file() else shutil.which("java")
    if not java:
        sys.exit("Java 11 or later is required (java on PATH or JAVA_HOME).")
    return java


def run_tlc(java, jar, spec_text, spec, cfg, out):
    """Runs one check in its own folder outside the repo; TLC writes trace files next to the spec."""
    out.mkdir(parents=True, exist_ok=True)
    (out / (spec + ".tla")).write_text(spec_text, encoding="utf-8")
    shutil.copy(HERE / cfg, out / cfg)
    log = out / "jvm-exceptions.log"
    # java.io.tmpdir: TLC unpacks its standard modules there; keep them out of the system Temp.
    cmd = [java, "-XX:+UseParallelGC", "-Djava.io.tmpdir=" + str(out), "-Xlog:exceptions=info:file=" + str(log),
           "-cp", str(jar), "tlc2.TLC", "-workers", "auto",
           "-metadir", str(out / "states"), "-cleanup", "-config", cfg, spec + ".tla"]
    start = time.time()
    try:
        proc = subprocess.run(cmd, cwd=str(out), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=TIMEOUT, universal_newlines=True, encoding="utf-8", errors="replace")
        text = proc.stdout
    except subprocess.TimeoutExpired as e:
        text = (e.stdout or "") + "\n[check.py] TLC stopped after %d s\n" % TIMEOUT
    (out / "tlc.out").write_text(text, encoding="utf-8")
    shutil.rmtree(str(out / "states"), ignore_errors=True)  # TLC's working files, hundreds of MB
    if failed_after_success(text, log):
        print("  (%s: TLC finished without a violation, then its collision estimate threw; counted as pass)" % out.name)
        text += "\n[check.py] " + SUCCESS + "\n"
    elif log.is_file():
        log.unlink()
    return outcome(text, (HERE / cfg).read_text(encoding="utf-8")), text, time.time() - start


def failed_after_success(text, log):
    """TLC 1.7.4 reaches AbstractChecker.reportSuccess only after a complete search without a
    violation; there its fingerprint-collision estimate can divide by a zero fingerprint
    distance (BigDecimal "Division by zero"). The JVM exception log shows where it was thrown."""
    if "Division by zero" not in text or not log.is_file():
        return False
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
    return any("ArithmeticException" in a and "'reportSuccess'" in b for a, b in zip(lines, lines[1:]))


def outcome(text, cfg_text):
    """'pass', the broken rule's name, or 'error: ...'."""
    if SUCCESS in text:
        return "pass"
    m = re.search(r"Error: Invariant (\w+) is violated", text)
    if m:
        return m.group(1)
    if "Error: Deadlock reached." in text:
        return "Deadlock"
    if "Temporal properties were violated" in text:
        props = re.findall(r"^\s*PROPERTY\s+(\w+)", cfg_text, re.M)
        return props[0] if len(props) == 1 else "temporal property"
    if "TLC stopped after" in text:
        return "error: timeout"
    tail = [l for l in text.splitlines() if l.strip()][-3:]
    return "error: " + " | ".join(tail)


def states(text):
    m = re.findall(r"([\d,]+) distinct states found", text)
    return m[-1] if m else "?"


def sync_warning():
    """Coverage record and sync commit live in SKILL.md; warn when covered code moved since."""
    if not SKILL.is_file():
        return "SKILL.md not found at %s" % SKILL
    text = SKILL.read_text(encoding="utf-8")
    m = re.search(r"^Sync commit: `([0-9a-f]{7,40})`", text, re.M)
    paths = sorted(set(re.findall(r"`((?:src|third_party)/[^`:\s]+)(?::[\d,\-]+)?`", text)))
    if not m or not paths:
        return "SKILL.md has no sync commit or coverage paths"
    try:
        diff = subprocess.run(["git", "diff", "--stat", m.group(1), "--"] + paths, cwd=str(REPO),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True).stdout
    except OSError as e:
        return "git unavailable: %s" % e
    return ("covered code changed since sync commit %s:\n%s" % (m.group(1), diff.rstrip())) if diff.strip() else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fetch", action="store_true", help="download the pinned TLC jar if missing")
    ap.add_argument("--mutants", action="store_true", help="also run each mutant; each must break its rule")
    ap.add_argument("--only", choices=[c[0] for c in CHECKS], help="run one check")
    args = ap.parse_args()

    jar, java = ensure_jar(args.fetch), java_cmd()
    out_root = Path(os.environ.get("VEYRA_FORMAL_OUT") or default_root("tmp") / "formal-virtualcam")
    run_dir = out_root / time.strftime("%Y%m%d-%H%M%S")
    warn = sync_warning()
    if warn:
        print("WARNING " + warn + "\n  Review the coverage table before trusting a pass.\n")

    specs = {c[1]: (HERE / (c[1] + ".tla")).read_text(encoding="utf-8") for c in CHECKS}
    by_name = {c[0]: c for c in CHECKS}
    ok = True
    for name, spec, cfg, expected, patch in CHECKS:
        if args.only and name != args.only:
            continue
        text_in = specs[spec]
        if patch:
            if text_in.count(patch[0]) != 1:
                ok = False
                print("%-24s STALE  model text not found once; update its patch in CHECKS" % name)
                continue
            text_in = text_in.replace(*patch)
        got, text, secs = run_tlc(java, jar, text_in, spec, cfg, run_dir / name)
        want = expected or "pass"
        same = got == want
        ok &= same
        print("%-24s %-6s %s (expected %s)  states=%s  %.0fs  %s" % (
            name, "ok" if same else "DIFFER", got if got == "pass" else "breaks " + got,
            want if want == "pass" else "breaks " + want, states(text), secs, run_dir / name / "tlc.out"))

    if args.mutants:
        print("\nmutants (each must break its rule):")
        for i, (change, check, old, new, rule) in enumerate(MUTANTS, 1):
            _, spec, cfg, _, _ = by_name[check]
            if specs[spec].count(old) != 1:
                ok = False
                print("  m%d STALE   model text not found once; update MUTANTS: %s" % (i, change))
                continue
            got, text, secs = run_tlc(java, jar, specs[spec].replace(old, new), spec, cfg, run_dir / ("m%d-%s" % (i, check)))
            same = got == rule
            ok &= same
            print("  m%d %-6s %s -> %s (expected breaks %s)  %.0fs" % (
                i, "ok" if same else "DIFFER", change, got if got == "pass" else "breaks " + got, rule, secs))

    print("\nall results as expected" if ok else
          "\nSOME RESULTS DIFFER: run /statechart on the .tla and .cfg in that check's folder (SKILL.md)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
