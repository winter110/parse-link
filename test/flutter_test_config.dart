import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/platform/login_browser.dart';

/// Runs before every test file under `test/`.
///
/// The backup/recovery tests create and restore dozens of envelopes, and a
/// single real 210000-round PBKDF2 derivation costs seconds of CPU here and
/// tens of seconds on a CI runner. That made every crypto test hit the 30 s
/// per-test timeout (and the checks job hit its own limit) even though the
/// envelope cost is not what any of them assert: they only use it as a carrier
/// for the behaviour under test. Shipped builds keep the real cost through
/// [CryptoBox.productionRounds]; this override is stripped from release builds
/// together with the assert that reads it.
Future<void> testExecutable(Future<void> Function() testMain) async {
  CryptoBox.testingRounds = 2000;
  // The Linux login window is a native GTK window driven through a plugin that
  // only exists in a real build. Login tests install a fake
  // InAppWebViewPlatform instead, so they must keep taking the embedded path
  // even though the test host is Linux.
  overrideLoginBrowserDetached(false);
  await testMain();
}
