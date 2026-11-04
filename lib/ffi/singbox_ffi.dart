import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Optional direct FFI loader for `libsingboxcore.dylib`.
///
/// Primary MVP path is MethodChannel → Swift → dlopen/FFI.
/// This file is an extension point if you prefer pure Dart FFI later.
///
/// Build the dylib first: `make -C native/singboxcore`
class SingboxFfi {
  SingboxFfi._(this._lib);

  final DynamicLibrary _lib;

  static SingboxFfi? tryOpen({String? path}) {
    if (!Platform.isMacOS) return null;
    final candidates = <String>[
      ?path,
      'libsingboxcore.dylib',
      // Relative to common build output when running from repo root tools.
      'native/singboxcore/build/arm64/libsingboxcore.dylib',
      'native/singboxcore/build/universal/libsingboxcore.dylib',
    ];
    for (final c in candidates) {
      try {
        return SingboxFfi._(DynamicLibrary.open(c));
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  String version() {
    final fn = _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
      'SingletVersion',
    );
    final free = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
      'SingletFreeString',
    );
    final p = fn();
    try {
      return p.toDartString();
    } finally {
      free(p);
    }
  }
}
