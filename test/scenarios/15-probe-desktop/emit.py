import sys
text = open(sys.argv[1], errors="replace").read()
lines = text.splitlines()
chunks, cur, size = [], [], 0
budget = max(3000, len(text) // 9 + 1)
for l in lines:
    l = l[:400]
    if size + len(l) > budget and cur:
        chunks.append(cur); cur, size = [], 0
    cur.append(l); size += len(l) + 1
if cur:
    chunks.append(cur)
for i, c in enumerate(chunks[:10]):
    msg = "\n".join(c).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::notice title=probe {i+1}/{len(chunks)}::{msg}")
