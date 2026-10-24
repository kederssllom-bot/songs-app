import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audio_metadata_reader/audio_metadata_reader.dart' as meta;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const gold = Color(0xFFD4AF37);
const bg = Color(0xFF0B0B0D);
const card = Color(0xFF17171B);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.songs.songs_app.audio',
    androidNotificationChannelName: 'تشغيل الأغاني',
    androidNotificationOngoing: true,
  );
  runApp(const App());
}

String cleanName(String s) {
  s = s.replaceAll(
      RegExp(r'[\(\[]?\s*MP3[_\s-]?\d+\s*K(bps)?\s*[\)\]]?',
          caseSensitive: false),
      '');
  s = s.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(RegExp(r'^[\-\.\s]+|[\-\.\s]+$'), '');
  return s.isEmpty ? 'بدون عنوان' : s;
}

class Song {
  final String path;
  final String folder;
  String title;
  String artist;
  String? album;
  Song(this.path, this.title, this.folder, {this.artist = ''});
}

class Ctrl extends ChangeNotifier {
  final player = AudioPlayer();
  List<Song> songs = [];
  List<Song> queue = [];
  String queueId = '';
  int? qIndex;
  Set<String> favs = {};
  Uint8List? cover;
  bool loading = true;
  String? error;
  Timer? _sleep;
  int? sleepMinutes;

  Ctrl() {
    player.currentIndexStream.listen((i) {
      if (i != null && i != qIndex) {
        qIndex = i;
        _loadArt();
        notifyListeners();
      }
    });
    player.playerStateStream.listen((_) => notifyListeners());
    player.shuffleModeEnabledStream.listen((_) => notifyListeners());
    player.loopModeStream.listen((_) => notifyListeners());
  }

  Song? get current =>
      (qIndex != null && qIndex! < queue.length) ? queue[qIndex!] : null;

  bool isFav(Song s) => favs.contains(s.path);

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    final st = await [
      Permission.audio,
      Permission.storage,
      Permission.notification,
    ].request();
    final ok = st[Permission.audio]?.isGranted == true ||
        st[Permission.storage]?.isGranted == true;
    if (!ok) {
      error = 'لازم تعطي التطبيق إذن الوصول للأغاني';
      loading = false;
      notifyListeners();
      return;
    }
    try {
      final p = await SharedPreferences.getInstance();
      favs = (p.getStringList('favs') ?? []).toSet();
    } catch (_) {}
    final out = <Song>[];
    await _scan(Directory('/storage/emulated/0'), out);
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    songs = out;
    loading = false;
    notifyListeners();
    _loadMeta();
  }

  static const exts = ['.mp3', '.m4a', '.flac', '.wav', '.ogg', '.aac'];

  Future<void> _scan(Directory d, List<Song> out) async {
    try {
      await for (final e in d.list(followLinks: false)) {
        final parts = e.path.split('/');
        final name = parts.last;
        if (name.startsWith('.')) continue; // hidden + trashed files
        if (e is Directory) {
          if (name == 'Android') continue;
          await _scan(e, out);
        } else if (e is File) {
          final p = e.path.toLowerCase();
          if (exts.any(p.endsWith) && e.lengthSync() > 800 * 1024) {
            final dot = name.lastIndexOf('.');
            final base = dot > 0 ? name.substring(0, dot) : name;
            out.add(Song(e.path, cleanName(base),
                parts.length > 1 ? parts[parts.length - 2] : ''));
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _loadMeta() async {
    var n = 0;
    for (final s in songs) {
      try {
        final m = meta.readMetadata(File(s.path), getImage: false);
        final t = (m.title ?? '').trim();
        final a = (m.artist ?? '').trim();
        if (t.isNotEmpty) s.title = t;
        if (a.isNotEmpty) s.artist = a;
        s.album = m.album;
      } catch (_) {}
      n++;
      if (n % 15 == 0) {
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    notifyListeners();
  }

  Future<void> _loadArt() async {
    cover = null;
    final s = current;
    if (s == null) return;
    try {
      final m = meta.readMetadata(File(s.path), getImage: true);
      if (m.pictures.isNotEmpty) cover = m.pictures.first.bytes;
    } catch (_) {}
    if (current == s) notifyListeners();
  }

  Future<void> playQueue(List<Song> list, int start, String id) async {
    try {
      if (id == queueId &&
          queue.length == list.length &&
          start < queue.length &&
          queue[start].path == list[start].path) {
        await player.seek(Duration.zero, index: start);
        player.play();
        return;
      }
      queue = List.of(list);
      queueId = id;
      qIndex = start;
      cover = null;
      notifyListeners();
      _loadArt();
      final src = ConcatenatingAudioSource(
        useLazyPreparation: true,
        children: [
          for (final s in queue)
            AudioSource.file(
              s.path,
              tag: MediaItem(
                id: s.path,
                title: s.title,
                artist: s.artist.isEmpty ? s.folder : s.artist,
                album: s.album,
              ),
            ),
        ],
      );
      await player.setAudioSource(src,
          initialIndex: start, initialPosition: Duration.zero);
      player.play();
    } catch (_) {
      error = 'ما قدرت أشغل هاي الأغنية';
      notifyListeners();
    }
  }

  void toggle() {
    if (player.playing) {
      player.pause();
    } else {
      player.play();
    }
  }

  void next() => player.seekToNext();

  void prev() {
    if (player.position.inSeconds > 3) {
      player.seek(Duration.zero);
    } else {
      player.seekToPrevious();
    }
  }

  void toggleShuffle() async {
    final on = !player.shuffleModeEnabled;
    if (on) await player.shuffle();
    await player.setShuffleModeEnabled(on);
  }

  void cycleRepeat() {
    final m = player.loopMode;
    player.setLoopMode(m == LoopMode.off
        ? LoopMode.all
        : m == LoopMode.all
            ? LoopMode.one
            : LoopMode.off);
  }

  Future<void> toggleFav(Song s) async {
    if (!favs.add(s.path)) favs.remove(s.path);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('favs', favs.toList());
    } catch (_) {}
  }

  void setSleep(int? minutes) {
    _sleep?.cancel();
    sleepMinutes = minutes;
    if (minutes != null) {
      _sleep = Timer(Duration(minutes: minutes), () {
        player.pause();
        sleepMinutes = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }
}

final ctrl = Ctrl();

String fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'أغاني',
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: bg,
          colorScheme: const ColorScheme.dark(primary: gold),
        ),
        builder: (c, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String q = '';
  int tab = 0;

  @override
  void initState() {
    super.initState();
    ctrl.load();
  }

  List<Song> _visible() {
    final base = tab == 1
        ? ctrl.songs.where((s) => ctrl.favs.contains(s.path)).toList()
        : ctrl.songs;
    if (q.isEmpty) return base;
    final l = q.toLowerCase();
    return base
        .where((s) =>
            s.title.toLowerCase().contains(l) ||
            s.artist.toLowerCase().contains(l))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: ctrl,
          builder: (context, _) {
            final list = _visible();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Row(
                    children: [
                      const Text('مكتبتي',
                          style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.bold,
                              color: gold)),
                      const Spacer(),
                      Text('${ctrl.songs.length} أغنية',
                          style: const TextStyle(color: Colors.white54)),
                    ],
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: TextField(
                    onChanged: (v) => setState(() => q = v),
                    decoration: InputDecoration(
                      hintText: 'ابحث عن أغنية أو فنان...',
                      prefixIcon: const Icon(Icons.search, color: gold),
                      filled: true,
                      fillColor: card,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      _chip('الكل', 0),
                      const SizedBox(width: 8),
                      _chip('المفضلة (${ctrl.favs.length})', 1),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(child: _body(list)),
                if (ctrl.current != null) const MiniPlayer(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _chip(String t, int i) => ChoiceChip(
        label: Text(t),
        selected: tab == i,
        selectedColor: gold,
        backgroundColor: card,
        labelStyle: TextStyle(color: tab == i ? Colors.black : Colors.white70),
        onSelected: (_) => setState(() => tab = i),
      );

  Widget _body(List<Song> list) {
    if (ctrl.loading) {
      return const Center(child: CircularProgressIndicator(color: gold));
    }
    if (ctrl.error != null && ctrl.songs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ctrl.error!),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () async {
                await openAppSettings();
              },
              child: const Text('فتح الإعدادات'),
            ),
            TextButton(
                onPressed: ctrl.load, child: const Text('إعادة المحاولة')),
          ],
        ),
      );
    }
    if (list.isEmpty) {
      return Center(
          child: Text(tab == 1 ? 'ما في أغاني مفضلة بعد' : 'ما لقيت أغاني'));
    }
    final id = '$tab|$q';
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, k) {
        final s = list[k];
        final active = ctrl.current?.path == s.path;
        final fav = ctrl.isFav(s);
        return ListTile(
          leading: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: active ? gold : Colors.white12),
            ),
            child: Icon(active ? Icons.graphic_eq : Icons.music_note,
                color: active ? gold : Colors.white54),
          ),
          title: Text(s.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: active ? gold : Colors.white)),
          subtitle: Text(s.artist.isEmpty ? s.folder : s.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
          trailing: IconButton(
            icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                color: fav ? gold : Colors.white38),
            onPressed: () => ctrl.toggleFav(s),
          ),
          onTap: () => ctrl.playQueue(list, k, id),
        );
      },
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context) {
    final s = ctrl.current!;
    return GestureDetector(
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => const PlayerPage())),
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: gold, width: 0.8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 42,
                height: 42,
                child: ctrl.cover != null
                    ? Image.memory(ctrl.cover!, fit: BoxFit.cover)
                    : const Icon(Icons.music_note, color: gold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(s.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (s.artist.isNotEmpty)
                    Text(s.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                      onPressed: ctrl.prev,
                      icon: const Icon(Icons.skip_previous_rounded)),
                  IconButton(
                    onPressed: ctrl.toggle,
                    icon: Icon(
                        ctrl.player.playing
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: gold,
                        size: 38),
                  ),
                  IconButton(
                      onPressed: ctrl.next,
                      icon: const Icon(Icons.skip_next_rounded)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  void _sleepSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: card,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('مؤقّت النوم',
                  style: TextStyle(
                      color: gold, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            for (final m in [15, 30, 45, 60])
              ListTile(
                title: Text('بعد $m دقيقة'),
                onTap: () {
                  ctrl.setSleep(m);
                  Navigator.pop(context);
                },
              ),
            if (ctrl.sleepMinutes != null)
              ListTile(
                title: const Text('إلغاء المؤقّت',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  ctrl.setSleep(null);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('يشتغل الآن', style: TextStyle(color: gold)),
        centerTitle: true,
      ),
      body: ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) {
          final s = ctrl.current;
          if (s == null) return const SizedBox();
          final fav = ctrl.isFav(s);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 270,
                  height: 270,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF15130A),
                    border: Border.all(color: gold, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Color(0x55D4AF37), blurRadius: 40),
                    ],
                  ),
                  child: ClipOval(
                    child: ctrl.cover != null
                        ? Image.memory(ctrl.cover!,
                            fit: BoxFit.cover, width: 270, height: 270)
                        : const Icon(Icons.music_note, size: 100, color: gold),
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    IconButton(
                      onPressed: () => ctrl.toggleFav(s),
                      icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                          color: fav ? gold : Colors.white54),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Text(s.title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Text(s.artist.isEmpty ? s.folder : s.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white54)),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => _sleepSheet(context),
                      icon: Icon(Icons.bedtime_outlined,
                          color:
                              ctrl.sleepMinutes != null ? gold : Colors.white54),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: StreamBuilder<Duration>(
                    stream: ctrl.player.positionStream,
                    builder: (context, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final dur = ctrl.player.duration ?? Duration.zero;
                      final max = dur.inMilliseconds.toDouble();
                      final val = pos.inMilliseconds
                          .toDouble()
                          .clamp(0.0, max > 0 ? max : 1.0);
                      return Column(
                        children: [
                          Slider(
                            activeColor: gold,
                            inactiveColor: Colors.white12,
                            min: 0,
                            max: max > 0 ? max : 1.0,
                            value: val,
                            onChanged: (v) => ctrl.player
                                .seek(Duration(milliseconds: v.toInt())),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(fmt(pos),
                                    style:
                                        const TextStyle(color: Colors.white54)),
                                Text(fmt(dur),
                                    style:
                                        const TextStyle(color: Colors.white54)),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: ctrl.toggleShuffle,
                        icon: Icon(Icons.shuffle,
                            color: ctrl.player.shuffleModeEnabled
                                ? gold
                                : Colors.white38),
                      ),
                      IconButton(
                        iconSize: 40,
                        onPressed: ctrl.prev,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      Container(
                        decoration: const BoxDecoration(
                            color: gold, shape: BoxShape.circle),
                        child: IconButton(
                          iconSize: 44,
                          color: Colors.black,
                          onPressed: ctrl.toggle,
                          icon: Icon(ctrl.player.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded),
                        ),
                      ),
                      IconButton(
                        iconSize: 40,
                        onPressed: ctrl.next,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                      IconButton(
                        onPressed: ctrl.cycleRepeat,
                        icon: Icon(
                            ctrl.player.loopMode == LoopMode.one
                                ? Icons.repeat_one
                                : Icons.repeat,
                            color: ctrl.player.loopMode == LoopMode.off
                                ? Colors.white38
                                : gold),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          );
        },
      ),
    );
  }
}
