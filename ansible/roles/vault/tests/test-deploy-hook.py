"""Exercise the rendered TLS hook against temporary certificates and a fake systemd."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


hook = sys.stdin.read()
with tempfile.TemporaryDirectory(prefix="vault-hook-") as directory:
    root = Path(directory)
    source = root / "source"
    target = root / "target"
    source.mkdir()
    target.mkdir()
    systemctl = root / "systemctl"
    systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SYSTEMCTL_LOG"\n')
    systemctl.chmod(0o700)
    script = root / "deploy"
    script.write_text(
        hook.replace("/var/lib/lego/certificates", str(source))
        .replace("/etc/vault.d/tls", str(target))
        .replace("/run/vault-tls.lock", str(root / "tls.lock"))
        .replace("install -o root -g vault", "install")
    )
    env = dict(
        os.environ,
        PATH=f"{root}:{os.environ['PATH']}",
        SYSTEMCTL_LOG=str(root / "reloads"),
    )

    def certificate(name, domain):
        run(
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:P-256",
            "-nodes",
            "-days",
            "1",
            "-subj",
            f"/CN={domain}",
            "-addext",
            f"subjectAltName=DNS:{domain}",
            "-keyout",
            str(source / f"{name}.key"),
            "-out",
            str(source / f"{name}.crt"),
        )

    def deploy():
        return subprocess.run(
            ["bash", str(script)], env=env, capture_output=True, text=True
        )

    certificate("vault", "vault.lab.canhdinh.com")
    result = deploy()
    assert result.returncode == 0, result.stderr
    assert (target / "server.crt").read_bytes() == (source / "vault.crt").read_bytes()
    assert (target / "server.key").read_bytes() == (source / "vault.key").read_bytes()
    assert (target / "server.key").stat().st_mode & 0o777 == 0o640
    assert (root / "reloads").read_text().splitlines() == [
        "is-active --quiet vault.service",
        "reload vault.service",
    ]
    original_key = (target / "server.key").read_bytes()
    original_certificate = (target / "server.crt").read_bytes()
    original_calls = (root / "reloads").read_bytes()

    certificate("other", "other.lab.canhdinh.com")
    (source / "vault.key").write_bytes((source / "other.key").read_bytes())
    assert deploy().returncode != 0, "Mismatched certificate and key were accepted"
    (source / "vault.crt").write_bytes((source / "other.crt").read_bytes())
    assert deploy().returncode != 0, "Wrong certificate hostname was accepted"
    assert (target / "server.key").read_bytes() == original_key
    assert (target / "server.crt").read_bytes() == original_certificate
    assert (root / "reloads").read_bytes() == original_calls
    assert not list(target.glob("*.new"))

print(
    "Vault TLS hook: valid pair reloads; mismatched key and wrong hostname preserve active files"
)
