import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int kPort = 5555;
const int kMaxContacts = 5;
const String kPrefix = 'minichat://';

String _rand(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
}

class Contact {
  String id, name, number, ip;
  int port;
  Contact({required this.id, required this.name, required this.number, required this.ip, required this.port});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'number': number, 'ip': ip, 'port': port};
  factory Contact.fromJson(Map j) =>
      Contact(id: j['id'], name: j['name'], number: j['number'] ?? '', ip: j['ip'], port: j['port']);
}

class Msg {
  final bool mine, sys;
  final String? text, image;
  final int ts;
  Msg({this.mine = false, this.sys = false, this.text, this.image, int? ts})
      : ts = ts ?? DateTime.now().millisecondsSinceEpoch;
  Map<String, dynamic> toJson() => {'mine': mine, 'sys': sys, 'text': text, 'image': image, 'ts': ts};
  factory Msg.fromJson(Map j) =>
      Msg(mine: j['mine'], sys: j['sys'], text: j['text'], image: j['image'], ts: j['ts']);
}

class Store extends ChangeNotifier {
  String id = '', nick = '', number = '';
  List<Contact> contacts = [];
  Map<String, List<Msg>> history = {};
  Set<String> unread = {};
  String? openChat;
  late Directory dir;
  late SharedPreferences prefs;

  Future<void> load() async {
    prefs = await SharedPreferences.getInstance();
    dir = await getApplicationDocumentsDirectory();
    final raw = prefs.getString('data');
    if (raw != null) {
      final d = jsonDecode(raw);
      id = d['id'];
      nick = d['nick'];
      number = d['number'];
      contacts = (d['contacts'] as List).map((e) => Contact.fromJson(e)).toList();
      (d['history'] as Map).forEach((k, v) {
        history[k] = (v as List).map((e) => Msg.fromJson(e)).toList();
      });
    } else {
      id = _rand(12);
    }
  }

  Future<void> save() async {
    await prefs.setString(
      'data',
      jsonEncode({
        'id': id,
        'nick': nick,
        'number': number,
        'contacts': contacts.map((c) => c.toJson()).toList(),
        'history': history.map((k, v) => MapEntry(k, v.map((m) => m.toJson()).toList())),
      }),
    );
  }

  void touch() => notifyListeners();

  Future<void> setProfile(String n, String num) async {
    nick = n;
    number = num;
    await save();
    notifyListeners();
  }

  Contact? find(String cid) {
    for (final c in contacts) {
      if (c.id == cid) return c;
    }
    return null;
  }

  // ---------- адрес и ссылка ----------
  Future<String> myIp() async {
    String? lan;
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (i.name.startsWith('pdp_ip')) continue; // мобильный интернет
      for (final a in i.addresses) {
        final ip = a.address;
        if (ip.startsWith('100.')) return ip; // Tailscale
        if (lan == null && (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.'))) {
          lan = ip;
        }
      }
    }
    return lan ?? '127.0.0.1';
  }

  Future<String> makeLink() async {
    final d = {'i': id, 'n': nick, 'u': number, 'a': await myIp(), 'p': kPort};
    return kPrefix + base64Url.encode(utf8.encode(jsonEncode(d)));
  }

  Future<String?> addByLink(String link) async {
    try {
      final s = link.trim().replaceFirst(kPrefix, '');
      final d = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(s))));
      final cid = d['i'] as String;
      if (cid == id) return 'Это твоя собственная ссылка';
      if (find(cid) != null) return 'Этот друг уже добавлен';
      if (contacts.length >= kMaxContacts) return 'Максимум $kMaxContacts друзей';
      final c = Contact(id: cid, name: d['n'], number: d['u'] ?? '', ip: d['a'], port: d['p']);
      contacts.add(c);
      await save();
      notifyListeners();
      unawaited(_deliver(c, {'type': 'hello'}));
      return null;
    } catch (_) {
      return 'Неверная ссылка';
    }
  }

  Future<void> deleteContact(Contact c) async {
    contacts.remove(c);
    history.remove(c.id);
    await save();
    notifyListeners();
  }

  // ---------- отправка ----------
  Future<bool> _deliver(Contact c, Map<String, dynamic> extra) async {
    final payload = {
      'id': id,
      'nick': nick,
      'number': number,
      'addr': await myIp(),
      'port': kPort,
      ...extra,
    };
    try {
      final s = await Socket.connect(c.ip, c.port, timeout: const Duration(seconds: 5));
      s.add(utf8.encode(jsonEncode(payload)));
      await s.flush();
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _add(String cid, Msg m) {
    history.putIfAbsent(cid, () => []).add(m);
    save();
    notifyListeners();
  }

  Future<void> sendText(Contact c, String text) async {
    _add(c.id, Msg(mine: true, text: text));
    if (!await _deliver(c, {'type': 'text', 'text': text})) {
      _add(c.id, Msg(sys: true, text: 'не доставлено (друг офлайн?)'));
    }
  }

  Future<void> sendImage(Contact c, Uint8List bytes) async {
    final name = '${_rand(8)}.jpg';
    await File('${dir.path}/$name').writeAsBytes(bytes);
    _add(c.id, Msg(mine: true, image: name));
    if (!await _deliver(c, {'type': 'img', 'data': base64Encode(bytes)})) {
      _add(c.id, Msg(sys: true, text: 'фото не доставлено (друг офлайн?)'));
    }
  }

  // ---------- приём ----------
  Future<void> startServer() async {
    try {
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, kPort, shared: true);
      server.listen((sock) {
        final buf = BytesBuilder();
        sock.listen(
          (chunk) {
            if (buf.length < 20 * 1024 * 1024) buf.add(chunk);
          },
          onDone: () {
            _handle(buf.takeBytes());
            sock.destroy();
          },
          onError: (_) => sock.destroy(),
          cancelOnError: true,
        );
      });
    } catch (_) {}
  }

  Future<void> _handle(Uint8List bytes) async {
    try {
      final m = jsonDecode(utf8.decode(bytes));
      final cid = m['id'] as String;
      var c = find(cid);
      if (c == null) {
        if (contacts.length >= kMaxContacts) return;
        c = Contact(id: cid, name: m['nick'], number: m['number'] ?? '', ip: m['addr'], port: m['port']);
        contacts.add(c);
      } else {
        c.name = m['nick'];
        c.number = m['number'] ?? '';
        c.ip = m['addr'];
        c.port = m['port'];
      }
      final type = m['type'];
      if (type == 'text') {
        _add(cid, Msg(text: m['text']));
        if (openChat != cid) unread.add(cid);
      } else if (type == 'img') {
        final name = '${_rand(8)}.jpg';
        await File('${dir.path}/$name').writeAsBytes(base64Decode(m['data']));
        _add(cid, Msg(image: name));
        if (openChat != cid) unread.add(cid);
      }
      await save();
      notifyListeners();
    } catch (_) {}
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final s = Store();
  await s.load();
  await s.startServer();
  runApp(MyApp(s));
}

class MyApp extends StatelessWidget {
  final Store s;
  const MyApp(this.s, {super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MiniChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF25D366)),
      home: ListenableBuilder(
        listenable: s,
        builder: (_, __) => s.nick.isEmpty ? SettingsPage(s, first: true) : ChatsPage(s),
      ),
    );
  }
}

// ---------- список чатов ----------
class ChatsPage extends StatelessWidget {
  final Store s;
  const ChatsPage(this.s, {super.key});

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addFriend(BuildContext context) async {
    final clip = (await Clipboard.getData('text/plain'))?.text ?? '';
    final ctrl = TextEditingController(text: clip.startsWith(kPrefix) ? clip : '');
    if (!context.mounted) return;
    final link = await showDialog<String>(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('Ссылка друга'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'minichat://...')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(dc, ctrl.text), child: const Text('Добавить')),
        ],
      ),
    );
    if (link == null || link.isEmpty) return;
    final err = await s.addByLink(link);
    if (err != null && context.mounted) _snack(context, err);
  }

  Future<void> _confirmDelete(BuildContext context, Contact c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: Text('Удалить чат с ${c.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('Нет')),
          TextButton(onPressed: () => Navigator.pop(dc, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) await s.deleteContact(c);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Чаты'),
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Моя ссылка',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: await s.makeLink()));
              if (context.mounted) _snack(context, 'Ссылка скопирована. Отправь её другу');
            },
          ),
          IconButton(icon: const Icon(Icons.person_add), onPressed: () => _addFriend(context)),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(s))),
          ),
        ],
      ),
      body: s.contacts.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Пока пусто.\nНажми 🔗, отправь свою ссылку другу\nили добавь его ссылку через ➕',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: s.contacts.map((c) {
                final h = s.history[c.id];
                final last = (h == null || h.isEmpty) ? null : h.last;
                final preview = last == null ? '' : (last.image != null ? '📷 Фото' : (last.text ?? ''));
                return ListTile(
                  title: Text(c.name),
                  subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: s.unread.contains(c.id)
                      ? const Icon(Icons.circle, size: 12, color: Color(0xFF25D366))
                      : null,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(s, c)))
                      .then((_) => s.touch()),
                  onLongPress: () => _confirmDelete(context, c),
                );
              }).toList(),
            ),
    );
  }
}

// ---------- чат ----------
class ChatPage extends StatefulWidget {
  final Store s;
  final Contact c;
  const ChatPage(this.s, this.c, {super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.s.openChat = widget.c.id;
    widget.s.unread.remove(widget.c.id);
  }

  @override
  void dispose() {
    widget.s.openChat = null;
    ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final t = ctrl.text.trim();
    if (t.isEmpty) return;
    ctrl.clear();
    widget.s.sendText(widget.c, t);
  }

  Future<void> _pick() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1280, imageQuality: 70);
    if (x != null) widget.s.sendImage(widget.c, await x.readAsBytes());
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s, c = widget.c;
    return Scaffold(
      backgroundColor: const Color(0xFFECE5DD),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.name),
            if (c.number.isNotEmpty) Text(c.number, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: s,
              builder: (_, __) {
                final msgs = (s.history[c.id] ?? []).reversed.toList();
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => Bubble(s, msgs[i]),
                );
              },
            ),
          ),
          SafeArea(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.photo), onPressed: _pick),
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: 'Сообщение', border: InputBorder.none),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.send), onPressed: _send),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class Bubble extends StatelessWidget {
  final Store s;
  final Msg m;
  const Bubble(this.s, this.m, {super.key});

  @override
  Widget build(BuildContext context) {
    if (m.sys) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text(m.text ?? '', style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ),
      );
    }
    final t = DateTime.fromMillisecondsSinceEpoch(m.ts);
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.all(8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: m.mine ? const Color(0xFFDCF8C6) : Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.image != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File('${s.dir.path}/${m.image}')),
              ),
            if (m.text != null) Text(m.text!, style: const TextStyle(color: Colors.black, fontSize: 16)),
            Text(time, style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ---------- настройки: только ник и номер ----------
class SettingsPage extends StatefulWidget {
  final Store s;
  final bool first;
  const SettingsPage(this.s, {this.first = false, super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final nick = TextEditingController(text: widget.s.nick);
  late final number = TextEditingController(text: widget.s.number);

  Future<void> _save() async {
    if (nick.text.trim().isEmpty) return;
    await widget.s.setProfile(nick.text.trim(), number.text.trim());
    if (!widget.first && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.first ? 'Добро пожаловать' : 'Настройки'),
        automaticallyImplyLeading: !widget.first,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: nick, decoration: const InputDecoration(labelText: 'Ник')),
            const SizedBox(height: 12),
            TextField(
              controller: number,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Номер'),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Сохранить')),
          ],
        ),
      ),
    );
  }
}
