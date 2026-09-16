import 'dart:async';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一台可供投屏的 DLNA 媒体渲染器。
class DlnaCastDevice {
  const DlnaCastDevice({
    required this.id,
    required this.name,
    required this.host,
  });

  /// 设备描述文档地址，作为稳定标识。
  final String id;

  /// 设备展示名（电视通常带品牌与型号）。
  final String name;

  /// 设备所在主机，手动投屏时用于复用同一链路。
  final String host;

  @override
  bool operator ==(Object other) => other is DlnaCastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 投屏流程所处阶段。
enum DlnaCastPhase {
  /// 未开始搜索。
  idle,

  /// 正在搜索局域网设备。
  searching,

  /// 搜索告一段落（结果可能为空，可再次刷新）。
  ready,

  /// 正在连接设备并推送播放地址。
  connecting,

  /// 已成功投屏播放。
  casting,
}

class DlnaCastState {
  const DlnaCastState({
    this.phase = DlnaCastPhase.idle,
    this.devices = const <DlnaCastDevice>[],
    this.castingDevice,
    this.error,
  });

  final DlnaCastPhase phase;
  final List<DlnaCastDevice> devices;

  /// 当前投屏目标；为空表示未投屏。
  final DlnaCastDevice? castingDevice;
  final String? error;

  bool get scanning =>
      phase == DlnaCastPhase.searching || phase == DlnaCastPhase.connecting;

  bool get casting => castingDevice != null;

  DlnaCastState copyWith({
    DlnaCastPhase? phase,
    List<DlnaCastDevice>? devices,
    DlnaCastDevice? castingDevice,
    bool clearCasting = false,
    String? error,
    bool clearError = false,
  }) {
    return DlnaCastState(
      phase: phase ?? this.phase,
      devices: devices ?? this.devices,
      castingDevice: clearCasting
          ? null
          : (castingDevice ?? this.castingDevice),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// DLNA 投屏控制器：搜索设备、推送播放地址、停止投屏。
///
/// 搜索走 SSDP 组播，需要在 Info.plist 声明本地网络权限；系统屏蔽组播时
/// （例如 iOS 未申请 Apple 组播权限）可用 [castToAddress] 手动指定电视 IP。
class DlnaCastNotifier extends Notifier<DlnaCastState> {
  DLNAManager? _manager;
  DLNADevice? _device;
  StreamSubscription? _subscription;
  Timer? _scanTimeout;
  final Map<String, DLNADevice> _known = {};

  @override
  DlnaCastState build() {
    ref.onDispose(_teardown);
    return const DlnaCastState();
  }

  /// 开始新一轮搜索：保留上轮结果先展示，再追加 6 秒内新响应的设备。
  Future<void> discover() async {
    final casting = state.castingDevice;
    final previous = state.devices;
    _teardown();
    state = DlnaCastState(
      phase: DlnaCastPhase.searching,
      devices: previous,
      castingDevice: casting,
    );
    if (await _multicastBlocked()) {
      state = state.copyWith(
        phase: DlnaCastPhase.ready,
        error: '当前系统屏蔽了局域网组播搜索，请手动输入电视 IP 投屏',
      );
      return;
    }
    final started = runZonedGuarded<Future<DLNAManager>>(() async {
      final manager = DLNAManager();
      final devices = await manager.start(reusePort: true);
      _manager = manager;
      _subscription = devices.devices.stream.listen(_onDevices);
      return manager;
    }, (error, stack) => _onZoneError(error));
    if (started == null) {
      state = state.copyWith(
        phase: DlnaCastPhase.ready,
        error: '搜索设备失败，可手动输入电视 IP',
      );
      return;
    }
    try {
      await started;
    } catch (e) {
      state = state.copyWith(phase: DlnaCastPhase.ready, error: '搜索设备失败：$e');
      return;
    }
    _scanTimeout = Timer(const Duration(seconds: 6), () {
      if (state.phase != DlnaCastPhase.searching) return;
      final empty = state.devices.isEmpty;
      state = state.copyWith(
        phase: DlnaCastPhase.ready,
        error: empty ? '未发现电视，请确认与本机处于同一 Wi-Fi' : null,
        clearError: !empty,
      );
    });
  }

  /// 停止搜索并释放组播端口；正在投屏的连接会保留。
  void stopDiscovery() {
    final casting = state.castingDevice;
    _teardown();
    state = DlnaCastState(
      phase: casting == null ? DlnaCastPhase.idle : DlnaCastPhase.casting,
      castingDevice: casting,
    );
  }

  /// 投屏到指定设备：推送地址成功后立即开播。
  Future<String?> cast(
    DlnaCastDevice target, {
    required String url,
    required String title,
  }) async {
    if (url.trim().isEmpty) return '播放地址还没准备好，请稍后再试';
    state = state.copyWith(
      phase: DlnaCastPhase.connecting,
      castingDevice: target,
      clearError: true,
    );
    var device = _device;
    if (device == null || deviceIdOf(device) != target.id) {
      device = _known[target.id];
      if (device == null) {
        // 搜索结果已被清理或来自手动输入，按描述地址重新获取一次。
        final info = await fetchDeviceInfo(target.host, hint: target.id);
        device = info == null ? null : DLNADevice(info);
      }
      _device = device;
    }
    if (device == null) {
      state = state.copyWith(
        phase: DlnaCastPhase.ready,
        clearCasting: true,
        error: '连接设备失败，请重试',
      );
      return '连接设备失败，请重试';
    }
    try {
      await device.setUrl(url, title: title, type: mimeOf(url));
      await device.play();
      state = state.copyWith(phase: DlnaCastPhase.casting, clearError: true);
      return null;
    } catch (_) {
      state = state.copyWith(
        phase: DlnaCastPhase.ready,
        clearCasting: true,
        error: '投屏失败，请检查电视是否支持该地址',
      );
      return '投屏失败，请检查电视是否支持该地址';
    }
  }

  /// 手动指定电视 IP 投屏：不依赖组播，适合系统屏蔽搜索的场景。
  Future<String?> castToAddress(
    String address, {
    required String url,
    required String title,
  }) async {
    final host = address.trim();
    if (host.isEmpty) return '请输入电视 IP';
    if (url.trim().isEmpty) return '播放地址还没准备好，请稍后再试';
    state = state.copyWith(phase: DlnaCastPhase.connecting, clearError: true);
    final info = await fetchDeviceInfo(host);
    if (info == null) {
      state = state.copyWith(
        phase: DlnaCastPhase.ready,
        error: '该地址未返回 DLNA 设备信息，请核对电视 IP',
      );
      return '该地址未返回 DLNA 设备信息，请核对电视 IP';
    }
    final device = DLNADevice(info);
    _device = device;
    final target = DlnaCastDevice(
      id: deviceIdOf(device),
      name: info.friendlyName.trim().isEmpty ? host : info.friendlyName.trim(),
      host: host,
    );
    _known[target.id] = device;
    state = state.copyWith(
      castingDevice: target,
      devices: _mergeDevice(target),
    );
    return cast(target, url: url, title: title);
  }

  /// 停止投屏并断开当前设备。
  Future<void> stopCasting() async {
    final device = _device;
    _device = null;
    if (device != null) {
      try {
        await device.stop();
      } catch (_) {
        // 电视已离线或拒绝指令时忽略，界面照常复位。
      }
      device.dispose();
    }
    state = state.copyWith(
      phase: state.devices.isEmpty ? DlnaCastPhase.idle : DlnaCastPhase.ready,
      clearCasting: true,
      clearError: true,
    );
  }

  // ==================== 内部实现 ====================

  List<DlnaCastDevice> _mergeDevice(DlnaCastDevice target) {
    if (state.devices.contains(target)) return state.devices;
    return [...state.devices, target];
  }

  void _onDevices(Map<String, DLNADevice> deviceList) {
    final devices = <DlnaCastDevice>[];
    for (final entry in deviceList.entries) {
      final info = entry.value.info;
      if (!isRenderer(info)) continue;
      _known[entry.key] = entry.value;
      devices.add(
        DlnaCastDevice(
          id: entry.key,
          name: deviceNameOf(info),
          host: Uri.tryParse(info.URLBase)?.host ?? '',
        ),
      );
    }
    state = state.copyWith(
      devices: devices,
      phase: state.casting ? DlnaCastPhase.casting : DlnaCastPhase.searching,
    );
  }

  void _onZoneError(Object error) {
    if (state.phase != DlnaCastPhase.searching) return;
    state = state.copyWith(
      phase: DlnaCastPhase.ready,
      error: '搜索被系统中断，可手动输入电视 IP',
    );
  }

  /// 探测本机能否向组播地址发包：iOS 未申请组播权限时会直接失败。
  Future<bool> _multicastBlocked() async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(const [0], InternetAddress('239.255.255.250'), 1900);
      return false;
    } catch (_) {
      return true;
    } finally {
      socket?.close();
    }
  }

  void _teardown() {
    _scanTimeout?.cancel();
    _scanTimeout = null;
    _subscription?.cancel();
    _subscription = null;
    _manager?.stop();
    _manager = null;
    _known.clear();
  }
}

/// 设备描述地址，作为设备唯一标识。
String deviceIdOf(DLNADevice device) => device.info.URLBase;

/// 设备展示名：优先用 friendlyName，缺失时退回主机名。
String deviceNameOf(DeviceInfo info) {
  final name = info.friendlyName.trim();
  if (name.isNotEmpty) return name;
  return Uri.tryParse(info.URLBase)?.host ?? '未知设备';
}

/// 设备是否提供 AVTransport：路由器、NAS 等无关设备会被过滤掉。
bool isRenderer(DeviceInfo info) {
  final hasTransport = info.serviceList.any(
    (service) =>
        service['serviceType']?.toString().contains('AVTransport') ?? false,
  );
  return hasTransport || info.deviceType.contains('MediaRenderer');
}

/// 按地址猜测协议类型，帮助电视正确识别 HLS 流。
PlayType mimeOf(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  if (path.endsWith('.m3u8')) return VideoMime.hls;
  if (path.endsWith('.mp4')) return VideoMime.mp4;
  if (path.endsWith('.ts')) return VideoMime.ts;
  return VideoMime.any;
}

/// 拉取并解析设备描述文档；[hint] 为已知描述地址时优先直连。
///
/// 手动投屏无法从组播拿到 LOCATION，因此按 DLNA 常见端口与路径依次探测。
Future<DeviceInfo?> fetchDeviceInfo(String host, {String? hint}) async {
  final candidates = <Uri>[
    if (hint != null && hint.isNotEmpty)
      if (Uri.tryParse(hint) != null) Uri.parse(hint),
    for (final port in const [1400, 49152, 80, 9197])
      for (final path in const [
        '/description.xml',
        '/dmr.xml',
        '/rootDesc.xml',
        '/upnp/desc.xml',
        '/',
      ])
        Uri.parse('http://$host:$port$path'),
  ];
  for (final uri in candidates) {
    try {
      final body = await DLNAHttp.get(uri);
      final info = DeviceInfoParser(body).parse(uri);
      if (isRenderer(info)) return info;
    } catch (_) {
      // 端口与路径不匹配是常态，继续尝试下一个候选地址。
    }
  }
  return null;
}

final dlnaCastProvider = NotifierProvider<DlnaCastNotifier, DlnaCastState>(
  DlnaCastNotifier.new,
);
