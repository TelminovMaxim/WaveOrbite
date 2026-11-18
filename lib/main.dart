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
// 1. МОДЕЛИ ДАННЫХ И ПАРСЕР КАРАОКЕ-ТЕКСТОВ (LRC)
// ============================================================================
enum AudioQualityMode {
  opus160('Opus 160 kbps (Макс. качество)'),
  aac128('AAC 128 kbps (Стандарт)'),
  dataSaver('Экономия трафика (~64 kbps)');

  final String label;
  const AudioQualityMode(this.label);
}

class LrcLine {
  final Duration timestamp;
  final String text;

  const LrcLine(this.timestamp, this.text);

  static List<LrcLine> parse(String? rawLrc) {
    if (rawLrc == null || rawLrc.trim().isEmpty) return [];
    final lines = <LrcLine>[];
    final regExp = RegExp(r'^\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)$');

    for (final raw in rawLrc.split('\n')) {
      final match = regExp.firstMatch(raw.trim());
      if (match != null) {
        final min = int.tryParse(match.group(1) ?? '0') ?? 0;
        final sec = double.tryParse(match.group(2) ?? '0') ?? 0.0;
        final text = (match.group(3) ?? '').trim();
        if (text.isNotEmpty) {
          lines.add(
            LrcLine(
              Duration(milliseconds: (min * 60000 + sec * 1000).round()),
              text,
            ),
          );
        }
      } else if (raw.trim().isNotEmpty && !raw.startsWith('[')) {
        // Фолбек для обычного текста без таймкодов
        lines.add(LrcLine(Duration(seconds: lines.length * 5), raw.trim()));
      }
    }
    return lines;
  }
}

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

  Future<Map<String, double>> getArtistWeights() async {
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
// 3. КАТАЛОГ, ДЕДУПЛИКАТОР, ИМПОРТ ПО ССЫЛКАМ И ТРАНСПОРТ ПОТОКОВ
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
      r'(slowed|reverb|nightcore|8d\s*audio|speed\s*up|sped\s*up|karaoke|instrumental\s*cover|bass\s*boosted)',
      caseSensitive: false,
    ).hasMatch(title);
  }

  /// Поиск по чистому каталогу (без дублей)
  Future<List<TrackModel>> searchCleanCatalog(String query) async {
    final uri = Uri.parse(
      'https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&media=music&entity=song&limit=20',
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) return [];

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final results = (decoded['results'] as List<dynamic>? ?? []);
    final seenKeys = <String>{};
    final output = <TrackModel>[];

    for (final item in results) {
      final title = (item['trackName'] as String?) ?? '';
      final artist = (item['artistName'] as String?) ?? '';
      if (title.isEmpty || artist.isEmpty) continue;
      if (isJunkTitle(title)) continue;

      final key = makeCanonicalKey(artist, title);
      if (seenKeys.contains(key)) continue;
      seenKeys.add(key);

      final durSec = ((item['trackTimeMillis'] as int?) ?? 180000) ~/ 1000;
      final cover = ((item['artworkUrl100'] as String?) ?? '')
          .replaceAll('100x100bb', '600x600bb');

      output.add(
        TrackModel(
          id: 'it_${item['trackId']}',
          canonicalKey: key,
          title: title,
          artist: artist,
          durationSec: durSec,
          coverUrl: cover,
        ),
      );
    }
    return output;
  }

  /// Импорт трека или плейлиста по внешней ссылке (Spotify / SoundCloud / YouTube) в стиле Liner
  Future<List<TrackModel>> importFromExternalUrl(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty) return [];

    // 1. YouTube / YouTube Music плейлист или видео
    if (url.contains('youtube.com') || url.contains('youtu.be')) {
      try {
        if (url.contains('list=')) {
          final playlist = await _yt.playlists.get(url);
          final imported = <TrackModel>[];
          await for (final video in _yt.playlists.getVideos(playlist.id).take(25)) {
            final clean = await searchCleanCatalog('${video.author} ${video.title}');
            if (clean.isNotEmpty) {
              imported.add(clean.first);
            } else {
              imported.add(
                TrackModel(
                  id: 'yt_${video.id.value}',
                  canonicalKey: makeCanonicalKey(video.author, video.title),
                  title: video.title,
                  artist: video.author,
                  durationSec: video.duration?.inSeconds ?? 180,
                  coverUrl: video.thumbnails.highResUrl,
                ),
              );
            }
          }
          return imported;
        } else {
          final video = await _yt.videos.get(url);
          final clean = await searchCleanCatalog('${video.author} ${video.title}');
          if (clean.isNotEmpty) return [clean.first];
        }
      } catch (_) {}
    }

    // 2. Spotify / SoundCloud через oEmbed API (получаем название и автора без ключей)
    try {
      Uri? oembedUri;
      if (url.contains('spotify.com')) {
        oembedUri = Uri.parse(
          'https://open.spotify.com/oembed?url=${Uri.encodeComponent(url)}',
        );
      } else if (url.contains('soundcloud.com')) {
        oembedUri = Uri.parse(
          'https://soundcloud.com/oembed?format=json&url=${Uri.encodeComponent(url)}',
        );
      }

      if (oembedUri != null) {
        final res = await http.get(oembedUri);
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final title = (data['title'] as String?) ?? '';
          final author = (data['author_name'] as String?) ?? '';
          final query = '$author $title'.trim();
          if (query.isNotEmpty) {
            final matched = await searchCleanCatalog(query);
            if (matched.isNotEmpty) return [matched.first];
          }
        }
      }
    } catch (_) {}

    return [];
  }

  /// Получение прямой ссылки на ПОЛНЫЙ аудиопоток с учётом выбранного качества
  Future<Uri?> resolveFullAudioStreamUri(
    TrackModel track, {
    AudioQualityMode quality = AudioQualityMode.opus160,
  }) async {
    final searchQuery = '${track.artist} - ${track.title} official audio';
    final searchList = await _yt.search.search(searchQuery);

    Video? bestMatch;
    for (final video in searchList.take(8)) {
      if (isJunkTitle(video.title)) continue;
      final vidDur = video.duration?.inSeconds ?? 0;
      if (vidDur <= 0) continue;

      if ((vidDur - track.durationSec).abs() <= 7) {
        bestMatch = video;
        break;
      }
    }

    bestMatch ??= searchList.isNotEmpty ? searchList.first : null;
    if (bestMatch == null) return null;

    final manifest =
        await _yt.videos.streamsClient.getManifest(bestMatch.id);
    final audioStreams = manifest.audioOnly.sortByBitrate();
    if (audioStreams.isEmpty) return null;

    switch (quality) {
      case AudioQualityMode.opus160:
        return audioStreams.last.url;
      case AudioQualityMode.aac128:
        final mp4Streams =
            audioStreams.where((s) => s.container.name.toLowerCase() == 'mp4');
        return (mp4Streams.isNotEmpty ? mp4Streams.last : audioStreams.last).url;
      case AudioQualityMode.dataSaver:
        return audioStreams.first.url;
    }
  }

  /// Фоновое кэширование полного трека на диск устройства для офлайна
  Future<String?> cacheTrackToDisk(TrackModel track, Uri streamUri) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(p.join(dir.path, 'audio_cache'));
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);

      final file = File(p.join(cacheDir.path, '${track.canonicalKey}.m4a'));
      if (file.existsSync() && file.lengthSync() > 10000) {
        return file.path;
      }

      final response = await http.get(streamUri);
      if (response.statusCode == 200 && response.bodyBytes.length > 10000) {
        await file.writeAsBytes(response.bodyBytes);
        return file.path;
      }
    } catch (_) {}
    return null;
  }

  /// Подгрузка синхронизированного LRC-текста с LRCLIB (мульти-поиск)
  Future<String?> fetchSyncedLyrics(TrackModel track) async {
    try {
      final uri = Uri.parse(
        'https://lrclib.net/api/get?track_name=${Uri.encodeComponent(track.title)}&artist_name=${Uri.encodeComponent(track.artist)}',
      );
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final synced = data['syncedLyrics'] as String?;
        if (synced != null && synced.isNotEmpty) return synced;
        return data['plainLyrics'] as String?;
      }

      // Фолбек через поиск LRCLIB, если точное совпадение не сработало
      final searchUri = Uri.parse(
        'https://lrclib.net/api/search?q=${Uri.encodeComponent('${track.artist} ${track.title}')}',
      );
      final searchRes = await http.get(searchUri);
      if (searchRes.statusCode == 200) {
        final list = jsonDecode(searchRes.body) as List<dynamic>;
        if (list.isNotEmpty) {
          final first = list.first as Map<String, dynamic>;
          return (first['syncedLyrics'] as String?) ??
              (first['plainLyrics'] as String?);
        }
      }
    } catch (_) {}
    return null;
  }

  void dispose() => _yt.close();
}

// ============================================================================
// 4. UI ПРИЛОЖЕНИЯ: ОРБИТАЛЬНЫЙ ПЛЕЕР, ЖИВОЕ КАРАОКЕ И «МОЯ ВОЛНА»
// ============================================================================
class WaveOrbitApp extends StatelessWidget {
  const WaveOrbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WaveOrbit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0B0D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFA855F7),
          surface: Color(0xFF141418),
        ),
      ),
      home: const MainHomeScreen(),
    );
  }
}

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();
  final AudioTransportService _transport = AudioTransportService();
  final TextEditingController _importUrlController = TextEditingController();
  late final AnimationController _orbitController;

  int _tabIndex = 0;
  List<TrackModel> _libraryTracks = [];
  List<TrackModel> _waveQueue = [];
  List<TrackModel> _searchResults = [];
  TrackModel? _currentTrack;
  Color _accentColor = const Color(0xFFA855F7);
  AudioQualityMode _qualityMode = AudioQualityMode.opus160;

  bool _isLoadingStream = false;
  bool _isSearching = false;
  bool _isImporting = false;
  String _characterFilter = 'all';
  String _moodFilter = 'all';

  @override
  void initState() {
    super.initState();
    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );

    _player.playingStream.listen((playing) {
      if (playing) {
        _orbitController.repeat();
      } else {
        _orbitController.stop();
      }
      if (mounted) setState(() {});
    });

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _currentTrack != null) {
        MusicBrainDb.instance
            .recordEvent(_currentTrack!.id, _currentTrack!.artist, 'play_full');
        _playNext();
      }
    });

    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    var tracks = await MusicBrainDb.instance.getAllTracks();
    if (tracks.isEmpty) {
      final starter = TrackModel(
        id: 'it_1440857781',
        canonicalKey: 'gorillaz_clinteastwood',
        title: 'Clint Eastwood',
        artist: 'Gorillaz',
        durationSec: 340,
        bpm: 112,
        mood: 'energetic',
        coverUrl:
            'https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/4b/6f/0b/4b6f0b9c-4e28-23f1-77a9-2f4b876a83a4/825646291045.jpg/600x600bb.jpg',
        accentColorValue: 0xFFA855F7,
      );
      await MusicBrainDb.instance.upsertTrack(starter);
      tracks = [starter];
    }

    _libraryTracks = tracks;
    _currentTrack = tracks.first;
    _accentColor = Color(_currentTrack!.accentColorValue);
    await _rebuildWaveQueue();
    if (mounted) setState(() {});
  }

  Future<void> _rebuildWaveQueue() async {
    final weights = await MusicBrainDb.instance.getArtistWeights();
    final banned = await MusicBrainDb.instance.getBannedTrackIds();

    final scored = _libraryTracks
        .where((t) => t.id != _currentTrack?.id && !banned.contains(t.id))
        .map((t) {
      double score = 55 + (weights[t.artist] ?? 0) * 2;
      if (_characterFilter == 'favorite' && (weights[t.artist] ?? 0) > 4) {
        score += 20;
      }
      if (_moodFilter != 'all') {
        score += (t.mood == _moodFilter) ? 20 : -30;
      }
      t.matchScore = score.clamp(0, 99).round();
      return t;
    }).toList()
      ..sort((a, b) => b.matchScore.compareTo(a.matchScore));

    _waveQueue = scored;
  }

  Future<void> _playTrack(TrackModel track) async {
    setState(() {
      _currentTrack = track;
      _isLoadingStream = true;
    });

    if (track.coverUrl.isNotEmpty) {
      try {
        final palette = await PaletteGenerator.fromImageProvider(
          NetworkImage(track.coverUrl),
          maximumColorCount: 8,
        );
        final vibrant = palette.vibrantColor?.color ??
            palette.dominantColor?.color ??
            const Color(0xFFA855F7);
        if (mounted) setState(() => _accentColor = vibrant);
      } catch (_) {}
    }

    // Если текста ещё нет — сразу начинаем подгружать с LRCLIB параллельно со звуком
    if (track.lrcLyrics == null || track.lrcLyrics!.isEmpty) {
      unawaited(() async {
        final lyrics = await _transport.fetchSyncedLyrics(track);
        if (lyrics != null) {
          track.lrcLyrics = lyrics;
          await MusicBrainDb.instance.upsertTrack(track);
          if (mounted) setState(() {});
        }
      }());
    }

    if (track.isCached) {
      await _player.setFilePath(track.cachedFilePath!);
      setState(() => _isLoadingStream = false);
      await _player.play();
      return;
    }

    final streamUri = await _transport.resolveFullAudioStreamUri(
      track,
      quality: _qualityMode,
    );
    if (streamUri != null) {
      await _player.setAudioSource(AudioSource.uri(streamUri));
      setState(() => _isLoadingStream = false);
      await _player.play();

      unawaited(() async {
        final savedPath = await _transport.cacheTrackToDisk(track, streamUri);
        if (savedPath != null) {
          track.cachedFilePath = savedPath;
          await MusicBrainDb.instance.upsertTrack(track);
          if (mounted) setState(() {});
        }
      }());
    } else {
      setState(() => _isLoadingStream = false);
    }
  }

  Future<void> _playNext() async {
    await _rebuildWaveQueue();
    if (_waveQueue.isNotEmpty) {
      await _playTrack(_waveQueue.first);
    }
  }

  Future<void> _onSearch(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _isSearching = true);
    final items = await _transport.searchCleanCatalog(query.trim());
    if (mounted) {
      setState(() {
        _searchResults = items;
        _isSearching = false;
      });
    }
  }

  Future<void> _handleImportLink() async {
    final url = _importUrlController.text.trim();
    if (url.isEmpty) return;
    setState(() => _isImporting = true);

    final imported = await _transport.importFromExternalUrl(url);
    for (final track in imported) {
      await MusicBrainDb.instance.upsertTrack(track);
    }
    _libraryTracks = await MusicBrainDb.instance.getAllTracks();
    await _rebuildWaveQueue();

    if (mounted) {
      setState(() {
        _isImporting = false;
        _importUrlController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            imported.isNotEmpty
                ? 'Импортировано треков: ${imported.length}'
                : 'Не удалось распознать ссылку (проверьте публичность)',
          ),
        ),
      );
      if (imported.isNotEmpty) {
        await _playTrack(imported.first);
      }
    }
  }

  void _openOrbitalPlayerSheet() {
    if (_currentTrack == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B0B0D),
      builder: (_) => _OrbitalFullPlayerView(
        player: _player,
        orbitController: _orbitController,
        track: _currentTrack!,
        accentColor: _accentColor,
        qualityLabel: _qualityMode.label,
        onLike: () async {
          await MusicBrainDb.instance.recordEvent(
            _currentTrack!.id,
            _currentTrack!.artist,
            'like',
          );
          await _rebuildWaveQueue();
          if (mounted) setState(() {});
        },
        onNext: _playNext,
      ),
    );
  }

  @override
  void dispose() {
    _importUrlController.dispose();
    _orbitController.dispose();
    _player.dispose();
    _transport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tabIndex,
          children: [
            _buildWaveHomeTab(),
            _buildSearchTab(),
            _buildLibraryTab(),
          ],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_currentTrack != null)
            GestureDetector(
              onTap: _openOrbitalPlayerSheet,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF18181D),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        _currentTrack!.coverUrl,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 44,
                          height: 44,
                          color: Colors.white10,
                          child: const Icon(Icons.music_note),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _currentTrack!.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            _isLoadingStream
                                ? 'Получение ${_qualityMode.name.toUpperCase()} потока...'
                                : _currentTrack!.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          _player.playing ? _player.pause() : _player.play(),
                      icon: Icon(
                        _player.playing ? Icons.pause_circle : Icons.play_circle,
                        color: _accentColor,
                        size: 36,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (idx) => setState(() => _tabIndex = idx),
            backgroundColor: const Color(0xFF121216),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.waves),
                label: 'Моя волна',
              ),
              NavigationDestination(
                icon: Icon(Icons.search),
                label: 'Поиск',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music),
                label: 'Медиатека',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWaveHomeTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 12),
        Center(
          child: GestureDetector(
            onTap: () {
              if (_player.playing) {
                _player.pause();
              } else if (_currentTrack != null) {
                _playTrack(_currentTrack!);
              }
            },
            child: Container(
              width: 156,
              height: 156,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [_accentColor, const Color(0xFF18181B)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: _accentColor.withValues(alpha: 0.4),
                    blurRadius: 36,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _player.playing ? Icons.pause : Icons.play_arrow,
                    size: 42,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'МОЯ ВОЛНА',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Настройка потока',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _filterChip('Всё подряд', _characterFilter == 'all', () {
              setState(() => _characterFilter = 'all');
              _rebuildWaveQueue();
            }),
            _filterChip('❤️ Любимое', _characterFilter == 'favorite', () {
              setState(() => _characterFilter = 'favorite');
              _rebuildWaveQueue();
            }),
            _filterChip('⚡ Бодрое', _moodFilter == 'energetic', () {
              setState(() => _moodFilter =
                  _moodFilter == 'energetic' ? 'all' : 'energetic');
              _rebuildWaveQueue();
            }),
            _filterChip('🌊 Спокойное', _moodFilter == 'calm', () {
              setState(() =>
                  _moodFilter = _moodFilter == 'calm' ? 'all' : 'calm');
              _rebuildWaveQueue();
            }),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Следующие в потоке',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 10),
        ..._waveQueue.map(
          (t) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(t.coverUrl, width: 46, height: 46),
            ),
            title: Text(t.title),
            subtitle: Text(t.artist),
            trailing: Text(
              '${t.matchScore}%',
              style: TextStyle(
                color: _accentColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: () => _playTrack(t),
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      selectedColor: _accentColor,
      onSelected: (_) => onTap(),
    );
  }

  Widget _buildSearchTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            onSubmitted: _onSearch,
            decoration: InputDecoration(
              hintText: 'Поиск треков (Дедупликатор + Opus 160kbps)...',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: const Color(0xFF18181D),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_isSearching) const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              itemCount: _searchResults.length,
              itemBuilder: (_, i) {
                final item = _searchResults[i];
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      item.coverUrl,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                    ),
                  ),
                  title: Text(item.title),
                  subtitle: Text(
                    '${item.artist} • ${(item.durationSec ~/ 60)}:${(item.durationSec % 60).toString().padLeft(2, '0')}',
                  ),
                  trailing: const Icon(Icons.play_arrow_rounded),
                  onTap: () async {
                    await MusicBrainDb.instance.upsertTrack(item);
                    _libraryTracks = await MusicBrainDb.instance.getAllTracks();
                    await _playTrack(item);
                    _openOrbitalPlayerSheet();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Блок импорта по ссылке (Spotify / SoundCloud / YouTube)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF18181D),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Импорт музыки по ссылке (Spotify / SoundCloud / YouTube)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _importUrlController,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Вставьте ссылку на трек или плейлист...',
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFF0E0E12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isImporting ? null : _handleImportLink,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accentColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isImporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Импорт'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Выбор качества аудиопотока
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF18181D),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Качество потока:', style: TextStyle(fontSize: 13)),
              DropdownButton<AudioQualityMode>(
                value: _qualityMode,
                underline: const SizedBox.shrink(),
                dropdownColor: const Color(0xFF1E1E24),
                items: AudioQualityMode.values
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text(mode.label, style: const TextStyle(fontSize: 12)),
                      ),
                    )
                    .toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _qualityMode = val);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        const Text(
          'Локальная БД и кэш устройства',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ..._libraryTracks.map(
          (t) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              t.isCached ? Icons.offline_pin : Icons.cloud_queue,
              color: t.isCached ? Colors.greenAccent : Colors.white54,
            ),
            title: Text(t.title),
            subtitle: Text(t.artist),
            onTap: () => _playTrack(t),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 5. ПОЛНОЭКРАННЫЙ ОРБИТАЛЬНЫЙ ПЛЕЕР + ЖИВОЕ КАРАОКЕ В РЕАЛЬНОМ ВРЕМЕНИ (LRC)
// ============================================================================
class _OrbitalFullPlayerView extends StatefulWidget {
  final AudioPlayer player;
  final AnimationController orbitController;
  final TrackModel track;
  final Color accentColor;
  final String qualityLabel;
  final VoidCallback onLike;
  final VoidCallback onNext;

  const _OrbitalFullPlayerView({
    required this.player,
    required this.orbitController,
    required this.track,
    required this.accentColor,
    required this.qualityLabel,
    required this.onLike,
    required this.onNext,
  });

  @override
  State<_OrbitalFullPlayerView> createState() => _OrbitalFullPlayerViewState();
}

class _OrbitalFullPlayerViewState extends State<_OrbitalFullPlayerView> {
  bool _showLyricsOverlay = false;

  @override
  Widget build(BuildContext context) {
    final lrcLines = LrcLine.parse(widget.track.lrcLyrics);

    return Container(
      height: MediaQuery.of(context).size.height * 0.94,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.35),
          radius: 1.1,
          colors: [
            widget.accentColor.withValues(alpha: 0.32),
            const Color(0xFF09090B),
          ],
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.keyboard_arrow_down, size: 28),
                ),
                Column(
                  children: [
                    const Text(
                      'PLAYING NOW',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 3.0,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      widget.track.isCached
                          ? 'OFFLINE CACHED • M4A'
                          : widget.qualityLabel.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        color: widget.track.isCached
                            ? Colors.greenAccent
                            : Colors.white54,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  onPressed: widget.onLike,
                  icon: Icon(Icons.favorite_border, color: widget.accentColor),
                ),
              ],
            ),
          ),

          Expanded(
            child: _showLyricsOverlay
                ? _buildLiveKaraokeView(lrcLines)
                : _buildOrbitalDiscView(),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                Text(
                  widget.track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.track.artist,
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          StreamBuilder<Duration>(
            stream: widget.player.positionStream,
            builder: (context, snapshot) {
              final pos = snapshot.data ?? Duration.zero;
              final total = widget.player.duration ??
                  Duration(seconds: widget.track.durationSec);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  children: [
                    Slider(
                      activeColor: widget.accentColor,
                      value: pos.inSeconds
                          .clamp(0, math.max(1, total.inSeconds))
                          .toDouble(),
                      max: math.max(1, total.inSeconds).toDouble(),
                      onChanged: (v) =>
                          widget.player.seek(Duration(seconds: v.round())),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${pos.inMinutes}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white54),
                        ),
                        Text(
                          '${total.inMinutes}:${(total.inSeconds % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white54),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: () => widget.player.seek(Duration.zero),
                icon: const Icon(Icons.fast_rewind_rounded, size: 34),
              ),
              const SizedBox(width: 24),
              GestureDetector(
                onTap: () => widget.player.playing
                    ? widget.player.pause()
                    : widget.player.play(),
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.accentColor,
                    boxShadow: [
                      BoxShadow(
                        color: widget.accentColor.withValues(alpha: 0.45),
                        blurRadius: 28,
                      ),
                    ],
                  ),
                  child: Icon(
                    widget.player.playing ? Icons.pause : Icons.play_arrow,
                    size: 36,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              IconButton(
                onPressed: widget.onNext,
                icon: const Icon(Icons.fast_forward_rounded, size: 34),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Нижняя полукруглая арка ^ LYRICS (переключает орбиту и живое караоке)
          GestureDetector(
            onTap: () =>
                setState(() => _showLyricsOverlay = !_showLyricsOverlay),
            child: Container(
              width: double.infinity,
              height: 54,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.elliptical(220, 48),
                ),
                border: const Border(top: BorderSide(color: Colors.white12)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _showLyricsOverlay
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    color: widget.accentColor,
                    size: 20,
                  ),
                  Text(
                    _showLyricsOverlay ? 'ORBIT VIEW' : 'LYRICS (LIVE)',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrbitalDiscView() {
    return Center(
      child: SizedBox(
        width: 290,
        height: 290,
        child: Stack(
          alignment: Alignment.center,
          children: [
            RotationTransition(
              turns: widget.orbitController,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white12),
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: widget.accentColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: widget.accentColor, blurRadius: 12),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(
              width: 236,
              height: 236,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: widget.accentColor, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: 0.35),
                    blurRadius: 24,
                  ),
                ],
              ),
            ),
            ClipOval(
              child: Image.network(
                widget.track.coverUrl,
                width: 198,
                height: 198,
                fit: BoxFit.cover,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveKaraokeView(List<LrcLine> lines) {
    if (lines.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Синхронизированный текст загружается из LRCLIB или отсутствует для этого трека',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 14),
          ),
        ),
      );
    }

    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, snapshot) {
        final pos = snapshot.data ?? Duration.zero;
        int activeIndex = 0;
        for (int i = 0; i < lines.length; i++) {
          if (pos >= lines[i].timestamp) {
            activeIndex = i;
          }
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final isActive = index == activeIndex;
            return GestureDetector(
              onTap: () => widget.player.seek(lines[index].timestamp),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  style: TextStyle(
                    fontSize: isActive ? 20 : 15,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                    color: isActive ? Colors.white : Colors.white38,
                  ),
                  child: Text(
                    lines[index].text,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
