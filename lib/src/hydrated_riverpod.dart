// ignore_for_file: lines_longer_than_80_chars

import 'dart:async';

import 'package:hydrated_riverpod/hydrated_riverpod.dart';
import 'package:meta/meta.dart';

/// For example:
///
/// ```dart
/// class MyStorage extends Storage {
///   ...
///   // A custom Storage implementation.
///   ...
/// }
///
/// void main() {
///   HydratedRiverpod.initialize(storage: MyStorage());
///     ...
///     // HydratedRiverpod instances will use MyStorage.
///     ...
/// }
/// ```
class HydratedRiverpod {
  HydratedRiverpod._({
    required Storage storage,
  }) : _storage = storage;

  final Storage _storage;

  /// Initializes [HydratedRiverpod] with [storage].
  Storage get storage => _storage;

  /// The current [HydratedRiverpod], if one has been created.
  static HydratedRiverpod? get instance => _instance;
  static HydratedRiverpod? _instance;

  /// Returns an instance of the [HydratedRiverpod], creating and
  /// initializing it if necessary.
  // ignore: prefer_constructors_over_static_methods
  static HydratedRiverpod initialize({
    Storage? storage,
  }) {
    storage ??= _defaultStorage;

    _instance = HydratedRiverpod._(storage: storage);

    return HydratedRiverpod.instance!;
  }
}

/// {@template HydratedStateNotifier}
/// Specialized [StateNotifier] which handles initializing the [StateNotifier] state
/// based on the persisted state. This allows state to be persisted
/// across hot restarts as well as complete app restarts.
///
/// ```dart
/// class Counter extends HydratedStateNotifier<int> {
///   Counter() : super(0);
///
///   void increment() => state++;
///
///   void decrement() => state==;
///
///   @override
///   int fromJson(Map<String, dynamic> json) => json['value'] as int;
///
///   @override
///   Map<String, int> toJson(int state) => {'value': state};
/// }
/// ```
///
/// {@endtemplate}
abstract class HydratedStateNotifier<State> extends StateNotifier<State>
    with HydratedMixin<State> {
  /// {@macro HydratedStateNotifier}
  HydratedStateNotifier(State state) : super(state) {
    hydrate();
  }
}

/// A mixin which enables automatic state persistence
/// for [StateController] and [StateNotifier] classes.
///
/// The [hydrate] method must be invoked in the constructor body
/// when using the [HydratedMixin] directly.
///
/// If a mixin is not necessary, it is recommended to
/// extend [HydratedStateController] and [HydratedStateNotifier] respectively.
///
/// ```dart
/// class Counter extends StateNotifier<int> with HydratedMixin {
///  Counter() : super(0) {
///    hydrate();
///  }
///  ...
/// }
/// ```
///
/// See also:
///
/// * [HydratedStateController] to enable automatic state persistence/restoration with [StateController]
/// * [HydratedStateNotifier] to enable automatic state persistence/restoration with [StateNotifier]
///
mixin HydratedMixin<State> on StateNotifier<State> {
  late final _scope = HydratedRiverpod.instance;

  Storage get _storage {
    final storage = _scope?.storage;
    if (storage == null) throw const StorageNotFound();
    if (storage is _DefaultStorage) throw const StorageNotFound();
    return storage;
  }

  /// Populates the internal state storage with the latest state.
  /// This should be called when using the [HydratedMixin]
  /// directly within the constructor body.
  ///
  /// ```dart
  /// class Counter extends StateNotifier<int> with HydratedMixin {
  ///  Counter() : super(0) {
  ///    hydrate();
  ///  }
  ///  ...
  /// }
  /// ```
  /// }
  /// ```
  void hydrate() {
    try {
      final stateJson = _toJson(state);
      if (stateJson != null) {
        _storage.write(storageToken, stateJson).then((_) {}, onError: onError);
      }
    } catch (error, stackTrace) {
      onError(error, stackTrace);
      if (error is StorageNotFound) rethrow;
    }
  }

  @override
  ErrorListener get onError => (Object error, StackTrace? stackTrace) {
        if (super.onError != null) {
          super.onError!(error, stackTrace);
        } else {
          throw error;
        }
      };

  State? _state;

  @override
  State get state {
    if (_state != null) return _state!;
    try {
      final stateJson = _storage.read(storageToken) as Map<dynamic, dynamic>?;
      if (stateJson == null) {
        _state = super.state;
        return super.state;
      }
      final cachedState = _fromJson(stateJson);
      if (cachedState == null) {
        _state = super.state;
        return super.state;
      }
      _state = cachedState;
      return cachedState;
    } catch (error, stackTrace) {
      onError(error, stackTrace);
      _state = super.state;
      return super.state;
    }
  }

  @override
  set state(State value) {
    super.state = value;
    final state = value;
    try {
      final stateJson = _toJson(state);
      if (stateJson != null) {
        _storage.write(storageToken, stateJson).then((_) {}, onError: onError);
      }
    } catch (error, stackTrace) {
      onError(error, stackTrace);
      rethrow;
    }
    _state = state;
  }

  State? _fromJson(dynamic json) {
    final dynamic traversedJson = _traverseRead(json);
    final castJson = _cast<Map<String, dynamic>>(traversedJson);
    return fromJson(castJson ?? <String, dynamic>{});
  }

  Map<String, dynamic>? _toJson(State state) {
    return _cast<Map<String, dynamic>>(_traverseWrite(toJson(state)).value);
  }

  dynamic _traverseRead(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>((dynamic key, dynamic value) {
        return MapEntry<String, dynamic>(
          _cast<String>(key) ?? '',
          _traverseRead(value),
        );
      });
    }
    if (value is List) {
      for (var i = 0; i < value.length; i++) {
        value[i] = _traverseRead(value[i]);
      }
    }
    return value;
  }

  T? _cast<T>(dynamic x) => x is T ? x : null;

  _Traversed _traverseWrite(Object? value) {
    final dynamic traversedAtomicJson = _traverseAtomicJson(value);
    if (traversedAtomicJson is! NIL) {
      return _Traversed.atomic(traversedAtomicJson);
    }
    final dynamic traversedComplexJson = _traverseComplexJson(value);
    if (traversedComplexJson is! NIL) {
      return _Traversed.complex(traversedComplexJson);
    }
    try {
      _checkCycle(value);
      final dynamic customJson = _toEncodable(value);
      final dynamic traversedCustomJson = _traverseJson(customJson);
      if (traversedCustomJson is NIL) {
        throw HydratedUnsupportedError(value);
      }
      _removeSeen(value);
      return _Traversed.complex(traversedCustomJson);
    } on HydratedCyclicError catch (e) {
      throw HydratedUnsupportedError(value, cause: e);
    } on HydratedUnsupportedError {
      rethrow; // do not stack `HydratedUnsupportedError`
    } catch (e) {
      throw HydratedUnsupportedError(value, cause: e);
    }
  }

  dynamic _traverseAtomicJson(dynamic object) {
    if (object is num) {
      if (!object.isFinite) return const NIL();
      return object;
    } else if (identical(object, true)) {
      return true;
    } else if (identical(object, false)) {
      return false;
    } else if (object == null) {
      return null;
    } else if (object is String) {
      return object;
    }
    return const NIL();
  }

  dynamic _traverseComplexJson(dynamic object) {
    if (object is List) {
      if (object.isEmpty) return object;
      _checkCycle(object);
      List<dynamic>? list;
      for (var i = 0; i < object.length; i++) {
        final traversed = _traverseWrite(object[i]);
        list ??= traversed.outcome == _Outcome.atomic
            ? object.sublist(0)
            : (<dynamic>[]..length = object.length);
        list[i] = traversed.value;
      }
      _removeSeen(object);
      return list;
    } else if (object is Map) {
      _checkCycle(object);
      final map = <String, dynamic>{};
      object.forEach((dynamic key, dynamic value) {
        final castKey = _cast<String>(key);
        if (castKey != null) {
          map[castKey] = _traverseWrite(value).value;
        }
      });
      _removeSeen(object);
      return map;
    }
    return const NIL();
  }

  dynamic _traverseJson(dynamic object) {
    final dynamic traversedAtomicJson = _traverseAtomicJson(object);
    return traversedAtomicJson is! NIL
        ? traversedAtomicJson
        : _traverseComplexJson(object);
  }

  dynamic _toEncodable(dynamic object) => object.toJson();

  final List _seen = <dynamic>[];

  void _checkCycle(Object? object) {
    for (var i = 0; i < _seen.length; i++) {
      if (identical(object, _seen[i])) {
        throw HydratedCyclicError(object);
      }
    }
    _seen.add(object);
  }

  void _removeSeen(dynamic object) {
    assert(_seen.isNotEmpty);
    assert(identical(_seen.last, object));
    _seen.removeLast();
  }

  /// [id] is used to uniquely identify multiple instances.
  /// In most cases it is not necessary;
  /// however, if you wish to intentionally have multiple instances,
  /// then you must override [id] and return a unique identifier for
  /// each [HydratedStateNotifier] instance in order to keep the caches
  /// independent of each other.
  String get id => '';

  /// Storage prefix which can be overridden to provide a custom
  /// storage namespace.
  /// Defaults to [runtimeType] but should be overridden in cases
  /// where stored data should be resilient to obfuscation or persist
  /// between debug/release builds.
  String get storagePrefix => runtimeType.toString();

  /// `storageToken` is used as registration token for hydrated storage.
  /// Composed of [storagePrefix] and [id].
  @nonVirtual
  String get storageToken => '$storagePrefix$id';

  /// [clear] is used to wipe or invalidate the cache of a [HydratedStateNotifier].
  /// Calling [clear] will delete the cached state of the state_notifier
  /// but will not modify the current state of the state_notifier.
  Future<void> clear() => _storage.delete(storageToken);

  /// Responsible for converting the `Map<String, dynamic>` representation
  /// of the StateNotifier state into a concrete instance of the StateNotifier state.
  State? fromJson(Map<String, dynamic> json);

  /// Responsible for converting a concrete instance of the StateNotifier state
  /// into the the `Map<String, dynamic>` representation.
  ///
  /// If [toJson] returns `null`, then no state changes will be persisted.
  Map<String, dynamic>? toJson(State state);
}

/// Reports that an object could not be serialized due to cyclic references.
/// When the cycle is detected, a [HydratedCyclicError] is thrown.
class HydratedCyclicError extends HydratedUnsupportedError {
  /// The first object that was detected as part of a cycle.
  HydratedCyclicError(Object? object) : super(object);

  @override
  String toString() => 'Cyclic error while state traversing';
}

/// {@template storage_not_found}
/// Exception thrown if there was no [HydratedStorage] specified.
/// This is most likely due to forgetting to setup the [HydratedStorage]:
/// {@endtemplate}
class StorageNotFound implements Exception {
  /// {@macro storage_not_found}
  const StorageNotFound();

  @override
  String toString() {
    return 'Storage was accessed before it was initialized.\n'
        'Please ensure that storage has been initialized.';
  }
}

/// Reports that an object could not be serialized.
/// The [unsupportedObject] field holds object that failed to be serialized.
///
/// If an object isn't directly serializable, the serializer calls the `toJson`
/// method on the object. If that call fails, the error will be stored in the
/// [cause] field. If the call returns an object that isn't directly
/// serializable, the [cause] is null.
class HydratedUnsupportedError implements Exception {
  /// The object that failed to be serialized.
  /// Error of attempt to serialize through `toJson` method.
  HydratedUnsupportedError(
    this.unsupportedObject, {
    this.cause,
  });

  /// The object that could not be serialized.
  final Object? unsupportedObject;

  /// The exception thrown when trying to convert the object.
  final Object? cause;

  @override
  String toString() {
    final safeString = Error.safeToString(unsupportedObject);
    final prefix = cause != null
        ? 'Converting object to an encodable object failed:'
        : 'Converting object did not return an encodable object:';
    return '$prefix $safeString';
  }
}

/// {@template NIL}
/// Type which represents objects that do not support json encoding
///
/// This should never be used and is exposed only for testing purposes.
/// {@endtemplate}
@visibleForTesting
class NIL {
  /// {@macro NIL}
  const NIL();
}

enum _Outcome { atomic, complex }

class _Traversed {
  _Traversed._({required this.outcome, required this.value});
  _Traversed.atomic(dynamic value)
      : this._(outcome: _Outcome.atomic, value: value);
  _Traversed.complex(dynamic value)
      : this._(outcome: _Outcome.complex, value: value);
  final _Outcome outcome;
  final dynamic value;
}

final _defaultStorage = _DefaultStorage();

class _DefaultStorage implements Storage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
