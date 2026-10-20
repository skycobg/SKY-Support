// SKY Support: monitor layout per peer ("Подредба на мониторите").
//
// Remembers, for every peer and for the current set of local screens, on which
// local screen (and where on it) each remote display is shown, and restores
// that layout automatically on the next connection. Nothing to click:
// - a window's place is recorded when its session is established and whenever
//   it is moved, resized or toggled fullscreen;
// - a display switched away from in a window is forgotten;
// - a window closed by the user gets a "closed at" time. On the next connection
//   the windows that were open at the end of the session come back: if some
//   records were never closed (connection lost, app quit) only those; else the
//   ones closed together at the end (within _endOfSessionSeconds of the last
//   close). A window closed long before the end stays closed.
// Different sets of local screens (docked / laptop only) are kept apart.
//
// Storage: one peer flutter option per remote display,
//   key   `sky-dl:<hash of local screen set>:<display index>`
//   value `<screen>;<fullscreen 1/0>;<l>;<t>;<w>;<h>[;<closed at, epoch s>]`
// where l, t, w, h are the window frame as fractions of the local screen.
//
// Design note: docs/2026-10-20-display-layout.md in the SKY Support project.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:get/get.dart';

/// Where one remote display sits on the local screens.
class SkyDisplayPlacement {
  final int screen;
  final bool fullscreen;
  // Window frame as fractions of the local screen rect.
  final double l, t, w, h;
  // Epoch seconds when the user closed the window; null while it is open.
  final int? closedAt;

  const SkyDisplayPlacement(
      this.screen, this.fullscreen, this.l, this.t, this.w, this.h,
      [this.closedAt]);

  SkyDisplayPlacement withClosedAt(int? v) =>
      SkyDisplayPlacement(screen, fullscreen, l, t, w, h, v);

  String encode() {
    final s =
        '$screen;${fullscreen ? 1 : 0};${_f(l)};${_f(t)};${_f(w)};${_f(h)}';
    return closedAt == null ? s : '$s;$closedAt';
  }

  static String _f(double v) => v.toStringAsFixed(4);

  static SkyDisplayPlacement? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    final p = s.split(';');
    if (p.length != 6 && p.length != 7) return null;
    final screen = int.tryParse(p[0]);
    final nums = p.sublist(2, 6).map(double.tryParse).toList();
    final closedAt = p.length == 7 ? int.tryParse(p[6]) : null;
    if (screen == null ||
        screen < 0 ||
        nums.any((e) => e == null) ||
        (p.length == 7 && closedAt == null)) {
      return null;
    }
    return SkyDisplayPlacement(
        screen, p[1] == '1', nums[0]!, nums[1]!, nums[2]!, nums[3]!, closedAt);
  }

  Rect rectOn(Rect s) => Rect.fromLTWH(
      s.left + l * s.width, s.top + t * s.height, w * s.width, h * s.height);
}

class SkyDisplayLayout {
  static const _prefix = 'sky-dl';
  static const _endOfSessionSeconds = 120;

  static Timer? _debounce;
  static DesktopTabController? _controller;
  // Last known local screens (sorted), for writes that cannot wait.
  static List<Rect>? _screens;
  // This window was opened for one display of an already connected peer.
  static bool _openedForDisplay = false;
  // First window of a connection: no capture until the layout is applied.
  static DateTime? _waitUntil;
  // Peers whose first peer info this window has handled / whose layout it applied.
  static final Set<String> _seen = {};
  static final Set<String> _applied = {};

  static bool get _isRemoteDesktopWindow =>
      isDesktop && kWindowType == WindowType.RemoteDesktop && kWindowId != null;

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static Future<List<Rect>> _localScreens() async {
    final screens = await getScreenRectList();
    screens.sort((a, b) =>
        a.left != b.left ? a.left.compareTo(b.left) : a.top.compareTo(b.top));
    _screens = screens;
    return screens;
  }

  static String _signature(List<Rect> screens) {
    final parts = screens
        .map((r) =>
            '${r.width.round()}x${r.height.round()}@${r.left.round()},${r.top.round()}')
        .toList()
      ..sort();
    return parts.join('|');
  }

  // FNV-1a, 32 bit: short stable key for the screen set.
  static String _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  static String _key(List<Rect> screens, int display) =>
      '$_prefix:${_hash(_signature(screens))}:$display';

  static SkyDisplayPlacement? _read(
          String peerId, List<Rect> screens, int display) =>
      SkyDisplayPlacement.decode(bind.mainGetPeerFlutterOptionSync(
          id: peerId, k: _key(screens, display)));

  static void _write(String peerId, List<Rect> screens, int display,
          SkyDisplayPlacement? p) =>
      bind.mainSetPeerFlutterOptionSync(
          id: peerId, k: _key(screens, display), v: p?.encode() ?? '');

  static void _withScreens(void Function(List<Rect> screens) fn) {
    final s = _screens;
    if (s != null) {
      try {
        fn(s);
      } catch (e) {
        debugPrint('sky display layout: write failed: $e');
      }
      return;
    }
    _localScreens().then(fn).catchError((e) {
      debugPrint('sky display layout: write failed: $e');
    });
  }

  static DesktopTabController? _tabController() {
    final c = _controller;
    if (c != null) return c;
    try {
      if (Get.isRegistered<DesktopTabController>()) {
        return Get.find<DesktopTabController>();
      }
    } catch (e) {
      debugPrint('sky display layout: no tab controller: $e');
    }
    return null;
  }

  static FFI? _ffiOf(TabInfo tab) {
    final page = tab.page;
    if (page is! RemotePage) return null;
    try {
      return page.ffi;
    } catch (e) {
      return null;
    }
  }

  /// The local screen the window is on: the one containing its centre.
  static int? _screenOf(Rect frame, List<Rect> screens) {
    final c = frame.center;
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].contains(c)) return i;
    }
    return null;
  }

  // ---------------------------------------------------------------- hooks --

  /// A remote-desktop window got a session tab. `display` is set when the
  /// window was opened for one display of an already connected peer.
  static void onWindowSession(int? display) {
    if (!_isRemoteDesktopWindow) return;
    _openedForDisplay = display != null;
    _waitUntil =
        display == null ? DateTime.now().add(const Duration(minutes: 1)) : null;
  }

  /// The frame of a remote-desktop window changed (move, resize, fullscreen).
  static void onWindowFrameChanged(DesktopTabController controller) {
    if (!_isRemoteDesktopWindow) return;
    _controller = controller;
    _scheduleCapture();
  }

  /// The user switched the display shown in a tab (toolbar): the old display
  /// is no longer shown here, the new one takes the window's place.
  static void onDisplaySwitched(String peerId, int oldDisplay, int newDisplay) {
    if (!_isRemoteDesktopWindow || oldDisplay == newDisplay) return;
    if (oldDisplay >= 0) {
      _withScreens((screens) => _write(peerId, screens, oldDisplay, null));
    }
    _scheduleCapture();
  }

  /// The page of a session goes away. `closeSession` is false when the session
  /// only moves to another window.
  static void onSessionClosed(FFI ffi, bool closeSession) {
    if (!_isRemoteDesktopWindow) return;
    final peerId = ffi.id;
    final pi = ffi.ffiModel.pi;
    _seen.remove(peerId);
    _applied.remove(peerId);
    _waitUntil = null;
    if (!closeSession || !pi.isSet.value) return;
    final d = pi.currentDisplay;
    if (d < 0) return;
    final now = _nowSeconds();
    _withScreens((screens) {
      final p = _read(peerId, screens, d);
      if (p != null) _write(peerId, screens, d, p.withClosedAt(now));
    });
  }

  static void _scheduleCapture() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), _capture);
  }

  static Future<void> _capture() async {
    if (!_isRemoteDesktopWindow || stateGlobal.isMinimized) return;
    final waitUntil = _waitUntil;
    if (waitUntil != null && DateTime.now().isBefore(waitUntil)) return;
    final controller = _tabController();
    if (controller == null) return;
    try {
      final frame =
          await WindowController.fromWindowId(stateGlobal.windowId).getFrame();
      if (frame.width <= 0 || frame.height <= 0) return;
      final screens = await _localScreens();
      final k = _screenOf(frame, screens);
      if (k == null) return; // minimized or off-screen
      final s = screens[k];
      final place = SkyDisplayPlacement(
          k,
          stateGlobal.fullscreen.value,
          (frame.left - s.left) / s.width,
          (frame.top - s.top) / s.height,
          frame.width / s.width,
          frame.height / s.height);
      for (final tab in controller.state.value.tabs) {
        final ffi = _ffiOf(tab);
        if (ffi == null || ffi.closed) continue;
        final pi = ffi.ffiModel.pi;
        if (!pi.isSet.value) continue;
        final d = pi.currentDisplay;
        if (d < 0 || d >= pi.displays.length) continue;
        _write(ffi.id, screens, d, place);
      }
    } catch (e) {
      debugPrint('sky display layout: capture failed: $e');
    }
  }

  /// Called for every peer info. At the first one of a fresh connection in the
  /// first window it restores the saved layout: this window takes its display
  /// and place, the other displays open in their own windows. Returns true when
  /// the layout is ours, so the caller skips the upstream "use all my displays".
  static Future<bool> tryApply(FfiModel model, String peerId,
      {required bool isCache}) async {
    if (!_isRemoteDesktopWindow) return false;
    try {
      if (isCache || _openedForDisplay) return false;
      // Reconnect in the same window: keep what is on the screen now.
      if (_seen.contains(peerId)) return _applied.contains(peerId);
      _seen.add(peerId);
      final pi = model.pi;
      if (!pi.isSupportMultiDisplay || pi.displays.length <= 1) return false;
      final screens = await _localScreens();
      if (screens.isEmpty) return false;

      final records = <int, SkyDisplayPlacement>{};
      for (var d = 0; d < pi.displays.length; d++) {
        final p = _read(peerId, screens, d);
        if (p != null && p.screen < screens.length) records[d] = p;
      }
      if (records.isEmpty) return false;
      final open = Map<int, SkyDisplayPlacement>.fromEntries(
          records.entries.where((e) => e.value.closedAt == null));
      final Map<int, SkyDisplayPlacement> chosen;
      if (open.isNotEmpty) {
        chosen = open;
      } else {
        var last = 0;
        for (final p in records.values) {
          if (p.closedAt! > last) last = p.closedAt!;
        }
        chosen = Map<int, SkyDisplayPlacement>.fromEntries(records.entries
            .where((e) => e.value.closedAt! >= last - _endOfSessionSeconds));
      }
      // Shown again in this session: if it ends without closing them, they stay.
      for (final e in chosen.entries) {
        _write(peerId, screens, e.key, e.value.withClosedAt(null));
      }

      final d0 = chosen.containsKey(pi.currentDisplay)
          ? pi.currentDisplay
          : chosen.keys.first;
      if (d0 != pi.currentDisplay) {
        bind.sessionSwitchDisplay(
          isDesktop: isDesktop,
          sessionId: model.sessionId,
          value: Int32List.fromList([d0]),
        );
        model.switchToNewDisplay(d0, model.sessionId, peerId);
      }
      // Our choice is the user's last choice: no upstream monitor restore.
      model.lastUserDisplay = d0;
      model.cancelPendingRestoreTimer();
      model.pendingMonitorRestore = null;

      final controller = _tabController();
      if (controller == null || controller.length <= 1) {
        final p0 = chosen[d0]!;
        await _placeThisWindow(p0.rectOn(screens[p0.screen]), p0.fullscreen);
      }
      for (final e in chosen.entries) {
        if (e.key == d0) continue;
        openMonitorInNewTabOrWindow(e.key, peerId, pi,
            screenRect: e.value.rectOn(screens[e.value.screen]),
            screenRectFullscreen: e.value.fullscreen);
      }
      _applied.add(peerId);
      debugPrint(
          'sky display layout: applied ${chosen.length} display(s) for $peerId');
      return true;
    } catch (e) {
      debugPrint('sky display layout: apply failed: $e');
      return false;
    } finally {
      _waitUntil = null;
      _scheduleCapture();
    }
  }

  static Future<void> _placeThisWindow(Rect r, bool fullscreen) async {
    final wc = WindowController.fromWindowId(stateGlobal.windowId);
    if (stateGlobal.fullscreen.value) {
      stateGlobal.setFullscreen(false);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (await wc.isMaximized()) {
      await wc.unmaximize();
    }
    if (fullscreen) {
      // Like tryMoveToScreenAndSetFullscreen(): a small window on that screen,
      // then fullscreen there.
      await wc.setFrame(Rect.fromLTWH(r.left + 30, r.top + 30, 600, 400));
      await Future.delayed(const Duration(milliseconds: 300));
      stateGlobal.setFullscreen(true);
    } else {
      await wc.setFrame(r);
    }
  }
}
