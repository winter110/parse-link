"""Keep the lockfile on the same hosted source the CI job pins.

`flutter pub get` writes the hosted URL of every package into `pubspec.lock`.
Generate the lockfile behind a China mirror (`PUB_HOSTED_URL=https://pub.flutter-io.cn`)
and that mirror ends up in the file; CI pins `PUB_HOSTED_URL=https://pub.dev`, so
`flutter pub get --enforce-lockfile` then reports

    Would change 1 dependency.
    Unable to satisfy `pubspec.yaml` using `pubspec.lock`.

even though every version is identical -- only the recorded source differs. The
failure message lists the packages that merely have newer versions available
(`record_use 0.6.0 (1.1.1 available)`, and 42 more), which sends the reader after
the wrong package. It has happened twice: once in the 10-28 lockfile cleanup and
again on the `pinyin` entry, so it is checked here instead of by eye.
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / 'pubspec.lock'

# Hosted sources that are mirrors of pub.dev. A lockfile pinned to any of them
# fails the CI job that sets PUB_HOSTED_URL to https://pub.dev.
MIRROR_HOSTS = (
    'pub.flutter-io.cn',
    'pub-web.flutter-io.cn',
    'pub.dartlang.org',
    'mirrors.tuna.tsinghua.edu.cn',
    'mirrors.cloud.tencent.com',
    'mirrors.aliyun.com',
)


class LockfileHostedSourceTest(unittest.TestCase):
    def test_lockfile_does_not_record_a_mirror(self):
        text = LOCK.read_text(encoding='utf-8')
        offenders = [
            '  line {}: {}'.format(number, line.strip())
            for number, line in enumerate(text.splitlines(), 1)
            if any(host in line for host in MIRROR_HOSTS)
        ]
        self.assertEqual(
            [],
            offenders,
            '\n'.join([
                'pubspec.lock records a mirror instead of the hosted source CI pins.',
                'Regenerate it where PUB_HOSTED_URL is unset (or set to https://pub.dev):',
                '  env -u PUB_HOSTED_URL flutter pub get',
                *offenders,
            ]),
        )


if __name__ == '__main__':
    unittest.main()
