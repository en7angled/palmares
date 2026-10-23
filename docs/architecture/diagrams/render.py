#!/usr/bin/env python3
"""Extract every ```mermaid block from a Markdown file, render each with mermaid-cli, report failures.

usage: render_mermaid.py <markdown-file> <out-dir> <puppeteer-config.json> [--png]
Writes <out-dir>/<doc-stem>-NN.mmd and .svg (and .png with --png). Prints a summary; exit 1 if any block fails.
"""
import re, subprocess, sys, pathlib, json

md, out, pcfg = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
want_png = "--png" in sys.argv
out.mkdir(parents=True, exist_ok=True)
text = md.read_text(encoding="utf-8")
blocks = re.findall(r"```mermaid[^\n]*\n(.*?)```", text, flags=re.S)
# title = nearest preceding heading
headings = [(m.start(), m.group(1).strip()) for m in re.finditer(r"^#{1,6}\s+(.*)$", text, flags=re.M)]
block_pos = [m.start() for m in re.finditer(r"```mermaid[^\n]*\n", text)]
def heading_for(pos):
    h = ""
    for p, t in headings:
        if p < pos: h = t
        else: break
    return h
results = []
for i, (body, pos) in enumerate(zip(blocks, block_pos), start=1):
    stem = f"{md.stem}-{i:02d}"
    mmd = out / f"{stem}.mmd"
    mmd.write_text(body, encoding="utf-8")
    svg = out / f"{stem}.svg"
    cmd = ["npx", "-y", "@mermaid-js/mermaid-cli@11.4.2", "-p", pcfg, "-i", str(mmd), "-o", str(svg), "-b", "white"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = r.returncode == 0 and svg.exists()
    if ok:
        err = ""
    else:
        lines = [l for l in (r.stderr + r.stdout).splitlines() if l and not l.startswith("npm notice")]
        key = [l for l in lines if any(k in l for k in ("Parse error", "Expecting", "Error:", "Syntax error", "UnknownDiagramError", "Lexical error"))]
        err = "\n".join((key or lines)[:8])
    kind = body.strip().splitlines()[0][:40] if body.strip() else "?"
    if ok and want_png:
        subprocess.run(["npx", "-y", "@mermaid-js/mermaid-cli@11.4.2", "-p", pcfg, "-i", str(mmd), "-o", str(out / f"{stem}.png"), "-b", "white", "-s", "2"], capture_output=True, text=True)
    results.append((stem, kind, heading_for(pos), ok, err))
bad = 0
for stem, kind, h, ok, err in results:
    print(f"{'OK  ' if ok else 'FAIL'} {stem:<28} {kind:<24} | {h}")
    if not ok:
        bad += 1
        print("     " + err.replace("\n", "\n     "))
print(f"\n{len(results)} blocks, {bad} failed")
sys.exit(1 if bad else 0)
