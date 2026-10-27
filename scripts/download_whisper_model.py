#!/usr/bin/env python3
"""Download and verify a pinned, offline speech model used by VibeScribe."""

import argparse
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
# Manifest and development folder for each model, matching SpeechModelID in the app.
MODELS = {
    "large-v3": ("whisper_model_manifest.json", "WhisperModel-large-v3"),
    "large-v3-turbo": ("whisper_model_manifest_turbo.json", "WhisperModel-turbo"),
    "bark-plus": ("bark_model_manifest_plus.json", "BarkModel-plus"),
}


def digest(path: Path, algorithm: str, git_blob: bool) -> str:
    hasher = hashlib.new(algorithm)
    if git_blob:
        hasher.update(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def is_valid(path: Path, file: dict) -> bool:
    if not path.is_file() or path.stat().st_size != file["size"]:
        return False
    if "sha256" in file:
        return digest(path, "sha256", False) == file["sha256"]
    return digest(path, "sha1", True) == file["gitOid"]


def download(manifest: dict, file: dict, destination: Path) -> None:
    source = manifest["sources"][file["source"]]
    url = (
        f"https://huggingface.co/{source['repo']}/resolve/{source['revision']}/"
        f"{urllib.parse.quote(file['sourcePath'], safe='/')}?download=true"
    )
    target = destination / file["path"]
    target.parent.mkdir(parents=True, exist_ok=True)

    for attempt in range(3):
        temporary = target.with_name(target.name + ".part")
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "VibeScribe model packager"})
            with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            if not is_valid(temporary, file):
                raise ValueError(f"Checksum or size mismatch for {file['path']}")
            os.replace(temporary, target)
            return
        except (OSError, urllib.error.URLError, ValueError):
            temporary.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=MODELS, default="large-v3-turbo")
    parser.add_argument("--verify-only", type=Path, metavar="DIRECTORY")
    args = parser.parse_args()

    manifest_name, folder_name = MODELS[args.model]
    manifest = json.loads((Path(__file__).parent / manifest_name).read_text())
    destination = args.verify_only or ROOT / ".build" / folder_name
    for file in manifest["files"]:
        relative_path = Path(file["path"])
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise ValueError(f"Unsafe manifest path: {relative_path}")
        target = destination / relative_path
        if is_valid(target, file):
            continue
        if args.verify_only:
            raise SystemExit(f"Missing or invalid cached model file: {target}")
        print(f"Downloading {file['path']}...")
        download(manifest, file, destination)

    print(f"Speech model {args.model} verified: {destination}")


if __name__ == "__main__":
    main()
