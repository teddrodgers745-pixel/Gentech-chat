// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:shared_preferences/shared_preferences.dart';

class Storage {
  SharedPreferences? _prefs;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      _prefs = null;
    }
  }

  Future<String?> getString(String key) async {
    try {
      return _prefs?.getString(key);
    } catch (_) {
      return null;
    }
  }

  Future<bool> setString(String key, String value) async {
    try {
      return await _prefs?.setString(key, value) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<dynamic> getJson(String key) async {
    try {
      final s = _prefs?.getString(key);
      if (s == null) return null;
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<bool> setJson(String key, dynamic value) async {
    try {
      if (value is String) {
        return await _prefs?.setString(key, value) ?? false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

final storage = Storage();
