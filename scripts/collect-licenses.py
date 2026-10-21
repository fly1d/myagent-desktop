#!/usr/bin/env python3
"""Collect notices from the exact resolved Cargo packages into an app bundle."""
import json
import pathlib
import shutil
import subprocess
import sys

project = pathlib.Path(__file__).resolve().parent.parent
destination = pathlib.Path(sys.argv[1])
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--manifest-path", str(project / "backend/Cargo.toml"),
    "--locked", "--format-version", "1",
]))
destination.mkdir(parents=True, exist_ok=True)
index = ["# Resolved Rust dependencies", "", "Package | License | Source", "--- | --- | ---"]
for package in sorted(metadata["packages"], key=lambda value: value["name"]):
    if package["source"] is None:
        continue
    name = package["name"] + "-" + package["version"]
    root = pathlib.Path(package["manifest_path"]).parent
    target = destination / name
    target.mkdir(exist_ok=True)
    found = set()
    for pattern in ("LICENSE*", "LICENCE*", "COPYING*", "NOTICE*"):
        for path in root.glob(pattern):
            if path.is_file():
                found.add(path)
    if package.get("license_file"):
        file = root / package["license_file"]
        if file.is_file():
            found.add(file)
    for file in found:
        shutil.copyfile(str(file), str(target / file.name))
    license_name = package.get("license") or "See package notice"
    index.append("%s | %s | https://crates.io/crates/%s/%s" % (
        name, license_name.replace("|", "/"), package["name"], package["version"]))
    if not found:
        (target / "PACKAGE.txt").write_text(
            "Name: %s\nLicense: %s\nSource: https://crates.io/crates/%s/%s\n" % (
                name, license_name, package["name"], package["version"]), encoding="utf-8")
(destination / "INDEX.md").write_text("\n".join(index) + "\n", encoding="utf-8")
