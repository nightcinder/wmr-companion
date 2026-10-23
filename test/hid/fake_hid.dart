import 'dart:async';

import 'package:flutter/services.dart';
import 'package:wmr_companion_app/hid/hid_gamepad_transport.dart';

class FakeHid implements HidGamepadTransport {
  final _status = StreamController<HidStatus>.broadcast();
  final reports = <Uint8List>[];
  final calls = <String>[];
  bool failSend = false;

  @override
  Stream<HidStatus> get status => _status.stream;

  void emit(HidStatus s) => _status.add(s);

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> sendReport(Uint8List data) async {
    if (failSend) throw PlatformException(code: 'send');
    reports.add(data);
  }

  @override
  Future<List<HidHost>> bondedHosts() async => const [HidHost('PC', 'AA:BB')];

  @override
  Future<void> connect(String address) async => calls.add('connect $address');

  @override
  Future<void> disconnect() async => calls.add('disconnect');

  @override
  Future<void> requestDiscoverable() async => calls.add('discoverable');
}
