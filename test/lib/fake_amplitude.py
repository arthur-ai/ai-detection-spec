#!/usr/bin/env python3
"""A fake Amplitude ingest endpoint, for testing every state a collector can be in.

    fake_amplitude.py <state> <capture-path>

It prints the port it bound on its first line, so a caller never has to guess one or race
for it, and appends every request body it receives to <capture-path>, one JSON document
per line. The captured bodies are the point: this file exists so that
test/test_telemetry.py can assert on what actually left the process rather than on what
bin/classify believes it sends.

States, and why each one exists:

  ok        200 with an ingest body, like the real endpoint. The happy path, and the only
            state whose capture is worth asserting field-by-field.
  throttle  429. Amplitude's documented answer to a per-device rate limit, and the one a
            fleet running classify in a loop will actually meet. It must cost the run
            nothing: no retry, no backoff, no second request. The capture proves the
            count.
  toobig    413. What arrives if the event ever grows past 1MB. Unreachable today -- the
            event is counts -- but a payload-shaped bug would find it, and a handler that
            treated 413 as retryable would turn one oversized event into a loop.
  garbage   200 with a body that is not JSON. A proxy, a captive portal or a corporate
            TLS terminator answering in place of the endpoint. The status line says
            success, so a sender that parses the response without guarding it fails HERE
            and nowhere else -- and it fails AFTER the user's answer was printed, which
            makes it a crash with no visible cause.
  hang      accepts the connection and never replies. THE IMPORTANT ONE, and the direct
            descendant of fake_docker's `hang`: connect() succeeds instantly, so every
            liveness-shaped guard passes, and the sender then blocks on the READ. Without
            a timeout on the socket this state costs the user's shell forever, after their
            answer was already on screen -- a tool that appears to hang after finishing.
            It is the only state that reaches the wall clock in telemetry_send().

  There is no `refuse` state here, because refusing needs no server: the test binds a
  port, closes it, and points classify at the hole. That is the ordinary case of an
  endpoint that is simply not there, and it must be as free as the others.

Every state must produce a byte-identical report and the same exit code as a run with
telemetry switched off. That is the whole contract: this is a repo whose central rule is
that a machine reporting nothing must never be confused with a clean one, and an
analytics call is the last place worth breaking it.
"""
import json
import socket
import sys
import time

RESPONSES = {
    # Shaped like the real thing: the live endpoint answers 200 with the ingest summary,
    # and a fake returning a bare "OK" would leave a stricter reader untested.
    "ok": (b"200 OK", b'{"code":200,"events_ingested":1,"payload_size_bytes":512,'
                       b'"server_upload_time_ms":1788639415994}'),
    "throttle": (b"429 Too Many Requests", b'{"code":429,"error":"Too many requests"}'),
    "toobig": (b"413 Payload Too Large", b'{"code":413,"error":"Payload too large"}'),
    "garbage": (b"200 OK", b"<html><body>Blocked by network policy</body></html>"),
}


def capture(path, conn, req):
    """Record the request BODY, and only a well-formed one.

    Split on the header terminator rather than counting bytes, then parse. A capture that
    stored whatever arrived would let a truncated or half-sent body read as a real event,
    which is the same class of mistake as a query that returns zero rows because it never
    ran.
    """
    head, _, body = req.partition("\r\n\r\n")
    length = 0
    for line in head.split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    while len(body.encode()) < length:
        more = conn.recv(65536)
        if not more:
            break
        body += more.decode(errors="replace")
    try:
        json.loads(body)
    except ValueError:
        body = json.dumps({"unparseable": body})
    with open(path, "a") as fh:
        fh.write(body.replace("\n", " ") + "\n")


def main():
    state, path = sys.argv[1], sys.argv[2]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Port 0: the kernel picks a free one and we report it. Choosing a number here and
    # hoping would make the suite fail on whichever developer machine already uses it.
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    print(f"fake-amplitude: {state} on port {srv.getsockname()[1]}", flush=True)
    while True:
        conn, _ = srv.accept()
        try:
            req = conn.recv(65536).decode(errors="replace")
            capture(path, conn, req)
            if state == "hang":
                # Captured FIRST, then silence. The request did arrive; what never comes
                # is the answer, which is precisely the state a health check cannot see.
                time.sleep(300)
                continue
            status, body = RESPONSES[state]
            conn.sendall(b"HTTP/1.1 " + status + b"\r\nContent-Type: application/json\r\n"
                         b"Content-Length: %d\r\n\r\n" % len(body) + body)
        except (OSError, KeyError):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()
