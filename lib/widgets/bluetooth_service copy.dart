import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_bluetooth/flutter_web_bluetooth.dart';

class AppBluetoothService {
  // Die UUIDs aus deinem funktionierenden Script
  static const String serviceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String luxCharUuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";

  /// Öffnet den Browser-Dialog zur Auswahl eines Bluetooth-Geräts
  static Future<BluetoothDevice> requestDevice() async {
    return await FlutterWebBluetooth.instance.requestDevice(
      RequestOptionsBuilder(
        [RequestFilterBuilder(name: 'LightDistance_Sensor')],
        optionalServices: [serviceUuid],
      ),
    );
  }

  /// Sucht nach passenden Charakteristiken und leitet Daten an den Callback weiter
  static Future<bool> discoverAndListen(
    BluetoothDevice device,
    void Function(String uuid, ByteData data) onDataReceived,
  ) async {
    // Sicherheitsprüfung: Warten, bis der Stream die Verbindung bestätigt
    final bool isConnected = await device.connected.first;
    if (!isConnected) {
      await device.connect();
      await device.connected.firstWhere((c) => c);
    }

    final services = await device.discoverServices();
    bool characteristicFound = false;

    for (var service in services) {
      final characteristics = await service.getCharacteristics();
      for (var char in characteristics) {
        debugPrint(
          'Suche Daten auf: ${char.uuid} (Notify: ${char.properties.notify}, Read: ${char.properties.read})',
        );
        if (char.properties.notify || char.properties.read) {
          if (char.properties.notify) {
            await char.startNotifications();
            char.value.listen((data) {
              // Wir geben die UUID mit, damit der Parser weiß, was er gerade liest
              onDataReceived(char.uuid, data);
            });
            debugPrint('Abonnement (Notify) erfolgreich für: ${char.uuid}');
          } else if (char.properties.read) {
            final value = await char.readValue();
            onDataReceived(char.uuid, value);
          }
          characteristicFound = true;
        }
      }
    }
    return characteristicFound;
  }
}
