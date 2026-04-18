import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

class AppBluetoothService {
  static const String serviceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String rxCharUuid =
      "6e400002-b5a3-f393-e0a9-e50e24dcca9e"; // Write
  static const String txCharUuid =
      "6e400003-b5a3-f393-e0a9-e50e24dcca9e"; // Notify

  static String? _connectedDeviceId;
  static StreamSubscription<BleDevice>? _scanSubscription;

  // Speichern des aktuellen Value-Change-Callbacks
  static OnValueChange? _currentValueChangeCallback;

  static Future<void> connectAndListen(
    void Function(String charUuid, Uint8List data) onDataReceived,
  ) async {
    try {
      await disconnect(); // Alte Verbindung sauber beenden

      final completer = Completer<BleDevice>();

      // Scan-Stream verwenden
      _scanSubscription = UniversalBle.scanStream.listen((BleDevice device) {
        if (!completer.isCompleted) {
          completer.complete(device);
        }
      });

      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [serviceUuid]),
      );

      final device = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw TimeoutException('Kein passendes Bluetooth-Gerät gefunden.'),
      );

      await UniversalBle.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;

      _connectedDeviceId = device.deviceId;

      await UniversalBle.connect(device.deviceId);
      debugPrint('Verbunden mit: ${device.name ?? device.deviceId}');

      // Services entdecken
      final services = await UniversalBle.discoverServices(device.deviceId);

      // Value Change Callback setzen
      _currentValueChangeCallback =
          (
            String deviceId, // Erster Parameter: deviceId
            String characteristicId, // Zweiter Parameter: characteristicId
            Uint8List value, // Dritter Parameter: value
            int? timestamp, // Vierter Parameter: timestamp (kann null sein)
          ) {
            if (deviceId == _connectedDeviceId) {
              onDataReceived(characteristicId, value);
            }
          };

      UniversalBle.onValueChange = _currentValueChangeCallback;

      // Notifications aktivieren
      bool nusFound = false;
      for (var service in services) {
        if (service.uuid.toLowerCase() == serviceUuid.toLowerCase()) {
          nusFound = true;
          for (var char in service.characteristics) {
            final charUuidLower = char.uuid.toLowerCase();

            if (charUuidLower == txCharUuid.toLowerCase() ||
                charUuidLower == rxCharUuid.toLowerCase()) {
              if (char.properties.contains(CharacteristicProperty.notify) ||
                  char.properties.contains(CharacteristicProperty.indicate)) {
                await UniversalBle.setNotifiable(
                  device.deviceId,
                  service.uuid,
                  char.uuid,
                  BleInputProperty.notification,
                );
                debugPrint('Notify aktiviert: ${char.uuid}');
              }
            }
          }
        }
      }

      if (!nusFound) {
        throw Exception('Nordic UART Service nicht gefunden!');
      }
    } catch (e) {
      debugPrint('Bluetooth Fehler: $e');
      await disconnect();
      rethrow;
    }
  }

  static Future<void> disconnect() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;

    if (_connectedDeviceId != null) {
      try {
        await UniversalBle.disconnect(_connectedDeviceId!);
      } catch (e) {
        debugPrint('Disconnect-Fehler: $e');
      }
      _connectedDeviceId = null;
    }

    // Callback entfernen
    if (_currentValueChangeCallback != null) {
      UniversalBle.onValueChange = null;
      _currentValueChangeCallback = null;
    }
  }

  static bool get isConnected => _connectedDeviceId != null;
}
