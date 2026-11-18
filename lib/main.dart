import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Инициализация SQLite для десктопа (Windows / Linux)
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  await MusicBrainDb.instance.init();
  runApp(const WaveOrbitApp());
}

// ============================================================================
// 1. МОДЕЛИ ДАННЫХ
// ============================================================================
class TrackModel {
  final String id;
  final String canonicalKey;
  final String title;
  final String artist;
  final int durationSec;
  final int bpm;
  final String mood; // 'energetic' | 'calm' | 'dark'
  final bool hasVocals;
  final String coverUrl;
  final int accentColorValue;
  String? cachedFilePath;
  String? lrcLyrics;
  int matchScore;

  TrackModel({
    required this.id,
    required this.canonicalKey,
    required this.title,
    required this.artist,
    required this.durationSec,
    this.bpm = 115,
    this.mood = 'energetic',
    this.hasVocals = true,
    required this.coverUrl,
    this.accentColorValue = 0xFFA855F7,
    this.cachedFilePath,
    this.lrcLyrics,
    this.matchScore = 75,
  });

  bool get isCached =>
      cachedFilePath != null && File(cachedFilePath!).existsSync();

  Map<String, dynamic> toMap() => {
        'id': id,
        'canonical_key': canonicalKey,
        'title': title,
        'artist': artist,
        'duration_sec': durationSec,
        'bpm': bpm,
        'mood': mood,
        'has_vocals': hasVocals ? 1 : 0,
        'cover_url': coverUrl,
        'accent_color': accentColorValue,
        'cached_file_path': cachedFilePath,
        'lrc_lyrics': lrcLyrics,
      };

  factory TrackModel.fromMap(Map<String, dynamic> map) => TrackModel(
        id: map['id'] as String,
        canonicalKey: map['canonical_key'] as String,
        title: map['title'] as String,
        artist: map['artist'] as String,
        durationSec: map['duration_sec'] as int,
        bpm: (map['bpm'] as int?) ?? 115,
        mood: (map['mood'] as String?) ?? 'energetic',
        hasVocals: ((map['has_vocals'] as int?) ?? 1) == 1,
        coverUrl: (map['cover_url'] as String?) ?? '',
        accentColorValue: (map['accent_color'] as int?) ?? 0xFFA855F7,
        cachedFilePath: map['cached_file_path'] as String?,
        lrcLyrics: map['lrc_lyrics'] as String?,
      );
}

// ============================================================================
// 2. ЛОКАЛЬНАЯ БАЗА ДАННЫХ SQLite (Offline-First + Append-Only Event Log)
// ============================================================================
class MusicBrainDb {
  MusicBrainDb._();
  static final MusicBrainDb instance = MusicBrainDb._();

  Database? _db;
  Database get db => _db!;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'music_brain.db');

    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            canonical_key TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            duration_sec INTEGER NOT NULL,
            bpm INTEGER DEFAULT 115,
            mood TEXT DEFAULT 'energetic',
            has_vocals INTEGER DEFAULT 1,
            cover_url TEXT,
            accent_color INTEGER DEFAULT 4289221879,
            cached_file_path TEXT,
            lrc_lyrics TEXT
          )
        ''');

        await database.execute('''
          CREATE TABLE events (
            event_id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            action TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');

        await database.execute('''
          CREATE TABLE preference_weights (
            entity_type TEXT NOT NULL,
            entity_key TEXT NOT NULL,
            score REAL DEFAULT 0.0,
            is_banned INTEGER DEFAULT 0,
            PRIMARY KEY (entity_type, entity_key)
          )
        ''');
      },
    );
  }

  Future<void> upsertTrack(TrackModel track) async {
    await db.insert(
      'tracks',
      track.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<TrackModel>> getAllTracks() async {
    final rows = await db.query('tracks');
    return rows.map(TrackModel.fromMap).toList();
  }

  Future<void> recordEvent(String trackId, String artist, String action) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final deviceId = Platform.isAndroid ? 'android_client' : 'windows_client';
    await db.insert('events', {
      'event_id': 'ev_${now}_${math.Random().nextInt(9999)}',
      'device_id': deviceId,
      'track_id': trackId,
      'action': action,
      'created_at': now,
    });

    double delta = 0;
    int banFlag = 0;
    if (action == 'like') delta = 5.0;
    if (action == 'unlike') delta = -4.0;
    if (action == 'play_full') delta = 3.0;
    if (action == 'skip_early') delta = -2.0;
    if (action == 'dislike_forever') {
      delta = -15.0;
      banFlag = 1;
    }

    if (delta != 0) {
      await db.rawInsert('''
        INSERT INTO preference_weights (entity_type, entity_key, score, is_banned)
        VALUES ('artist', ?, ?, 0)
        ON CONFLICT(entity_type, entity_key)
        DO UPDATE SET score = score + ?
      ''', [artist, delta, delta]);
    }

    if (banFlag == 1) {
      await db.rawInsert('''
        INSERT INTO preference_weights (entity_type, entity_key, score, is_banned)
        VALUES ('track', ?, -100, 1)
        ON CONFLICT(entity_type, entity_key)
        DO UPDATE SET is_banned = 1, score = -100
      ''', [trackId]);
    }
  }

  Future> getArtistWeights() async {
    final rows = await db.query(
      'preference_weights',
      where: "entity_type = 'artist'",
    );
    return {
      for (final r in rows)
        r['entity_key'] as String: (r['score'] as num).toDouble(),
    };
  }

  Future<Set<String>> getBannedTrackIds() async {
    final rows = await db.query(
      'preference_weights',
      where: "entity_type = 'track' AND is_banned = 1",
    );
    return rows.map((r) => r['entity_key'] as String).toSet();
  }

  Future<String> exportEventsJson() async {
    final events = await db.query('events', orderBy: 'created_at DESC');
    return const JsonEncoder.withIndent('  ').convert({
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'events': events,
    });
  }
}

// ============================================================================
// 3. КАТАЛОГ, ДЕДУПЛИКАТОР И ТРАНСПОРТ ПОЛНЫХ АУДИОПОТОКОВ (Opus 160kbps / M4A)
// ============================================================================
class AudioTransportService {
  final YoutubeExplode _yt = YoutubeExplode();

  static String makeCanonicalKey(String artist, String title) {
    final cleanArtist = artist
        .toLowerCase()
        .split(RegExp(r'feat\.|ft\.|,|&'))
        .first
        .replaceAll(RegExp(r'[^a-zа-яё0-9]'), '');
    final cleanTitle = title
        .toLowerCase()
        .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'[^a-zа-яё0-9]'), '');
    return '${cleanArtist}_$cleanTitle';
  }

  static bool isJunkTitle(String title) {
    return RegExp(
      r'(slowed|reverb|nightcore|8d\s*audio|speed\s*up|sped\s*up|karaoke
