#!/usr/bin/env python3
"""Print the --dart-define arguments for a desktop build, one per line.

Mirrors the Windows/Android build scripts (tool/build-common.ps1) so the Linux
package embeds exactly the same control URL, repository and announcements URL.
Optional private define files are passed through when they exist locally; they
are never required, and CI never has them.
"""
import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import urljoin, urlparse

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = ("controlEnabled", "controlUrl", "githubRepository", "applicationId",
            "metricsAppKey", "metricsChannel")
PRIVATE_DEFINE_FILES = (".local/baidu-api.defines.json",
                        ".local/parser-hub.defines.json",
                        ".local/cloud-command.defines.json")
REPOSITORY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$")
APPLICATION_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$")
CHANNEL = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


def https_url(value, name):
    if not value:
        return
    if (not value.startswith("https://") or re.search(r"[\s\x00-\x1f\x7f\\]", value)
            or value.rstrip() != value or len(value) > 2048):
        raise ValueError(name + " must be a plain HTTPS URL")


def load(path):
    if not path.is_file():
        raise ValueError("build config not found: " + str(path))
    settings = json.loads(path.read_text(encoding="utf-8"))
    missing = [key for key in REQUIRED if key not in settings]
    if missing:
        raise ValueError("build config is missing " + ", ".join(missing))
    if not isinstance(settings["controlEnabled"], bool):
        raise ValueError("controlEnabled must be a JSON boolean")
    for key in ("controlUrl", "githubRepository", "applicationId", "metricsAppKey", "metricsChannel"):
        if not isinstance(settings[key], str):
            raise ValueError(key + " must be a string")
        settings[key] = settings[key].strip()
    if settings["controlEnabled"]:
        https_url(settings["controlUrl"], "controlUrl")
        if not settings["controlUrl"]:
            raise ValueError("controlUrl is required when control is enabled")
    if settings["githubRepository"] and not REPOSITORY.match(settings["githubRepository"]):
        raise ValueError("githubRepository must be empty or owner/repository")
    if not APPLICATION_ID.match(settings["applicationId"]):
        raise ValueError("applicationId is not a valid identifier")
    if settings["metricsAppKey"] and not re.fullmatch(r"[0-9a-fA-F]{24}", settings["metricsAppKey"]):
        raise ValueError("metricsAppKey must be empty or 24 hex characters")
    if not CHANNEL.match(settings["metricsChannel"]):
        raise ValueError("metricsChannel is not valid")
    announcements = settings.get("announcementsUrl", "")
    if not isinstance(announcements, str):
        raise ValueError("announcementsUrl must be a string")
    announcements = announcements.strip()
    if not announcements and settings["controlEnabled"]:
        control = urlparse(settings["controlUrl"])
        if not control.query and control.path.lower().endswith(".json"):
            announcements = urljoin(settings["controlUrl"], "announcements.json")
    https_url(announcements, "announcementsUrl")
    settings["announcementsUrl"] = announcements
    return settings


def arguments(settings):
    yield "--dart-define=ASTERLINK_ANNOUNCEMENTS_URL=" + settings["announcementsUrl"]
    yield "--dart-define=ASTERLINK_CONTROL_ENABLED=" + str(settings["controlEnabled"]).lower()
    yield "--dart-define=ASTERLINK_CONTROL_URL=" + settings["controlUrl"]
    yield "--dart-define=ASTERLINK_GITHUB_REPO=" + settings["githubRepository"]
    for relative in PRIVATE_DEFINE_FILES:
        path = ROOT / relative
        if path.is_file():
            json.loads(path.read_text(encoding="utf-8"))
            yield "--dart-define-from-file=" + str(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--build-config")
    args = parser.parse_args()
    default = ROOT / ".local/build-config.json"
    if not args.build_config and not default.is_file():
        default = ROOT / "config/build.community.json"
    try:
        settings = load(Path(args.build_config) if args.build_config else default)
    except (ValueError, OSError) as error:
        sys.stderr.write(str(error) + "\n")
        return 1
    for item in arguments(settings):
        print(item)
    return 0


if __name__ == "__main__":
    sys.exit(main())
