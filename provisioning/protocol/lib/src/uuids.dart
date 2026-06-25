/// The 128-bit GATT UUIDs for the whiteboard provisioning service.
///
/// These are a private, randomly-chosen 128-bit range — deliberately *not* in
/// the Bluetooth SIG `0000xxxx-0000-1000-8000-00805f9b34fb` block — so they
/// won't collide with standard services. The trailing group encodes the
/// characteristic index. UUIDs are lowercase; butane compares case-insensitively
/// but we normalize to be safe.
class WhiteboardGatt {
  WhiteboardGatt._();

  /// Primary service advertised by the Pi.
  static const String service = 'b9a7f4e0-1c3d-4b6a-9e21-7f5c2a8d0001';

  /// Read: device identity + current connection (a [DeviceInfo] JSON blob).
  static const String info = 'b9a7f4e0-1c3d-4b6a-9e21-7f5c2a8d0002';

  /// Write: an app→Pi [Command] JSON blob (scan / provision / forget).
  static const String command = 'b9a7f4e0-1c3d-4b6a-9e21-7f5c2a8d0003';

  /// Read + notify: live [StatusReport] JSON as provisioning progresses.
  static const String status = 'b9a7f4e0-1c3d-4b6a-9e21-7f5c2a8d0004';

  /// Read + notify: the Wi-Fi scan list, streamed as chunk frames (see
  /// [ChunkAssembler]) because a full list exceeds the BLE notification MTU.
  static const String networks = 'b9a7f4e0-1c3d-4b6a-9e21-7f5c2a8d0005';

  /// The friendly name the Pi advertises (used as a scan filter fallback). Kept
  /// short so it fits alongside the 128-bit service UUID in the 31-byte adv
  /// packet; the human label is also available via the [info] characteristic.
  static const String advertisedName = 'Whiteboard-Setup';
}
