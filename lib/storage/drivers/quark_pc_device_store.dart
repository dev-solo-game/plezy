import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/base_shared_preferences_service.dart';
import '../../utils/app_logger.dart';
import 'quark_pc_session.dart';

/// Persists a single stable desktop device identity (`utdid` + `machine`) per
/// Plezy installation so Quark PC mounts, re-scans, and mode switches keep
/// presenting the same Windows client instead of minting new machine ids.
class QuarkPcDeviceStore {
  QuarkPcDeviceStore._();

  static const String prefsKey = 'quark_pc_device_v1';

  static QuarkPcDevice? _cached;
  static Future<QuarkPcDevice>? _inFlight;

  /// In-memory device loaded by [loadIfPresent], [getOrCreate], or [adoptIfAbsent].
  static QuarkPcDevice? get cached => _cached;

  /// Loads an already persisted device into [cached] without generating one if
  /// no desktop mount has stored a device yet.
  static Future<QuarkPcDevice?> loadIfPresent({SharedPreferencesWithCache? prefs}) async {
    if (_cached != null && prefs == null) return _cached;
    final store = await _resolveStore(prefs);
    final stored = _readDevice(store);
    if (stored != null) _cached = stored;
    return stored;
  }

  /// Returns the persisted device for this installation, creating (or adopting
  /// [seed]) and saving one on first use.
  static Future<QuarkPcDevice> getOrCreate({QuarkPcDevice? seed, SharedPreferencesWithCache? prefs}) {
    final existing = _cached;
    if (existing != null && prefs == null) return Future<QuarkPcDevice>.value(existing);
    if (prefs != null) return _loadOrCreate(seed: seed, prefs: prefs);
    return _inFlight ??= _loadOrCreate(seed: seed).whenComplete(() => _inFlight = null);
  }

  /// Adopts [device] into memory immediately and persists it if no global
  /// device has been saved yet.
  static Future<QuarkPcDevice> adoptIfAbsent(QuarkPcDevice device, {SharedPreferencesWithCache? prefs}) async {
    final existing = _cached;
    if (existing != null && prefs == null) return existing;
    if (prefs == null) _cached ??= device;
    try {
      return await _loadOrCreate(seed: device, prefs: prefs);
    } catch (e) {
      appLogger.d('QuarkPcDeviceStore: failed to persist adopted device', error: e);
      return _cached ?? device;
    }
  }

  static Future<QuarkPcDevice> _loadOrCreate({QuarkPcDevice? seed, SharedPreferencesWithCache? prefs}) async {
    final store = await _resolveStore(prefs);
    final stored = _readDevice(store);
    if (stored != null) {
      _cached = stored;
      return stored;
    }
    final device = seed ?? QuarkPcDevice.generate();
    await store.setString(prefsKey, jsonEncode(device.toJson()));
    await _tryReload(store);
    final settled = _readDevice(store) ?? device;
    _cached = settled;
    return settled;
  }

  static Future<SharedPreferencesWithCache> _resolveStore(SharedPreferencesWithCache? prefs) async {
    if (prefs != null) return prefs;
    final store = await BaseSharedPreferencesService.sharedCache();
    await _tryReload(store);
    return store;
  }

  static Future<void> _tryReload(SharedPreferencesWithCache store) async {
    try {
      await store.reloadCache();
    } catch (e) {
      appLogger.d('QuarkPcDeviceStore: prefs reload failed', error: e);
    }
  }

  static QuarkPcDevice? _readDevice(SharedPreferencesWithCache store) {
    final raw = store.get(prefsKey);
    if (raw is! String || raw.isEmpty) return null;
    try {
      return QuarkPcDevice.tryFromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _cached = null;
    _inFlight = null;
  }
}
