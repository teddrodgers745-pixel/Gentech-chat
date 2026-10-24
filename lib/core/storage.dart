// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat.dart';
import '../models/provider.dart';

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

  // Provider methods
  Future<Provider?> getProvider() async {
    try {
      final s = _prefs?.getString('provider');
      if (s == null) return null;
      final map = jsonDecode(s) as Map<String, dynamic>;
      return Provider.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<bool> setProvider(Provider provider) async {
    try {
      return await _prefs?.setString('provider', jsonEncode(provider.toJson())) ?? false;
    } catch (_) {
      return false;
    }
  }

  // Chat list methods
  Future<List<Chat>> getChats() async {
    try {
      final s = _prefs?.getString('chats');
      if (s == null) return [];
      final list = jsonDecode(s) as List;
      return list
          .map((e) => Chat.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> setChats(List<Chat> chats) async {
    try {
      return await _prefs?.setString(
            'chats',
            jsonEncode(chats.map((c) => c.toJson()).toList()),
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  // Current chat ID methods
  Future<String?> getCurrentChatId() async {
    try {
      return _prefs?.getString('currentChat');
    } catch (_) {
      return null;
    }
  }

  Future<bool> setCurrentChatId(String? id) async {
    try {
      return await _prefs?.setString('currentChat', id ?? '') ?? false;
    } catch (_) {
      return false;
    }
  }
}

final storage = Storage();
