#!/usr/bin/env python3
"""Pack a Linglong (如意玲珑) layer directory into a `.layer` archive.

File layout, from `libs/linglong/src/linglong/package/layer_file.h`:

    magic number      40 bytes  "<<< deepin linglong layer archive >>>" padded with \\0
    meta info length   4 bytes  little-endian uint32
    meta info          N bytes  JSON
    binary data                 erofs image

The meta JSON is *not* `info.json` itself. `layer_packager.cpp` wraps it:

    api::types::v1::LayerInfo layerInfo;
    layerInfo.version = "1";
    layerInfo.info = nlohmann::json(*info);

so the payload must be {"version": "1", "info": {...}}.  Writing the flattened
`info.json` makes `LayerInfo::info` null and the package manager then fails with
`failed to parse json: [json.exception.type_error.304] cannot use at() with null`.
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

MAGIC = b"<<< deepin linglong layer archive >>>".ljust(40, b"\0")
META_VERSION = "1"
REQUIRED_INFO = ("arch", "base", "channel", "command", "id", "kind", "module",
                 "name", "schema_version", "size", "version")


def read_info(layer_dir):
    with open(os.path.join(layer_dir, "info.json"), encoding="utf-8") as stream:
        return json.load(stream)


def meta_bytes(layer_dir):
    meta = {"version": META_VERSION, "info": read_info(layer_dir)}
    return json.dumps(meta, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _mkfs(erofs, layer_dir):
    base = ["mkfs.erofs", "-zlz4", "-b4096", erofs, layer_dir]
    attempts = (["--all-root"], [])
    last = None
    for extra in attempts:
        command = base[:1] + extra + base[1:]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode == 0:
            return
        last = result.stdout.decode("utf-8", "replace").strip()
    raise RuntimeError("mkfs.erofs failed: " + (last or "unknown error"))


def build(layer_dir, output):
    layer_dir = os.path.abspath(layer_dir)
    output = os.path.abspath(output)
    meta = meta_bytes(layer_dir)
    info = read_info(layer_dir)
    for key in REQUIRED_INFO:
        if key not in info:
            raise ValueError("info.json is missing " + key)

    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    # Keep the multi-megabyte erofs image next to the output: /tmp is often a
    # small tmpfs, and it also avoids a cross-device copy.
    erofs = "{}.{}.erofs".format(output, os.getpid())
    try:
        _mkfs(erofs, layer_dir)
        partial = output + ".partial"
        with open(partial, "wb") as out, open(erofs, "rb") as payload:
            out.write(MAGIC)
            out.write(struct.pack("<I", len(meta)))
            out.write(meta)
            shutil.copyfileobj(payload, out, 1 << 20)
        os.replace(partial, output)
    finally:
        try:
            os.unlink(erofs)
        except OSError:
            pass
    return output


def verify(path, extract_to=None):
    """Check magic, meta and that the erofs payload can be unpacked."""
    with open(path, "rb") as stream:
        header = stream.read(44)
        if len(header) < 44 or not header.startswith(MAGIC.rstrip(b"\0")):
            raise ValueError("magic mismatch")
        length = struct.unpack("<I", header[40:44])[0]
        meta = json.loads(stream.read(length).decode("utf-8"))
        if not isinstance(meta, dict) or "version" not in meta or "info" not in meta:
            raise ValueError('meta must be {"version": "...", "info": {...}}')
        info = meta["info"]
        for key in REQUIRED_INFO:
            if key not in info:
                raise ValueError("meta info is missing " + key)

        workdir = extract_to or tempfile.mkdtemp(
            prefix="linglong-verify-", dir=os.path.dirname(os.path.abspath(path)))
        os.makedirs(workdir, exist_ok=True)
        erofs = os.path.join(workdir, "payload.erofs")
        with open(erofs, "wb") as payload:
            shutil.copyfileobj(stream, payload, 1 << 20)
    root = os.path.join(workdir, "root")
    result = subprocess.run(["fsck.erofs", "--extract=" + root, erofs],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = result.stdout.decode("utf-8", "replace").strip()
    if result.returncode != 0:
        raise ValueError("erofs payload is unreadable: " + output[:400])
    app_files = os.path.join(root, "files")
    if not os.path.isdir(app_files):
        raise ValueError("layer has no files/ directory")
    entry = info["command"][0]
    # command points inside the container; the matching path in the layer is
    # files/<rest after /opt/apps/<id>/files>.
    prefix = "/opt/apps/" + info["id"] + "/files/"
    if not entry.startswith(prefix):
        raise ValueError("command must live under " + prefix)
    expected = os.path.join(app_files, entry[len(prefix):])
    if not os.path.isfile(expected):
        raise ValueError("command target is missing: " + os.path.relpath(expected, root))
    if extract_to is None:
        shutil.rmtree(workdir, ignore_errors=True)
    return info


def main(argv):
    if len(argv) == 3 and argv[1] == "--verify":
        info = verify(argv[2])
        print("layer ok: {} {} ({})".format(info["id"], info["version"], info["base"]))
        return 0
    if len(argv) == 3:
        build(argv[1], argv[2])
        info = verify(argv[2])
        print("layer: {} ({} bytes)".format(argv[2], os.path.getsize(argv[2])))
        print("  {} {} base={}".format(info["id"], info["version"], info["base"]))
        return 0
    sys.stderr.write("usage: pack_layer.py <layer-dir> <output.layer>\n"
                     "       pack_layer.py --verify <file.layer>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
