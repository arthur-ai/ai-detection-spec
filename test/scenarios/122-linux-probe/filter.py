# Probe only: print osquery rows whose id/loc names a candidate, one per line.
import json, re, sys
pat = re.compile(r'craft|codewhale|codew|octomind|deepseek|muvon|hmbown|hunterbown|scoop|winget|lukilabs|momentic|(^|[/\\ ])qa($|[/\\. ])', re.I)
rows = json.load(open(sys.argv[1], encoding="utf-8-sig"))
seen = set()
for r in rows:
    s = "%s|%s|%s|%s|%s" % (r.get("kind"), r.get("id"), r.get("ver"), (r.get("loc") or "")[:120], (r.get("extra") or "")[:80])
    if (pat.search(r.get("id") or "") or pat.search(r.get("loc") or "") or pat.search(r.get("extra") or "")) and s not in seen:
        seen.add(s); print(s)
