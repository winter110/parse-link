#!/usr/bin/env python3
"""Build the Linux release packages from a Flutter Linux bundle.

Two artefacts are produced from the same `build/linux/x64/release/bundle`:

* a Debian package that installs to /opt/asterlink (system libraries are used,
  the dependency list is derived from the bundle's DT_NEEDED entries);
* a Linglong (如意玲珑) layer that is self-contained: every library the bundle
  needs but the pinned base layer does not provide is copied into files/lib.

Usage:
    tool/package_linux.py deb   [--output PATH]
    tool/package_linux.py layer [--output PATH]
    tool/package_linux.py verify --deb PATH --layer PATH
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "build/linux/x64/release/bundle"
LOCAL = ROOT / ".local" / "linux"
SCRATCH = ROOT / ".local" / "linux-scratch"
BASE_LIBS = ROOT / "tool/linglong/base-libs.txt"
PACK_LAYER = ROOT / "tool/linglong/pack_layer.py"

APP_ID = "com.asterlink.app"
APP_NAME = "asterlink"
APP_TITLE = "文析助手"
BASE_REF = "org.deepin.base/25.2.2"
ICON_SOURCE = ROOT / "assets/icons/app.png"

# Loader internals are never shipped: they have to match the process that
# starts the container, not the machine that built it.
SKIP_SONAMES = {"linux-vdso.so.1", "linux-gate.so.1"}
LOADER_PREFIXES = ("ld-linux", "ld64.so")
SKIP_PREFIXES = LOADER_PREFIXES + (
    "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1",
    "libresolv.so.2", "libnsl.so")

# The base layer ships GLib 2.80 while the build machine has a newer one.
# GLib is ABI-stable, and libraries such as libsecret are linked against the
# newer symbols (g_variant_builder_init_static appeared after 2.80), so the
# bundled copy always wins over the base copy.  GTK 3 from the base layer keeps
# working against the newer GLib.
ALWAYS_BUNDLE = {
    "libglib-2.0.so.0", "libgio-2.0.so.0", "libgobject-2.0.so.0",
    "libgmodule-2.0.so.0", "libgthread-2.0.so.0",
}

# The base layer ships GLib 2.80 while the build machine has a newer one.
# GLib is ABI-stable, and libraries such as libsecret are linked against the
# newer symbols (g_variant_builder_init_static appeared after 2.80), so the
# bundled copy always wins over the base copy.  GTK 3 from the base layer keeps
# working against the newer GLib.
ALWAYS_BUNDLE = {
    "libglib-2.0.so.0", "libgio-2.0.so.0", "libgobject-2.0.so.0",
    "libgmodule-2.0.so.0", "libgthread-2.0.so.0",
}

# `libdartjni.so` belongs to package:jni, which is only used on Android.  It is
# linked against libjvm, and pulling a JVM into the layer (or asking users to
# install one) would be wrong, so the closure walk skips it.
SKIP_WALK = {"libdartjni.so"}

# soname -> Debian binary package on Deepin 25 (Debian trixie, amd64).  Only the
# libraries the shipped ELF files link directly are listed; unknown entries are
# reported as warnings instead of silently producing an uninstallable package.
SONAME_PACKAGES = {
    "libc.so.6": "libc6",
    "libm.so.6": "libc6",
    "libdl.so.2": "libc6",
    "libpthread.so.0": "libc6",
    "librt.so.1": "libc6",
    "libgcc_s.so.1": "libgcc-s1",
    "libstdc++.so.6": "libstdc++6",
    "libz.so.1": "zlib1g",
    "libgtk-3.so.0": "libgtk-3-0",
    "libgdk-3.so.0": "libgtk-3-0",
    "libatk-1.0.so.0": "libatk1.0-0",
    "libatk-bridge-2.0.so.0": "libatk-bridge2.0-0",
    "libcairo.so.2": "libcairo2",
    "libcairo-gobject.so.2": "libcairo-gobject2",
    "libpango-1.0.so.0": "libpango-1.0-0",
    "libpangocairo-1.0.so.0": "libpangocairo-1.0-0",
    "libgdk_pixbuf-2.0.so.0": "libgdk-pixbuf-2.0-0",
    "libharfbuzz.so.0": "libharfbuzz0b",
    "libfontconfig.so.1": "libfontconfig1",
    "libglib-2.0.so.0": "libglib2.0-0",
    "libgio-2.0.so.0": "libglib2.0-0",
    "libgobject-2.0.so.0": "libglib2.0-0",
    "libepoxy.so.0": "libepoxy0",
    "libsecret-1.so.0": "libsecret-1-0",
    "libjsoncpp.so.25": "libjsoncpp25",
    "libayatana-appindicator3.so.1": "libayatana-appindicator3-1",
    "libayatana-indicator3.so.7": "libayatana-indicator3-7",
    "libayatana-ido3-0.4.so.0": "libayatana-ido3-0.4-0",
    "libdbusmenu-glib.so.4": "libdbusmenu-glib4",
    "libdbusmenu-gtk3.so.4": "libdbusmenu-gtk3-4",
    "libmpv.so.2": "libmpv2",
    # Linux web login window (vendor_plugins/asterlink_webview_linux).
    "libwebkit2gtk-4.1.so.0": "libwebkit2gtk-4.1-0",
    "libjavascriptcoregtk-4.1.so.0": "libjavascriptcoregtk-4.1-0",
    "libsoup-3.0.so.0": "libsoup-3.0-0",
    "libjvm.so": None,  # package:jni, Android only
}

DEB_MAINTAINER = "AsterLink build <noreply@asterlink.app>"
DEB_DESCRIPTION = (
    "AsterLink (文析助手) parses netdisk share links and downloads the files.\n"
    " Supports 15 netdisk providers with share links and extraction codes, direct\n"
    " link extraction, multi-account management, a unified download queue\n"
    " (HTTP/HTTPS/magnet/BitTorrent), online playback and LAN transfer."
)


class BuildError(RuntimeError):
    pass


def project_version():
    """Return (upstream, build) from pubspec.yaml, e.g. ("2.0.0", 200)."""
    text = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", text, re.M)
    if not match:
        raise BuildError("pubspec.yaml has no version of the form X.Y.Z+N")
    return match.group(1), int(match.group(2))


def scratch(prefix):
    """Temporary tree on the project disk; /tmp is a tiny tmpfs on some systems."""
    SCRATCH.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=prefix, dir=str(SCRATCH)))


def require_bundle():
    for name in ("asterlink", "lib/libapp.so", "lib/libflutter_linux_gtk.so",
                 "data/flutter_assets/AssetManifest.bin"):
        if not (BUNDLE / name).is_file():
            raise BuildError("the Linux bundle is incomplete: missing " + name)
    if not (BUNDLE / "asterlink_gopeed").is_file():
        raise BuildError("the download helper is missing from the bundle")
    return BUNDLE


def run(command, **kwargs):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
    if result.returncode != 0:
        raise BuildError("{} failed:\n{}".format(
            " ".join(str(part) for part in command),
            result.stdout.decode("utf-8", "replace").strip()[:2000]))
    return result.stdout.decode("utf-8", "replace")


def is_elf(path):
    try:
        with open(path, "rb") as stream:
            return stream.read(4) == b"\x7fELF"
    except OSError:
        return False


def needed_sonames(path):
    output = run(["readelf", "-d", str(path)])
    return re.findall(r"\(NEEDED\).*\[(.+?)\]", output)


def base_sonames():
    if not BASE_LIBS.is_file():
        raise BuildError("missing " + str(BASE_LIBS.relative_to(ROOT)))
    names = set()
    for line in BASE_LIBS.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.add(line)
    return names


def collect_runtime_libs(files_dir, base):
    """Copy every library the bundle needs that the base layer does not provide."""
    lib_dir = files_dir / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    shipped = {path.name for path in lib_dir.iterdir() if path.is_file()}
    queue = [path for path in files_dir.rglob("*") if path.is_file() and is_elf(path)]
    seen = set()
    copied = []
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = str(lib_dir) + (
        ":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")

    while queue:
        current = queue.pop()
        if current.name in seen or current.name in SKIP_WALK:
            continue
        seen.add(current.name)
        for line in ldd(current, env):
            soname = line[0]
            target = line[1]
            if soname in SKIP_SONAMES or soname.startswith(SKIP_PREFIXES):
                continue
            if soname in shipped:
                continue
            if soname in base and soname not in ALWAYS_BUNDLE:
                continue
            if not target or target == "not found":
                raise BuildError("{} needs {}, which is not installed on this machine".format(
                    current.name, soname))
            destination = lib_dir / soname
            if not destination.exists():
                shutil.copy2(target, destination)
                copied.append(soname)
                shipped.add(soname)
            queue.append(destination)
    return sorted(copied)


def check_closure(files_dir, base):
    """Every DT_NEEDED of a shipped ELF must be bundled or provided by the base."""
    bundled = {path.name for path in (files_dir / "lib").iterdir() if path.is_file()}
    problems = []
    for path in sorted(files_dir.rglob("*")):
        if not path.is_file() or path.is_symlink() or not is_elf(path):
            continue
        if path.name in SKIP_WALK:
            continue
        for soname in needed_sonames(path):
            if soname in bundled or soname in base:
                continue
            if soname in SKIP_SONAMES or soname.startswith(LOADER_PREFIXES):
                continue
            problems.append("{} needs {}".format(path.name, soname))
    if problems:
        raise BuildError("the layer would not start; missing libraries:\n  "
                         + "\n  ".join(sorted(set(problems))))


def ldd(path, env):
    output = subprocess.run(["ldd", str(path)], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT).stdout.decode("utf-8", "replace")
    for line in output.splitlines():
        parts = line.replace("\t", " ").split()
        if "=>" in parts:
            index = parts.index("=>")
            soname = parts[index - 1]
            target = parts[index + 1] if index + 1 < len(parts) else ""
            yield soname, target
        elif len(parts) == 1 and ".so" in parts[0]:
            yield parts[0], ""


def launcher_script():
    return """#!/bin/bash
# Linglong entry point: prefer the libraries shipped next to the app.
APP_DIR=/opt/apps/{app_id}/files
export LD_LIBRARY_PATH="$APP_DIR/lib${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}"
cd "$APP_DIR" || exit 1
exec "$APP_DIR/{name}" "$@"
""".format(app_id=APP_ID, name=APP_NAME)


DESKTOP_ENTRY = """[Desktop Entry]
Type=Application
Name={title}
Name[en]=AsterLink
GenericName=Netdisk parser and downloader
Comment=Parse netdisk share links and download the files directly
Comment[zh_CN]=解析网盘分享链接并直接下载，也可管理网盘与设备互传
Exec={exec_line}
Icon={icon}
Terminal=false
Categories=Network;FileTransfer;
Keywords=netdisk;pan;download;网盘;解析;下载;
StartupWMClass={app_id}
{extra}"""


def stage_tree(files_dir):
    """Copy the Flutter bundle into files/ and keep the helper executable."""
    for item in BUNDLE.iterdir():
        target = files_dir / item.name
        if item.is_dir():
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)
    helper = files_dir / "asterlink_gopeed"
    if not helper.is_file():
        built = ROOT / "native/bin/asterlink_gopeed"
        if not built.is_file():
            raise BuildError("build native/bin/asterlink_gopeed before packaging")
        shutil.copy2(built, helper)
    helper.chmod(0o755)
    (files_dir / APP_NAME).chmod(0o755)


def normalize_modes(root, executables=()):
    """Give the tree reproducible 0755/0644 modes regardless of the local umask."""
    for current, directories, names in os.walk(root):
        os.chmod(current, 0o755)
        for name in directories:
            os.chmod(os.path.join(current, name), 0o755)
        for name in names:
            path = os.path.join(current, name)
            if not os.path.islink(path):
                os.chmod(path, 0o644)
    for relative in executables:
        path = root / relative
        if path.exists():
            os.chmod(path, 0o755)


def write_icon(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ICON_SOURCE, path)


def build_deb(output):
    require_bundle()
    upstream, build = project_version()
    version = "{}+{}".format(upstream, build)
    tree = scratch("deb-")
    try:
        app_dir = tree / "opt" / APP_NAME
        app_dir.mkdir(parents=True)
        stage_tree(app_dir)
        (tree / "usr/bin").mkdir(parents=True, exist_ok=True)

        binary = tree / "usr" / "bin" / APP_NAME
        os.symlink("/opt/{}/{}".format(APP_NAME, APP_NAME), binary)

        entry = tree / "usr/share/applications" / (APP_NAME + ".desktop")
        entry.parent.mkdir(parents=True, exist_ok=True)
        entry.write_text(DESKTOP_ENTRY.format(
            title=APP_TITLE,
            exec_line="/opt/{}/{} %U".format(APP_NAME, APP_NAME),
            icon=APP_NAME, app_id=APP_ID, extra=""), encoding="utf-8")
        write_icon(tree / "usr/share/icons/hicolor/512x512/apps" / (APP_NAME + ".png"))

        doc_dir = tree / "usr/share/doc" / APP_NAME
        doc_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "LICENSE", doc_dir / "copyright")
        (doc_dir / "changelog.Debian").write_text(
            "{name} ({version}) unstable; urgency=medium\n\n"
            "  * Linux (amd64) build of AsterLink {upstream}.\n\n"
            " -- {maintainer}  {date}\n".format(
                name=APP_NAME, version=version, upstream=upstream,
                maintainer=DEB_MAINTAINER,
                date=subprocess.run(["date", "-R"], stdout=subprocess.PIPE).stdout
                .decode().strip()),
            encoding="utf-8")

        normalize_modes(tree, ("opt/asterlink/asterlink", "opt/asterlink/asterlink_gopeed"))

        normalize_modes(tree, ("opt/asterlink/asterlink", "opt/asterlink/asterlink_gopeed"))

        depends, unknown = deb_depends(app_dir)
        if unknown:
            sys.stderr.write("warning: no package mapping for {}\n".format(", ".join(unknown)))
        installed_size = 0
        for root, _dirs, names in os.walk(tree):
            for name in names:
                path = os.path.join(root, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                installed_size += os.lstat(path).st_size
        fields = [
            "Package: " + APP_NAME,
            "Version: " + version,
            "Section: net",
            "Priority: optional",
            "Architecture: amd64",
            "Installed-Size: " + str((installed_size + 1023) // 1024),
            "Depends: " + ", ".join(depends),
            "Maintainer: " + DEB_MAINTAINER,
        ]
        repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
        if repository:
            fields.append("Homepage: https://github.com/" + repository)
        fields.append("Description: " + DEB_DESCRIPTION)
        control = tree / "DEBIAN"
        control.mkdir()
        (control / "control").write_text("\n".join(fields + [""]), encoding="utf-8")
        (control / "postinst").write_text(
            "#!/bin/sh\nset -e\n"
            "if [ \"$1\" = configure ]; then\n"
            "  command -v update-desktop-database >/dev/null 2>&1 && "
            "update-desktop-database -q /usr/share/applications || true\n"
            "  command -v gtk-update-icon-cache >/dev/null 2>&1 && "
            "gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true\n"
            "fi\nexit 0\n", encoding="utf-8")
        (control / "postrm").write_text(
            "#!/bin/sh\nset -e\n"
            "if [ \"$1\" = remove ] || [ \"$1\" = purge ]; then\n"
            "  command -v update-desktop-database >/dev/null 2>&1 && "
            "update-desktop-database -q /usr/share/applications || true\n"
            "fi\nexit 0\n", encoding="utf-8")
        for script in ("postinst", "postrm"):
            (control / script).chmod(0o755)

        output.parent.mkdir(parents=True, exist_ok=True)
        partial = output.parent / (output.name + ".partial")
        run(["dpkg-deb", "--build", "--root-owner-group", str(tree), str(partial)])
        os.replace(partial, output)
        return output
    finally:
        shutil.rmtree(tree, ignore_errors=True)


def deb_depends(app_dir):
    packages = []
    unknown = []
    for path in sorted(app_dir.rglob("*")):
        if not path.is_file() or path.is_symlink() or not is_elf(path):
            continue
        for soname in needed_sonames(path):
            if soname.startswith(LOADER_PREFIXES) or (app_dir / "lib" / soname).is_file():
                continue  # shipped in the bundle, or resolved by the loader itself
            if soname not in SONAME_PACKAGES:
                unknown.append(soname)
                continue
            package = SONAME_PACKAGES[soname]
            if package and package not in packages:
                packages.append(package)
    preferred = ["libc6", "libstdc++6", "libgcc-s1", "libgtk-3-0", "libmpv2"]
    ordered = [name for name in preferred if name in packages]
    ordered += [name for name in packages if name not in ordered]
    return ordered, sorted(set(unknown))


def build_layer(output):
    require_bundle()
    base = base_sonames()
    upstream, build = project_version()
    version = "{}.{}".format(upstream, build)
    stage = scratch("layer-")
    try:
        layer = stage / "layer"
        files = layer / "files"
        files.mkdir(parents=True)
        stage_tree(files)
        copied = collect_runtime_libs(files, base)

        launcher = files / "bin" / APP_NAME
        launcher.parent.mkdir(parents=True, exist_ok=True)
        launcher.write_text(launcher_script(), encoding="utf-8")
        launcher.chmod(0o755)

        entry_dir = layer / "entries/share/applications"
        entry_dir.mkdir(parents=True, exist_ok=True)
        (entry_dir / (APP_ID + ".desktop")).write_text(DESKTOP_ENTRY.format(
            title=APP_TITLE,
            exec_line="/usr/bin/ll-cli run " + APP_ID,
            icon=APP_ID, app_id=APP_ID,
            extra="X-linglong=" + APP_ID), encoding="utf-8")
        write_icon(layer / "entries/share/icons/hicolor/512x512/apps" / (APP_ID + ".png"))

        check_closure(files, base)
        check_closure(files, base)
        normalize_modes(layer, ("files/asterlink", "files/asterlink_gopeed",
                                "files/bin/asterlink"))

        check_closure(files, base)
        check_closure(files, base)
        normalize_modes(layer, ("files/asterlink", "files/asterlink_gopeed",
                                "files/bin/asterlink"))

        size = 0
        for root, _dirs, names in os.walk(files):
            for name in names:
                try:
                    size += os.lstat(os.path.join(root, name)).st_size
                except OSError:
                    pass
        info = {
            "arch": ["x86_64"],
            "base": BASE_REF,
            "channel": "main",
            "command": ["/opt/apps/{}/files/bin/{}".format(APP_ID, APP_NAME)],
            "description": "解析网盘分享链接并提取直链下载，内置下载内核（HTTP/HTTPS/磁力/BT）。",
            "id": APP_ID,
            "kind": "app",
            "module": "binary",
            "name": APP_TITLE,
            "schema_version": "1.0",
            "size": size,
            "version": version,
        }
        # An empty "permissions" object makes the package manager reject the
        # layer while parsing, so the key is omitted entirely.
        (layer / "info.json").write_text(
            json.dumps(info, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        (layer / "linglong.yaml").write_text(
            "version: \"1\"\n\n"
            "package:\n"
            "  id: {app_id}\n"
            "  name: {name}\n"
            "  version: {version}\n"
            "  kind: app\n"
            "  description: |\n"
            "    解析网盘分享链接并提取直链下载。\n\n"
            "command:\n"
            "  - /opt/apps/{app_id}/files/bin/{name}\n\n"
            "base: {base_ref}\n\n"
            "modules:\n"
            "  - name: binary\n"
            "    files:\n"
            "      - /\n".format(app_id=APP_ID, name=APP_NAME, version=version,
                              base_ref=BASE_REF),
            encoding="utf-8")

        output.parent.mkdir(parents=True, exist_ok=True)
        python = sys.executable or "python3"
        run([python, str(PACK_LAYER), str(layer), str(output)])
        print("bundled {} libraries not provided by {}".format(len(copied), BASE_REF))
        return output
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def verify_layer(layer_path):
    python = sys.executable or "python3"
    output = run([python, str(PACK_LAYER), "--verify", str(layer_path)])
    print(output.strip())


def deb_contents(path):
    output = run(["dpkg-deb", "--contents", str(path)])
    return output


def verify_packages(deb, layer):
    if deb:
        contents = deb_contents(deb)
        for expected in ("/opt/{0}/{0}".format(APP_NAME),
                         "/opt/{}/asterlink_gopeed".format(APP_NAME),
                         "/opt/{}/lib/libapp.so".format(APP_NAME)):
            if expected not in contents:
                raise BuildError("{} is missing {}".format(deb.name, expected))
        fields = run(["dpkg-deb", "--field", str(deb)])
        if "Architecture: amd64" not in fields or "Depends: " not in fields:
            raise BuildError("the control file is incomplete")
        print("deb ok: {} ({:.1f} MB)".format(deb.name, deb.stat().st_size / 1048576))
    if layer:
        verify_layer(layer)
        print("layer ok: {} ({:.1f} MB)".format(layer.name, layer.stat().st_size / 1048576))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("deb", "layer"):
        item = sub.add_parser(name)
        item.add_argument("--output")
    check = sub.add_parser("verify")
    check.add_argument("--deb")
    check.add_argument("--layer")
    args = parser.parse_args(argv)

    upstream, build = project_version()
    deb_default = LOCAL / "asterlink_{}+{}_amd64.deb".format(upstream, build)
    layer_default = LOCAL / "asterlink_{}.{}_x86_64_binary.layer".format(upstream, build)
    try:
        if args.command == "deb":
            build_deb(Path(args.output) if args.output else deb_default)
        elif args.command == "layer":
            build_layer(Path(args.output) if args.output else layer_default)
        else:
            verify_packages(Path(args.deb) if args.deb else None,
                            Path(args.layer) if args.layer else None)
    except BuildError as error:
        parser.exit(1, str(error) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
