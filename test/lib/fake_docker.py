#!/usr/bin/env python3
"""A fake Docker daemon on a unix socket, for testing every state it can be in.

    fake_docker.py <socket-path> <state>

States, and why each one exists:

  healthy    answers GET /images/json with images. The only state that should produce
             container findings.
  hang       accepts the connection and never replies. THE IMPORTANT ONE. connect()
             succeeds in 0.000s, so a liveness probe built on connect() reports the
             daemon up, and osquery then blocks on the READ. Measured: osquery does not
             give up at all, still running past 45s. Against real Docker the same state
             costs 10.4s, because Docker's own socket layer gives up first -- the table
             has no timeout of its own, so the ceiling belongs to whatever is listening.
  error      answers 500. Observed on a real half-started Docker Desktop, where
             /v1.51/version returned 500 from this socket. It matters because `curl -s`
             exits 0 on an HTTP 500, so the obvious guard passes here and the query then
             returns zero rows -- a silent "we looked and found nothing" when we did not
             look at all.
  refuse     socket file exists with nothing listening, i.e. a stale socket. connect()
             fails at once and osquery gives up fast.

Testing against a real Docker install cannot cover these deterministically: a hosted
macOS runner has no Docker, and a developer machine is in whichever state it happens to
be in. osquery's --docker_socket flag makes the whole matrix reproducible in about a
second per state.

ONLY /images/json IS SERVED. docker_containers needs a faithful per-container inspect
document -- osquery calls /containers/<id>/json?stream=false and reads it strictly,
failing on the first missing node with "No such node (Config.Entrypoint)" and returning
zero rows while printing to stderr, which a --json caller never sees. A hand-built
inspect that osquery merely ACCEPTS is worse than none: the first attempt here produced
rows with every field empty, which would let a broken query pass. If containers are
wanted later, capture a real inspect document rather than hand-writing one.
"""
import json
import os
import socket
import sys
import time

IMAGES = [
    {"Id": "sha256:" + "a" * 64, "RepoTags": ["ollama/ollama:latest"],
     "Created": 1735689600, "Size": 4_500_000_000},
    {"Id": "sha256:" + "b" * 64, "RepoTags": ["ghcr.io/open-webui/open-webui:main"],
     "Created": 1735689600, "Size": 3_100_000_000},
    {"Id": "sha256:" + "c" * 64, "RepoTags": ["postgres:16"],
     "Created": 1735689600, "Size": 400_000_000},
]


def respond(conn, state, path=""):
    if state == "hang":
        time.sleep(300)
        return
    if state == "error":
        body = b'{"message":"server error"}'
        conn.sendall(b"HTTP/1.1 500 Internal Server Error\r\n"
                     b"Content-Type: application/json\r\n"
                     b"Content-Length: %d\r\n\r\n" % len(body) + body)
        return
    # Real Docker answers /_ping with the two bytes "OK" and text/plain, not JSON. The
    # guard checks only the status code, but a fake that returned JSON here would leave a
    # stricter guard untested and quietly wrong.
    if path.startswith("/_ping"):
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                     b"Content-Length: 2\r\n\r\nOK")
        return
    body = json.dumps(IMAGES).encode()
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                 b"Content-Length: %d\r\n\r\n" % len(body) + body)


def main():
    path, state = sys.argv[1], sys.argv[2]
    if os.path.exists(path):
        os.unlink(path)

    if state == "refuse":
        # A stale socket FILE with nothing listening. A real socket object that is then
        # closed would leave no file at all, which is the 'absent' state instead.
        open(path, "w").close()
        print(f"fake-docker: {state} on {path}", flush=True)
        time.sleep(300)
        return

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(16)
    os.chmod(path, 0o666)
    print(f"fake-docker: {state} on {path}", flush=True)
    while True:
        conn, _ = srv.accept()
        try:
            req = conn.recv(8192).decode(errors="replace")
            path = req.split(" ")[1] if req.count(" ") >= 2 else ""
            respond(conn, state, path)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()
