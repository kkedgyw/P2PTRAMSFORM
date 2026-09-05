import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 端到端加密：口令 → PBKDF2-HMAC-SHA256 → AES-256-GCM
///
/// 用途：文件可能经过不可信通道（虚拟组网的中继节点、异地公网链路），
/// 加一层端到端加密后，中转方只能看到密文。
///
/// 密钥派生：两端约定同一个口令（房间码），发送端随机生成 salt 并随文件清单
/// 一起发给对端，双方各自派生出相同的 AES-256 密钥。
///
/// 每个分块独立做 GCM 加密并自带认证标签，因此：
/// - 可以流式处理任意大小的文件，不需要把整个文件读进内存
/// - 任一块被篡改会当场认证失败，不会写出被污染的文件
///
/// 流格式：
///   header : "P2PE"(4) + version(1)
///   chunk  : uint32 BE(len) + nonce(12) + cipherText + mac(16)
///            len = nonce + cipherText + mac 的总长度
class TransferCrypto {
  static const int _version = 1;
  static const int _saltLength = 16;
  static const int _nonceLength = 12;

  /// AES-GCM 的认证标签固定 16 字节
  static const int _macLength = 16;

  /// 明文分块大小。每块会额外产生 12+16+4 = 32 字节开销
  static const int chunkSize = 64 * 1024;

  /// PBKDF2 迭代次数。纯 Dart 实现下约几百毫秒，多文件传输时每个文件
  /// 只派生一次（同一会话共用 salt），所以开销可控。
  /// 注意：安全性的决定性因素是口令强度，迭代数只是抬高离线爆破成本。
  static const int _pbkdf2Iterations = 50000;

  /// 流头部魔数 "P2PE"
  static const List<int> magic = [0x50, 0x32, 0x50, 0x45];

  static final AesGcm _algorithm = AesGcm.with256bits();
  static final Random _random = Random.secure();

  final SecretKey _key;

  /// 盐值。发送端生成后要随文件清单发给对端，否则对端派生不出同一把密钥
  final Uint8List salt;

  TransferCrypto._(this._key, this.salt);

  /// 发送端：随机生成 salt
  static Future<TransferCrypto> create(String passphrase) =>
      fromSalt(passphrase, _randomBytes(_saltLength));

  /// 用给定 salt 派生密钥（收发两端都走这里，得到同一把密钥）
  static Future<TransferCrypto> fromSalt(
      String passphrase, List<int> salt) async {
    final pbkdf2 = Pbkdf2.hmacSha256(
      iterations: _pbkdf2Iterations,
      bits: 256,
    );
    final key = await pbkdf2.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
    return TransferCrypto._(key, Uint8List.fromList(salt));
  }

  /// 从对端传来的 base64 盐值恢复
  static Future<TransferCrypto> fromSaltBase64(
          String passphrase, String saltBase64) =>
      fromSalt(passphrase, base64Decode(saltBase64));

  String get saltBase64 => base64Encode(salt);

  // ------------------------------------------------------------ 文件名

  /// 文件名同样加密 —— 文件名本身也常常包含敏感信息
  Future<String> encryptName(String name) async {
    final box = await _algorithm.encrypt(utf8.encode(name), secretKey: _key);
    return base64Encode(_packBox(box));
  }

  Future<String> decryptName(String encoded) async {
    final box = _unpackBox(base64Decode(encoded));
    final clear = await _algorithm.decrypt(box, secretKey: _key);
    return utf8.decode(clear);
  }

  // ------------------------------------------------------------ 文件流

  /// 明文流 → 密文流（开头带 5 字节 header）
  Stream<List<int>> encrypt(Stream<List<int>> source) async* {
    yield <int>[...magic, _version];
    await for (final block in _rechunk(source, chunkSize)) {
      final box = await _algorithm.encrypt(block, secretKey: _key);
      final payload = _packBox(box);
      yield <int>[..._uint32(payload.length), ...payload];
    }
  }

  /// 密文流 → 明文流。header 不匹配会直接抛异常，交给调用方提示用户
  Stream<List<int>> decrypt(Stream<List<int>> source) async* {
    final reader = _StreamReader(source);

    final header = await reader.take(5);
    if (header.length < 5) {
      throw const FormatException('加密流不完整（读不到文件头）');
    }
    for (var i = 0; i < magic.length; i++) {
      if (header[i] != magic[i]) {
        throw const FormatException('收到的数据不是本应用的加密流');
      }
    }
    if (header[4] != _version) {
      throw FormatException('不支持的加密版本: ${header[4]}');
    }

    while (true) {
      final lenBytes = await reader.take(4);
      if (lenBytes.isEmpty) break; // 正常结束
      if (lenBytes.length < 4) {
        throw const FormatException('加密流被截断（长度字段不完整）');
      }
      final len = _readUint32(lenBytes);
      if (len <= _nonceLength + _macLength || len > 16 * 1024 * 1024) {
        throw FormatException('加密块长度异常: $len');
      }
      final payload = await reader.take(len);
      if (payload.length < len) {
        throw const FormatException('加密流被截断（数据不完整）');
      }
      final box = _unpackBox(payload);
      yield await _algorithm.decrypt(box, secretKey: _key);
    }
  }

  // ------------------------------------------------------------ 编解码

  static List<int> _packBox(SecretBox box) =>
      <int>[...box.nonce, ...box.cipherText, ...box.mac.bytes];

  static SecretBox _unpackBox(List<int> payload) {
    if (payload.length < _nonceLength + _macLength) {
      throw const FormatException('加密块过短');
    }
    final macStart = payload.length - _macLength;
    return SecretBox(
      payload.sublist(_nonceLength, macStart),
      nonce: payload.sublist(0, _nonceLength),
      mac: Mac(payload.sublist(macStart)),
    );
  }

  static List<int> _uint32(int value) => <int>[
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static int _readUint32(List<int> b) =>
      (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

  static Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  /// 把任意分块的流重新切成固定大小的块（加密要求每块等长）
  static Stream<List<int>> _rechunk(Stream<List<int>> source, int size) async* {
    var pending = <int>[];
    await for (final chunk in source) {
      if (pending.isEmpty && chunk.length >= size) {
        // 常见情况：文件读取块正好是整块，直接透传避免拷贝
        if (chunk.length == size) {
          yield chunk;
          continue;
        }
      }
      pending = <int>[...pending, ...chunk];
      while (pending.length >= size) {
        if (pending.length == size) {
          yield pending;
          pending = <int>[];
        } else {
          yield pending.sublist(0, size);
          pending = pending.sublist(size);
        }
      }
    }
    if (pending.isNotEmpty) yield pending;
  }
}

/// 从字节流里按需取固定长度的数据（跨 chunk 边界累积）
class _StreamReader {
  final StreamIterator<List<int>> _iterator;
  var _buffer = <int>[];
  var _pos = 0;

  _StreamReader(Stream<List<int>> source)
      : _iterator = StreamIterator<List<int>>(source);

  /// 取 [count] 字节；数据不足时返回已读到的部分（可能为空）
  Future<List<int>> take(int count) async {
    while (_buffer.length - _pos < count) {
      if (!await _iterator.moveNext()) {
        final rest = _buffer.sublist(_pos);
        _pos = _buffer.length;
        return rest;
      }
      if (_pos > 0) {
        _buffer = _buffer.sublist(_pos);
        _pos = 0;
      }
      _buffer = <int>[..._buffer, ..._iterator.current];
    }
    final out = _buffer.sublist(_pos, _pos + count);
    _pos += count;
    return out;
  }
}
