"""Unpack a Web Store CRX3 into a Chromium profile's Extensions directory, the way Chrome does.

    python unpack_crx.py <crx> <extension id> <profile>/Extensions

For the Windows scenarios, which have Python and no zsh. test/scenarios/45-claude-extension/
setup.sh carries the same code inline and the reasoning: osquery derives an extension's id
from the manifest `key`, Chrome's own unpacker copies the publisher key out of the CRX
header, and this does the same, then checks the key derives the id requested. Prints the
version, which names the directory the extension lands in (<id>/<version>_0).
"""
import base64
import hashlib
import io
import json
import os
import struct
import sys
import zipfile

crx, eid, root = sys.argv[1:4]
raw = open(crx, "rb").read()
assert raw[:4] == b"Cr24", "not a CRX3"
hlen = struct.unpack("<II", raw[4:12])[1]


def fields(buf):
    # Length-delimited protobuf fields, which is all of a CRX3 header that matters here.
    i = 0
    while i < len(buf):
        tag = shift = 0
        while True:
            b = buf[i]; i += 1; tag |= (b & 0x7F) << shift; shift += 7
            if b < 0x80:
                break
        if tag & 7 == 0:
            while buf[i] >= 0x80:
                i += 1
            i += 1
            continue
        n = shift = 0
        while True:
            b = buf[i]; i += 1; n |= (b & 0x7F) << shift; shift += 7
            if b < 0x80:
                break
        yield tag >> 3, buf[i:i + n]
        i += n


proofs, crx_id = [], b""
for num, val in fields(raw[12:12 + hlen]):
    if num in (2, 3):                 # sha256_with_rsa, sha256_with_ecdsa
        proofs += [v for n, v in fields(val) if n == 1]
    elif num == 10000:                # signed_header_data
        crx_id = next((v for n, v in fields(val) if n == 1), b"")
z = zipfile.ZipFile(io.BytesIO(raw[12 + hlen:]))
m = json.loads(z.read("manifest.json").decode("utf-8-sig"))
injected = not m.get("key")
if injected:
    dev = [k for k in proofs if hashlib.sha256(k).digest()[:16] == crx_id]
    assert dev, "no developer key in the CRX header"
    m["key"] = base64.b64encode(dev[0]).decode()
derived = "".join(chr(97 + int(c, 16))
                  for c in hashlib.sha256(base64.b64decode(m["key"])).hexdigest()[:32])
assert derived == eid, "key derives %s, not %s" % (derived, eid)
dest = os.path.join(root, eid, "%s_0" % m["version"])
os.makedirs(dest, exist_ok=True)
z.extractall(dest)
if injected:
    with open(os.path.join(dest, "manifest.json"), "w") as f:
        json.dump(m, f, indent=2)
print(m["version"])
