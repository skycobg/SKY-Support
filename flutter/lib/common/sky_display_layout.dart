// SKY Support: monitor layout per peer ("Подредба на мониторите").
//
// Remembers, for every peer and for the current set of local screens, on which
// local screen (and where on it) each remote display is shown, and restores
// that layout automatically on the next connection. Nothing to click: the
// layout is captured whenever a remote-desktop window is moved, resized or
// switched to/from fullscreen, and forgotten when the user closes a display
// window. Different sets of local screens (docked / laptop only) are kept
// apart automatically.
//
// Storage: one peer flutter option per remote display,
//   key   `sky-dl:<hash of local screen set>:<display index>`
//   value `<local screen index>;<1 if fullscreen else 0>;<l>;<t>;<w>;<h>`
// where l, t, w, h are the window rect as fractions of the local screen.
// Separate keys per display avoid read-modify-write races between windows
// (every remote-desktop window is its own Flutter engine).
//
// Design note: docs/2026-10-20-display-layout.md in the SKY Support project.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';

/// Where one remote display sits on the local screens.
class SkyDisplayPlacement {
  final int screen;
  final bool fullscreen;
  // Window rect as fractions of the local screen rect.
  final double l, t, w, h;

  const SkyDisplayPlacement(
      this.screen, this.fullscreen, this.l, this.t, this.w, this.h);

  String encode() =>
      '$screen;${fullscreen ? 1 : 0};${_f(l)};${_f(t)};${_f(w)};${_f(h)}';

  static String _f(double v) => v.toStringAsFixed(4);

  static SkyDisplayPlacement? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    final p = s.split(';');
    if (p.length != 6) return null;
    final screen = int.tryParse(p[0]);
    final nums = p.sublist(2).map(double.tryParse).toList();
    if (screen == null || screen < 0 || nums.any((e) => e == null)) {
      return null;
    }
    return SkyDisplayPlacement(
        screen, p[1] == '1', nums[0]!, nums[1]!, nums[2]!, nums[3]!);
  }

  Rect rectOn(Rect screen) => Rect.fromLTWH(
      screen.left + l * screen.width,
      screen.top + t * screen.height,
      w * screen.width,
      h * screen.height);
}

class SkyDisplayLayout {
  static const _prefix = 'sky-dl';
  static Timer? _debounce;
  static DesktopTabController? _controller;

  /// Signature of the current set of local screens: sorted `WxH@L,T` list.
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

  static String _key(String sig, int display) =>
      '$_prefix:${_hash(sig)}:$display';

  static bool get _isRemoteDesktopWindow =>
      isDesktop && kWindowType == WindowType.RemoteDesktop && kWindowId != null;

  /// The local screen the window is on: the one containing its centre, else the
  /// nearest one.
  static int _screenOf(Rect frame, List<Rect> screens) {
    final c = frame.center;
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].contains(c)) return i;
    }
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < screens.length; i++) {
      final d = (screens[i].center - c).distanceSquared;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  /// Called by the tab bar of a remote-desktop window whenever its frame
  /// changes (move, resize, maximize, fullscreen).
  static void onWindowFrameChanged(DesktopTabController controller) {
    if (!_isRemoteDesktopWindow) return;
    _controller = controller;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), _capture);
  }

  /// Called when the display shown by a session changes (menu "Display").
  /// The old display is no longer on this window, so its record goes away;
  /// the new one is captured with the window's current frame.
  static void onDisplaySwitched(String peerId, int oldDisplay, int newDisplay) {
    if (!_isRemoteDesktopWindow || oldDisplay == newDisplay) return;
    if (oldDisplay >= 0) forget(peerId, oldDisplay);
    final c = _controller;
    if (c != null) onWindowFrameChanged(c);
  }

  /// Called when the user closes a window that was opened for one display
  /// (close button of the window or of its tab). A lost connection does not
  /// come here, so it keeps the layout.
  static void onUserClosed(DesktopTabController controller) {
    if (!_isRemoteDesktopWindow) return;
    _debounce?.cancel();
    for (final tab in controller.state.value.tabs) {
      final page = tab.page;
      if (page is! RemotePage) continue;
      final ffi = page.ffi;
      final pi = ffi.ffiModel.pi;
      if (ffi.closed || !pi.isSet.value) continue;
      if (pi.currentDisplay >= 0) forget(ffi.id, pi.currentDisplay);
    }
  }

  static Future<void> forget(String peerId, int display) async {
    try {
      final screens = await getScreenRectList();
      if (screens.isEmpty) return;
      bind.mainSetPeerFlutterOptionSync(
          id: peerId, k: _key(_signature(screens), display), v: '');
    } catch (e) {
      debugPrint('sky display layout: forget failed: $e');
    }
  }

  static Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !_isRemoteDesktopWindow) return;
    try {
      final wc = WindowController.fromWindowId(kWindowId!);
      final frame = await wc.getFrame();
      if (frame.width <= 0 || frame.height <= 0) return;
      final screens = await getScreenRectList();
      if (screens.isEmpty) return;
      final k = _screenOf(frame, screens);
      final s = screens[k];
      final fullscreen = stateGlobal.fullscreen.isTrue;
      final place = fullscreen
          ? SkyDisplayPlacement(k, true, 0, 0, 1, 1)
          : SkyDisplayPlacement(
              k,
              false,
              (frame.left - s.left) / s.width,
              (frame.top - s.top) / s.height,
              frame.width / s.width,
              frame.height / s.height);
      final sig = _signature(screens);
      for (final tab in controller.state.value.tabs) {
        final page = tab.page;
        if (page is! RemotePage) continue;
        final ffi = page.ffi;
        final pi = ffi.ffiModel.pi;
        if (ffi.closed || !pi.isSet.value) continue;
        final d = pi.currentDisplay;
        if (d < 0 || d >= pi.displays.length) continue;
        bind.mainSetPeerFlutterOptionSync(
            id: ffi.id, k: _key(sig, d), v: place.encode());
      }
    } catch (e) {
      debugPrint('sky display layout: capture failed: $e');
    }
  }

  /// At a fresh connection (first window of the peer): put the remote displays
  /// where they were last time on this set of local screens. Returns false
  /// when nothing is saved, so the caller keeps the upstream behaviour.
  static Future<bool> tryApply(FfiModel model, String peerId) async {
    if (!isDesktop) return false;
    final pi = model.pi;
    if (!pi.isSupportMultiDisplay || pi.displays.length <= 1) return false;
    try {
      final screens = await getScreenRectList();
      if (screens.isEmpty) return false;
      final sig = _signature(screens);
      final entries = <int, SkyDisplayPlacement>{};
      for (var d = 0; d < pi.displays.length; d++) {
        final p = SkyDisplayPlacement.decode(
            bind.mainGetPeerFlutterOptionSync(id: peerId, k: _key(sig, d)));
        if (p != null && p.screen < screens.length) entries[d] = p;
      }
      if (entries.isEmpty) return false;

      // This window shows the current display if it is saved, else the first
      // saved one.
      final d0 = entries.containsKey(pi.currentDisplay)
          ? pi.currentDisplay
          : entries.keys.first;
      if (d0 != pi.currentDisplay) {
        bind.sessionSwitchDisplay(
          isDesktop: isDesktop,
          sessionId: model.sessionId,
          value: Int32List.fromList([d0]),
        );
        pi.currentDisplay = d0;
        try {
          CurrentDisplayState.find(peerId).value = d0;
        } catch (e) {
          //
        }
      }
      // Our choice is the user's last choice: no upstream restore afterwards.
      model.lastUserDisplay = d0;
      model.cancelPendingRestoreTimer();
      model.pendingMonitorRestore = null;

      final p0 = entries[d0]!;
      await tryMoveToScreenAndSetFullscreen(p0.rectOn(screens[p0.screen]),
          fullscreen: p0.fullscreen);
      for (final e in entries.entries) {
        if (e.key == d0) continue;
        openMonitorInNewTabOrWindow(e.key, peerId, pi,
            screenRect: e.value.rectOn(screens[e.value.screen]),
            screenRectFullscreen: e.value.fullscreen);
      }
      debugPrint(
          'sky display layout: applied ${entries.length} display(s) for $peerId');
      return true;
    } catch (e) {
      debugPrint('sky display layout: apply failed: $e');
      return false;
    }
  }
}
