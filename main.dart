import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

const gold = Color(0xFFD4AF37);
const bg = Color(0xFF0B0B0D);
const card = Color(0xFF17171B);

void main() => runApp(const App());

class Song {
  final String path;
  final String title;
  final String folder;
  Song(this.path, this.title, this.folder);
}

class Ctrl extends ChangeNotifier {
  final player = AudioPlayer();
  List<Song> songs = [];
  int? index;
  bool shuffle = false;
  int repeat = 0; // 0 off, 1 all, 2 one
  bool loading = true;
  String? error;

  Ctrl() {
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _onEnd();
    });
    player.playerStateStream.listen((_) => notifyListeners());
  }

  Song? get current => index == null ? null : songs[index!];

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    final st = await [Permission.audio, Permission.storage].request();
    final ok = st[Permission.audio]?.isGranted == true ||
        st[Permission.storage]?.isGranted == true;
    if (!ok) {
      error = 'لازم تعطي التطبيق إذن الوصول للأغاني';
      loading = false;
      notifyListeners();
      return;
    }
    final out = <Song>[];
    await _scan(Directory('/storage/emulated/0'), out);
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    songs = out;
    loading = false;
    notifyListeners();
  }

  static const exts = ['.mp3', '.m4a', '.flac', '.wav', '.ogg', '.aac'];

  Future<void> _scan(Directory d, List<Song> out) async {
    try {
      await for (final e in d.list(followLinks: false)) {
        final name = e.path.split('/').last;
        if (e is Directory) {
          if (name.startsWith('.') || name == 'Android') continue;
          await _scan(e, out);
        } else if (e is File) {
          final p = e.path.toLowerCase();
          if (exts.any(p.endsWith) && e.lengthSync() > 800 * 1024) {
            final parts = e.path.split('/');
            final file = parts.last;
            final dot = file.lastIndexOf('.');
            out.add(Song(e.path, dot > 0 ? file.substring(0, dot) : file,
                parts.length > 1 ? parts[parts.length - 2] : ''));
          }
        }
      }
    } catch (_) {}
  }

  Future<void> playAt(int i) async {
    index = i;
    notifyListeners();
    try {
      await player.setFilePath(songs[i].path);
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

  void next() {
    if (songs.isEmpty) return;
    final i = shuffle
        ? Random().nextInt(songs.length)
        : ((index ?? -1) + 1) % songs.length;
    playAt(i);
  }

  void prev() {
    if (songs.isEmpty) return;
    if (player.position.inSeconds > 3) {
      player.seek(Duration.zero);
      return;
    }
    playAt(((index ?? 0) - 1 + songs.length) % songs.length);
  }

  void _onEnd() {
    if (repeat == 2) {
      player.seek(Duration.zero);
      player.play();
    } else if (repeat == 1 || shuffle || (index ?? 0) < songs.length - 1) {
      next();
    }
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    notifyListeners();
  }

  void cycleRepeat() {
    repeat = (repeat + 1) % 3;
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

  @override
  void initState() {
    super.initState();
    ctrl.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: ctrl,
          builder: (context, _) {
            final items = <int>[];
            for (var i = 0; i < ctrl.songs.length; i++) {
              if (q.isEmpty ||
                  ctrl.songs[i].title.toLowerCase().contains(q.toLowerCase())) {
                items.add(i);
              }
            }
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
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: TextField(
                    onChanged: (v) => setState(() => q = v),
                    decoration: InputDecoration(
                      hintText: 'ابحث عن أغنية...',
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
                Expanded(child: _body(items)),
                if (ctrl.current != null) const MiniPlayer(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _body(List<int> items) {
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
            TextButton(onPressed: ctrl.load, child: const Text('إعادة المحاولة')),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(child: Text('ما لقيت أغاني'));
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, k) {
        final i = items[k];
        final s = ctrl.songs[i];
        final active = ctrl.index == i;
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
          subtitle: Text(s.folder,
              maxLines: 1,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
          onTap: () => ctrl.playAt(i),
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
            const Icon(Icons.music_note, color: gold),
            const SizedBox(width: 12),
            Expanded(
              child: Text(s.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
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
                onPressed: ctrl.next, icon: const Icon(Icons.skip_next_rounded)),
          ],
        ),
      ),
    );
  }
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});
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
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF2A2410), Color(0xFF0F0F12)],
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                    ),
                    border: Border.all(color: gold, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Color(0x55D4AF37), blurRadius: 40),
                    ],
                  ),
                  child: const Icon(Icons.music_note, size: 100, color: gold),
                ),
                const Spacer(),
                Text(s.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(s.folder,
                    style: const TextStyle(color: Colors.white54)),
                const SizedBox(height: 24),
                StreamBuilder<Duration>(
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
                                  style: const TextStyle(color: Colors.white54)),
                              Text(fmt(dur),
                                  style: const TextStyle(color: Colors.white54)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      onPressed: ctrl.toggleShuffle,
                      icon: Icon(Icons.shuffle,
                          color: ctrl.shuffle ? gold : Colors.white38),
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
                          ctrl.repeat == 2 ? Icons.repeat_one : Icons.repeat,
                          color: ctrl.repeat == 0 ? Colors.white38 : gold),
                    ),
                  ],
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
