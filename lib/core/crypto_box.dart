import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'json.dart';

class CryptoBox {
  /// PBKDF2 cost (in rounds) of every envelope this build writes: backups and
  /// the local password-recovery file. It is stored next to the salt, so
  /// readers always use the cost they find in the file.
  static const int productionRounds = 210000;

  /// Test-suite override for [envelopeRounds]. Reading it only inside an
  /// `assert` keeps release builds at [productionRounds]: the assert body is
  /// stripped, so this field can never lower the cost of a shipped build.
  ///
  /// The value cannot live in a static alone - `compute` starts a fresh
  /// isolate with empty statics - so callers read [envelopeRounds] in the
  /// calling isolate and hand it to the worker as part of the message.
  static int? _testingRounds;

  @visibleForTesting
  static set testingRounds(int? value) => _testingRounds = value;

  static int get envelopeRounds {
    var value = productionRounds;
    assert(() {
      value = _testingRounds ?? productionRounds;
      return true;
    }());
    return value;
  }

  static Uint8List random(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  static Uint8List seal(Uint8List key, List<int> plain, {Uint8List? iv}) {
    final nonce = iv ?? random(12);
    require(key.length == 32 && nonce.length == 12, '加密参数无效');
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    return Uint8List.fromList([
      ...nonce,
      ...cipher.process(Uint8List.fromList(plain)),
    ]);
  }

  static Uint8List open(Uint8List key, List<int> packed) {
    require(key.length == 32 && packed.length >= 28, '加密数据格式错误');
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          128,
          Uint8List.fromList(packed.sublist(0, 12)),
          Uint8List(0),
        ),
      );
    try {
      return cipher.process(Uint8List.fromList(packed.sublist(12)));
    } on InvalidCipherTextException {
      throw const AppException('密码错误或加密数据已损坏');
    }
  }

  /// Derives a key with the round count recorded in the envelope it will be
  /// used for. The bounds only reject values that cannot work at all: writers
  /// always pass [envelopeRounds], while readers must accept whatever an older
  /// build (or a fixture) wrote, and a hostile high count is a denial of
  /// service rather than a shortcut.
  static Uint8List derive(String password, Uint8List salt, int rounds) {
    require(
      rounds >= 1 &&
          rounds <= 2000000 &&
          salt.length >= 16 &&
          salt.length <= 64,
      '备份密钥参数无效',
    );
    final bytes = Uint8List.fromList(utf8.encode(password));
    try {
      final generator = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
        ..init(Pbkdf2Parameters(salt, rounds, 32));
      return generator.process(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Uint8List aesCbc(
    bool encrypt,
    List<int> data,
    List<int> key,
    List<int> iv,
  ) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            encrypt,
            PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
              ParametersWithIV(
                KeyParameter(Uint8List.fromList(key)),
                Uint8List.fromList(iv),
              ),
              null,
            ),
          );
    return cipher.process(Uint8List.fromList(data));
  }
}
