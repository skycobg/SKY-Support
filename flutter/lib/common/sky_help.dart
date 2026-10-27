// SKY: help requests. The customer phones SKY and presses the button here; SKY Support sends its ID, its
// one-time password and what it knows to our API server, and a technician who is logged in accepts the request
// and connects with no digits or questions on the customer's side. The contract: README-SKY.md.
//
// Customer: SkyHelp.openFromArgs (desktop, `--sky-help <file>` from the SKY Zapper app) and SkyHelp.handleLink
// (`sky-support://sky-help?...`: an open SKY Support, or Android). Technician: SkyHelpBoard polls the server and
// SkyHelpBoardView shows the requests on the connection page.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../consts.dart';
import '../models/platform_model.dart';
import '../models/server_model.dart';
import '../models/state_model.dart';
import '../utils/http_service.dart' as http;

bool get _bg {
  final lang = bind.mainGetLocalOption(key: kCommConfKeyLang);
  if (lang.isNotEmpty && lang != 'default') return lang.startsWith('bg');
  return Platform.localeName.toLowerCase().startsWith('bg');
}

String _t(String bg, String en) => _bg ? bg : en;

class _Resp {
  final int code;
  final dynamic data;
  _Resp(this.code, this.data);

  String get error => (data is Map && data['error'] is String)
      ? data['error'] as String
      : _t('Грешка от сървъра ($code).', 'Server error ($code).');
}

Future<_Resp> _call(String method, String path,
    {Map<String, dynamic>? body, bool auth = false}) async {
  final base =
      (await bind.mainGetApiServer()).trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty) throw Exception('no API server');
  final url = Uri.parse('$base$path');
  final headers = <String, String>{'Content-Type': 'application/json'};
  if (auth) headers.addAll(getHttpHeaders());
  final resp = method == 'GET'
      ? await http.get(url, headers: headers)
      : await http.post(url, headers: headers, body: jsonEncode(body ?? {}));
  dynamic data;
  try {
    data = jsonDecode(decode_http_response(resp));
  } catch (_) {}
  return _Resp(resp.statusCode, data);
}

List<Map<String, String>> _rows(dynamic v) {
  if (v is! List) return [];
  return v
      .whereType<Map>()
      .map((r) => {'k': '${r['k'] ?? ''}', 'v': '${r['v'] ?? ''}'})
      .where((r) => r['k']!.isNotEmpty || r['v']!.isNotEmpty)
      .toList();
}

// ---------------------------------------------------------------------------------------------------------------
// The customer

final _kFileName = RegExp(r'^sky-help-[A-Za-z0-9_-]{1,64}\.json$');

class SkyHelp {
  static bool _open = false;

  /// Desktop start with `--sky-help <file>` (the SKY Zapper app).
  static void openFromArgs(List<String> args) {
    final i = args.indexOf('--sky-help');
    if (i < 0 || i + 1 >= args.length) return;
    _show(_readFile(args[i + 1]));
  }

  /// A `sky-support://sky-help?...` link: `f=<path in hex>` from a second start on this computer (see
  /// src/sky_help.rs), `d=<base64url JSON>` on Android. True if it was one (handled here).
  static bool handleLink({List<String>? cmdArgs, Uri? uri, String? uriString}) {
    Uri? u = uri;
    if (u == null && uriString != null) u = Uri.tryParse(uriString);
    if (u == null &&
        cmdArgs != null &&
        cmdArgs.isNotEmpty &&
        cmdArgs[0].startsWith(bind.mainUriPrefixSync())) {
      u = Uri.tryParse(cmdArgs[0]);
    }
    if (u == null || u.authority != 'sky-help') return false;
    final f = u.queryParameters['f'];
    final d = u.queryParameters['d'];
    Map<String, dynamic> product = {};
    if (f != null && f.isNotEmpty) {
      try {
        product = _readFile(utf8.decode(_hexDecode(f)));
      } catch (e) {
        debugPrint('sky help: bad link: $e');
      }
    } else if (d != null && d.isNotEmpty && !isDesktop) {
      try {
        final m = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(d))));
        if (m is Map<String, dynamic>) product = m;
      } catch (e) {
        debugPrint('sky help: bad data: $e');
      }
    }
    Future.delayed(Duration.zero, () => _show(product));
    return true;
  }

  static List<int> _hexDecode(String s) => [
        for (var i = 0; i + 1 < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16)
      ];

  /// The program's data, read once and deleted. Only a `sky-help-*.json` straight in this user's temp folder is
  /// taken: a link from a web page must not make us read or delete other files.
  static Map<String, dynamic> _readFile(String path) {
    try {
      final file = File(path);
      final name = file.uri.pathSegments.isEmpty ? '' : file.uri.pathSegments.last;
      final dir = file.parent.resolveSymbolicLinksSync().toLowerCase();
      final temp = Directory.systemTemp.resolveSymbolicLinksSync().toLowerCase();
      if (!_kFileName.hasMatch(name) || dir != temp || file.lengthSync() > 65536) {
        debugPrint('sky help: not taking $path');
        return {};
      }
      final text = file.readAsStringSync();
      file.deleteSync();
      final m = jsonDecode(text);
      return m is Map<String, dynamic> ? m : {};
    } catch (e) {
      debugPrint('sky help: the file $path: $e');
      return {};
    }
  }

  static void _show(Map<String, dynamic> product, [int attempt = 0]) {
    if (_open) {
      if (isDesktop) windowOnTop(null);
      return;
    }
    if (globalKey.currentState?.overlay == null) {
      // the window is still starting
      if (attempt < 40) {
        Future.delayed(const Duration(milliseconds: 500), () => _show(product, attempt + 1));
      }
      return;
    }
    _open = true;
    if (isDesktop) windowOnTop(null);
    final req = _CustomerRequest(product);
    gFFI.dialogManager
        .show((setState, close, context) {
          req.setState = setState;
          req.close = close;
          return req.build(context);
        }, clickMaskDismiss: false, backDismiss: false, forceGlobal: true)
        .catchError((e) {
          debugPrint('sky help: the dialog: $e');
          return null;
        })
        .whenComplete(() {
          _open = false;
          req.dispose();
        });
  }
}

enum _Stage { ready, sending, waiting, accepted, connected, expired, failed }

class _CustomerRequest {
  final Map<String, dynamic> product;
  _CustomerRequest(this.product) {
    _init();
  }

  StateSetter? setState;
  void Function([dynamic])? close;
  final problem = TextEditingController();
  _Stage stage = _Stage.ready;
  List<String> phones = ['+359 882 733 447', '+359 2 973 3447'];
  String error = '';
  String acceptedBy = '';
  String myId = '';
  String myPassword = '';
  bool readyToSend = false;
  bool noOneTimePassword = false;
  String notReadyWhy = '';
  int? requestId;
  String token = '';
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  void _set(VoidCallback f) {
    if (_disposed) return;
    f();
    setState?.call(() {});
  }

  Future<void> _init() async {
    try {
      final r = await _call('GET', '/api/sky/help/config');
      if (r.code == 200 && r.data is Map && r.data['phones'] is List) {
        final p = (r.data['phones'] as List).map((e) => '$e').toList();
        if (p.isNotEmpty) _set(() => phones = p);
      }
    } catch (e) {
      debugPrint('sky help: config: $e');
    }
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    _tick();
  }

  /// While nothing has been sent: is this SKY Support ready to be connected to? After that: the heartbeat.
  Future<void> _tick() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      myId = await bind.mainGetMyId();
      myPassword = await bind.mainGetTemporaryPassword();
      if (stage == _Stage.ready || stage == _Stage.failed) {
        await _checkReady();
      } else if (stage == _Stage.waiting || stage == _Stage.accepted) {
        await _heartbeat();
      }
    } catch (e) {
      debugPrint('sky help: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _checkReady() async {
    final method = await bind.mainGetOption(key: kOptionVerificationMethod);
    final approve = await bind.mainGetOption(key: kOptionApproveMode);
    String why = '';
    final noOneTime = method == kUsePermanentPassword || approve == 'click';
    if (noOneTime) {
      why = _t(
          'Тази програма е настроена без еднократна парола. Кажете на служителя ID-то по-долу.',
          'This program is set up without a one-time password. Tell the technician the ID below.');
    } else if (myId.isEmpty || myPassword.isEmpty) {
      why = _t('Свързване със сървъра…', 'Connecting to the server…');
    } else if (isDesktop && stateGlobal.svcStatus.value != SvcStatus.ready) {
      why = _t('Свързване със сървъра…', 'Connecting to the server…');
    }
    _set(() {
      notReadyWhy = why;
      noOneTimePassword = noOneTime;
      readyToSend = why.isEmpty;
    });
  }

  Future<void> send() async {
    if (!readyToSend || stage == _Stage.sending) return;
    _set(() {
      stage = _Stage.sending;
      error = '';
    });
    try {
      if (isAndroid && !gFFI.serverModel.isStart) {
        // Android shares the screen only after the system asks the user once more. No floating window:
        // its permission is a settings page, and the request would wait on it.
        await gFFI.serverModel.checkRequestNotificationPermission();
        await gFFI.serverModel.startService();
      }
      final computer = jsonDecode(await bind.mainGetCommon(key: 'sky-help-computer'));
      final compRows = computer is Map ? _rows(computer['rows']) : <Map<String, String>>[];
      final host = computer is Map ? '${computer['hostname'] ?? ''}' : '';
      final title = '${product['title'] ?? ''}'.trim();
      final info = <String, dynamic>{
        'title': title.isNotEmpty ? title : host,
        if (problem.text.trim().isNotEmpty) 'problem': problem.text.trim(),
        'rows': [..._rows(product['rows']), ...compRows],
        if (product['data'] is Map) 'data': product['data'],
      };
      final r = await _call('POST', '/api/sky/help', body: {
        'peer_id': await bind.mainGetMyId(),
        'uuid': await bind.mainGetUuid(),
        'password': await bind.mainGetTemporaryPassword(),
        'product': '${product['product'] ?? (isAndroid ? 'android' : 'sky-support')}',
        'info': info,
      });
      if (r.code != 200 || r.data is! Map) {
        _set(() {
          stage = _Stage.failed;
          error = r.error;
        });
        return;
      }
      requestId = (r.data['id'] as num).toInt();
      token = '${r.data['token']}';
      _set(() => stage = _Stage.waiting);
    } catch (e) {
      _set(() {
        stage = _Stage.failed;
        error = _t('Няма връзка със сървъра на SKY.', 'No connection to the SKY server.');
      });
    }
  }

  Future<void> _heartbeat() async {
    final connected = isAndroid &&
        stage == _Stage.accepted &&
        gFFI.serverModel.clients.any((c) => c.authorized);
    final r = await _call('POST', '/api/sky/help/status', body: {
      'id': requestId,
      'token': token,
      'password': myPassword,
      'connected': connected,
    });
    if (r.code == 404) {
      _set(() => stage = _Stage.expired);
      return;
    }
    if (r.code != 200 || r.data is! Map) return;
    final status = '${r.data['status']}';
    final by = '${r.data['accepted_by'] ?? ''}';
    switch (status) {
      case 'accepted':
        _set(() {
          stage = _Stage.accepted;
          acceptedBy = by;
        });
        break;
      case 'connected':
        _set(() {
          stage = _Stage.connected;
          acceptedBy = by;
        });
        _timer?.cancel();
        Future.delayed(const Duration(seconds: 4), () => close?.call());
        break;
      case 'expired':
      case 'cancelled':
        _set(() => stage = _Stage.expired);
        break;
    }
  }

  Future<void> cancel() async {
    final id = requestId;
    _timer?.cancel();
    if (id != null && (stage == _Stage.waiting || stage == _Stage.accepted)) {
      try {
        await _call('POST', '/api/sky/help/cancel', body: {'id': id, 'token': token});
      } catch (e) {
        debugPrint('sky help: cancel: $e');
      }
    }
    close?.call();
  }

  void retry() {
    _set(() {
      stage = _Stage.ready;
      requestId = null;
      error = '';
    });
    _tick();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    final id = requestId;
    if (id != null && (stage == _Stage.waiting || stage == _Stage.accepted)) {
      _call('POST', '/api/sky/help/cancel', body: {'id': id, 'token': token})
          .catchError((e) => _Resp(0, null));
    }
  }

  Widget _idAndPassword(BuildContext context) => SelectableText(
        _t('ID: $myId\nПарола: $myPassword', 'ID: $myId\nPassword: $myPassword'),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      );

  CustomAlertDialog build(BuildContext context) {
    const big = TextStyle(fontSize: 16);
    final children = <Widget>[];
    final actions = <Widget>[];
    switch (stage) {
      case _Stage.ready:
      case _Stage.sending:
        children.addAll([
          Text(_t('За отдалечена помощ се обадете на:', 'For remote help, call us:'), style: big),
          const SizedBox(height: 8),
          for (final p in phones)
            SelectableText(p, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(
              _t('Когато говорите със служител на SKY, натиснете бутона отдолу.',
                  'When you are talking to someone from SKY, press the button below.'),
              style: big),
          const SizedBox(height: 12),
          TextField(
            controller: problem,
            maxLength: 300,
            decoration: InputDecoration(
                labelText: _t('Какъв е проблемът? (по желание)', 'What is the problem? (optional)')),
          ),
          if (notReadyWhy.isNotEmpty)
            Text(notReadyWhy, style: TextStyle(color: Theme.of(context).hintColor)),
          if (noOneTimePassword && myId.isNotEmpty)
            SelectableText('ID: $myId',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ]);
        actions.addAll([
          dialogButton(_t('Затвори', 'Close'), onPressed: cancel, isOutline: true),
          dialogButton(
              stage == _Stage.sending
                  ? _t('Изпраща се…', 'Sending…')
                  : _t('Започни отдалечена помощ', 'Start remote help'),
              onPressed: readyToSend && stage == _Stage.ready ? send : null),
        ]);
        break;
      case _Stage.waiting:
        children.addAll([
          Row(children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 12),
            Expanded(
                child: Text(
                    _t('Заявката е изпратена. Служителят на SKY ще се свърже след малко.',
                        'The request has been sent. Someone from SKY will connect shortly.'),
                    style: big)),
          ]),
          if (isAndroid) ...[
            const SizedBox(height: 12),
            Text(
                _t('Ако телефонът попита дали да споделя екрана, натиснете „Сподели екрана“ (или „Започни“).',
                    'If the phone asks whether to share the screen, press "Share screen" (or "Start now").'),
                style: TextStyle(color: Theme.of(context).hintColor)),
          ],
        ]);
        actions.add(dialogButton(_t('Откажи', 'Cancel'), onPressed: cancel, isOutline: true));
        break;
      case _Stage.accepted:
        children.add(Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 12),
          Expanded(
              child: Text(
                  acceptedBy.isEmpty
                      ? _t('Служител на SKY се свързва…', 'Someone from SKY is connecting…')
                      : _t('$acceptedBy от SKY се свързва…', '$acceptedBy from SKY is connecting…'),
                  style: big)),
        ]));
        actions.add(dialogButton(_t('Откажи', 'Cancel'), onPressed: cancel, isOutline: true));
        break;
      case _Stage.connected:
        children.add(Text(
            acceptedBy.isEmpty
                ? _t('Служителят на SKY е при вас.', 'Someone from SKY is connected.')
                : _t('$acceptedBy от SKY е при вас.', '$acceptedBy from SKY is connected.'),
            style: big));
        actions.add(dialogButton(_t('Затвори', 'Close'), onPressed: () => close?.call()));
        break;
      case _Stage.expired:
      case _Stage.failed:
        children.addAll([
          Text(
              stage == _Stage.failed
                  ? error
                  : _t('Никой не прие заявката.', 'Nobody has accepted the request.'),
              style: big),
          const SizedBox(height: 12),
          Text(
              _t('Обадете се на ${phones.join(' или ')} и кажете на служителя:',
                  'Call ${phones.join(' or ')} and tell the technician:'),
              style: big),
          const SizedBox(height: 8),
          _idAndPassword(context),
        ]);
        actions.addAll([
          dialogButton(_t('Затвори', 'Close'), onPressed: () => close?.call(), isOutline: true),
          dialogButton(_t('Опитай пак', 'Try again'), onPressed: retry),
        ]);
        break;
    }
    return CustomAlertDialog(
      title: Row(children: [
        Icon(Icons.support_agent, color: MyTheme.accent),
        const SizedBox(width: 10),
        Expanded(child: Text(_t('Помощ от SKY', 'Help from SKY'))),
      ]),
      content: ConstrainedBox(
        constraints: BoxConstraints(minWidth: isDesktop ? 420 : 0, maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
      actions: actions,
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The technicians

class SkyHelpItem {
  final int id;
  final String peerId;
  final String product;
  final String status;
  final String acceptedBy;
  final int createdAt;
  final String ip;
  final String title;
  final String problem;
  final List<Map<String, String>> rows;

  SkyHelpItem.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        peerId = '${j['peer_id'] ?? ''}',
        product = '${j['product'] ?? ''}',
        status = '${j['status'] ?? ''}',
        acceptedBy = '${j['accepted_by'] ?? ''}',
        createdAt = (j['created_at'] as num? ?? 0).toInt(),
        ip = '${j['ip'] ?? ''}',
        title = j['info'] is Map ? '${j['info']['title'] ?? ''}' : '',
        problem = j['info'] is Map ? '${j['info']['problem'] ?? ''}' : '',
        rows = j['info'] is Map ? _rows(j['info']['rows']) : [];

  bool get pending => status == 'pending';
}

class SkyHelpBoard {
  static final SkyHelpBoard instance = SkyHelpBoard._();
  SkyHelpBoard._();

  final RxList<SkyHelpItem> items = <SkyHelpItem>[].obs;
  final RxString error = ''.obs;
  final RxInt serverNow = 0.obs;
  final Set<int> _seen = {};
  Timer? _timer;
  bool _busy = false;
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Every 5 s while the program runs; it asks the server only while someone is logged in.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => poll());
  }

  Future<void> poll() async {
    if (_busy || DateTime.now().isBefore(_quietUntil)) return;
    if (!gFFI.userModel.isLogin ||
        bind.mainGetLocalOption(key: 'access_token').isEmpty) {
      if (items.isNotEmpty) items.clear();
      error.value = '';
      return;
    }
    _busy = true;
    try {
      final r = await _call('GET', '/api/sky/help/pending', auth: true);
      if (r.code == 200 && r.data is Map) {
        final list = (r.data['list'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(SkyHelpItem.fromJson)
            .toList();
        final fresh = list.where((e) => e.pending && !_seen.contains(e.id));
        final alert = fresh.isNotEmpty;
        _seen.addAll(list.map((e) => e.id));
        serverNow.value = (r.data['now'] as num? ?? 0).toInt();
        items.assignAll(list);
        error.value = '';
        if (alert) _alert();
      } else if (r.code == 403 || r.code == 404) {
        // not a SKY technician, or an older server: nothing to show; ask again in a minute
        items.clear();
        error.value = '';
        _quietUntil = DateTime.now().add(const Duration(minutes: 1));
      } else if (r.code == 401) {
        items.clear();
        error.value = _t('Влезте отново в акаунта си, за да виждате заявките за помощ.',
            'Log in again to see the help requests.');
      } else {
        error.value = r.error;
      }
    } catch (e) {
      error.value = _t('Няма връзка със сървъра за заявките за помощ.',
          'No connection to the help request server.');
    } finally {
      _busy = false;
    }
  }

  void _alert() {
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    if (isDesktop) windowOnTop(null);
  }

  Future<void> accept(BuildContext context, SkyHelpItem it) async {
    try {
      final r = await _call('POST', '/api/sky/help/accept', body: {'id': it.id}, auth: true);
      if (r.code != 200 || r.data is! Map) {
        showToast(r.error, timeout: const Duration(seconds: 6));
        poll();
        return;
      }
      final id = '${r.data['peer_id']}';
      final password = '${r.data['password']}';
      if (context.mounted) connect(context, id, password: password);
      poll();
    } catch (e) {
      showToast(_t('Няма връзка със сървъра.', 'No connection to the server.'));
    }
  }
}

/// The help requests at the top of the connection page; nothing when there are none.
class SkyHelpBoardView extends StatelessWidget {
  const SkyHelpBoardView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final board = SkyHelpBoard.instance;
    return Obx(() {
      final items = board.items.toList();
      final error = board.error.value;
      if (items.isEmpty && error.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 8, right: 12, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error.isNotEmpty)
              Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final it in items) _card(context, it, board.serverNow.value),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _card(BuildContext context, SkyHelpItem it, int now) {
    final ago = now > 0 && it.createdAt > 0 ? ((now - it.createdAt) / 60).floor() : 0;
    final when = ago <= 0
        ? _t('току-що', 'just now')
        : _t('преди $ago мин.', '$ago min ago');
    final small = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
            color: it.pending ? Colors.orange : Theme.of(context).dividerColor,
            width: it.pending ? 2 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.support_agent, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    it.title.isEmpty
                        ? _t('Заявка за помощ', 'Help request')
                        : _t('Моли за помощ: ${it.title}', 'Asks for help: ${it.title}'),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              Text(when, style: small),
            ]),
            if (it.problem.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(it.problem, style: const TextStyle(fontStyle: FontStyle.italic)),
              ),
            const SizedBox(height: 4),
            for (final r in it.rows)
              SelectableText.rich(TextSpan(children: [
                TextSpan(text: r['k']!.isEmpty ? '' : '${r['k']}: ', style: small),
                TextSpan(text: r['v'], style: const TextStyle(fontSize: 12)),
              ])),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(
                    it.pending
                        ? _t('Чака служител', 'Waiting')
                        : _t('Пое я ${it.acceptedBy}', 'Taken by ${it.acceptedBy}'),
                    style: TextStyle(
                        color: it.pending ? Colors.orange : Theme.of(context).hintColor,
                        fontWeight: FontWeight.w600)),
              ),
              if (it.pending)
                ElevatedButton.icon(
                  icon: const Icon(Icons.call_received, size: 18),
                  label: Text(_t('Приеми', 'Accept')),
                  onPressed: () => SkyHelpBoard.instance.accept(context, it),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}
