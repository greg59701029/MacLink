#!/usr/bin/env python3
"""Package only reviewed companion sources, never local installation state."""

import hashlib
import pathlib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FILES = ("SETUP.md", "server.py", "assistant_actions.py", "agent_transport.py", "codex_tasks.py", "input_helper.swift", "screen_stream.py", "screen_stream.swift", "install_service.py", "diagnostics.py",
         "install.command", "check-connection.command", "show-pairing.command", "run.command")


def main():
    source = ROOT / "MacBridge"
    for name in FILES:
        if not (source / name).is_file() or (source / name).is_symlink():
            raise RuntimeError(f"Missing regular source file: {name}")
    output = ROOT / "releases"
    output.mkdir(exist_ok=True)
    archive = output / "MacLink-Companion.zip"
    temporary = archive.with_suffix(".zip.tmp")
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as package:
            for name in FILES:
                package.write(source / name, f"MacLink-Companion/{name}")
        with zipfile.ZipFile(temporary) as package:
            assert set(package.namelist()) == {f"MacLink-Companion/{name}" for name in FILES}
            assert package.testzip() is None
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Created {archive.name}: {len(FILES)} source/setup files, {archive.stat().st_size} bytes")
    print(f"SHA-256: {hashlib.sha256(archive.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
