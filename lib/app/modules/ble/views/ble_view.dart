import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../data/models/ble_device_model.dart';
import '../../../services/ble_discovery_service.dart';
import '../controllers/ble_controller.dart';

/// Full-featured BLE discovery and connection management page.
///
/// Displays Bluetooth status, role controls, nearby devices with signal
/// strength, and connected devices with real-time status updates.
class BleView extends GetView<BleController> {
  const BleView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Devices'),
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.black,
            size: 20,
          ),
          onPressed: () => Get.back(),
        ),
        actions: [
          // Bluetooth status indicator
          Obx(
            () => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Icon(
                Icons.bluetooth,
                color: controller.isBluetoothOn.value
                    ? colorScheme.primary
                    : colorScheme.error,
              ),
            ),
          ),
        ],
      ),
      body: Obx(
        () => Column(
          children: [
            // ── Status & Role Header ──
            _buildStatusHeader(context),

            // ── Error Banner ──
            if (controller.lastError.value.isNotEmpty)
              _buildErrorBanner(context),

            // ── Action Buttons ──
            _buildActionBar(context),

            const SizedBox(height: 8),

            // ── Device Lists ──
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  // Connected Devices Section
                  if (controller.connectedDevices.isNotEmpty) ...[
                    _buildSectionHeader(
                      context,
                      'Connected Devices',
                      Icons.link,
                    ),
                    ...controller.connectedDevices.map(
                      (device) =>
                          _buildDeviceTile(context, device, isConnected: true),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Nearby Devices Section
                  _buildSectionHeader(
                    context,
                    'Nearby Devices',
                    Icons.radar,
                    trailing: controller.isScanning.value
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                  ),
                  if (controller.discoveredDevices.isEmpty)
                    _buildEmptyState(context)
                  else
                    ...controller.discoveredDevices.map(
                      (device) => _buildDeviceTile(context, device),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Status Header
  // ---------------------------------------------------------------------------

  Widget _buildStatusHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(
        children: [
          // Bluetooth state
          Icon(
            controller.isBluetoothOn.value
                ? Icons.bluetooth_connected
                : Icons.bluetooth_disabled,
            size: 20,
            color: controller.isBluetoothOn.value
                ? colorScheme.primary
                : colorScheme.error,
          ),
          const SizedBox(width: 8),
          Text(
            controller.bluetoothStatusText,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: controller.isBluetoothOn.value
                  ? colorScheme.primary
                  : colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          // Role badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _roleColor(controller.currentRole.value, colorScheme),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              controller.roleText,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _roleColor(BleRole role, ColorScheme colorScheme) {
    switch (role) {
      case BleRole.host:
        return colorScheme.primary;
      case BleRole.client:
        return colorScheme.tertiary;
      case BleRole.none:
        return colorScheme.outline;
    }
  }

  // ---------------------------------------------------------------------------
  // Error Banner
  // ---------------------------------------------------------------------------

  Widget _buildErrorBanner(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: colorScheme.errorContainer,
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              controller.lastError.value,
              style: TextStyle(
                color: colorScheme.onErrorContainer,
                fontSize: 13,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close,
              size: 16,
              color: colorScheme.onErrorContainer,
            ),
            onPressed: () => controller.lastError.value = '',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Action Bar
  // ---------------------------------------------------------------------------

  Widget _buildActionBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          // Scan / Stop Scan
          _ActionChip(
            icon: controller.isScanning.value
                ? Icons.stop_circle_outlined
                : Icons.search,
            label: controller.isScanning.value ? 'Stop Scan' : 'Scan',
            onPressed: controller.isBluetoothOn.value
                ? (controller.isScanning.value
                      ? controller.stopScan
                      : controller.startScan)
                : null,
          ),

          // Refresh
          _ActionChip(
            icon: Icons.refresh,
            label: 'Refresh',
            onPressed: controller.isBluetoothOn.value
                ? controller.refreshScan
                : null,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section Header
  // ---------------------------------------------------------------------------

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon, {
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Empty State
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.bluetooth_searching,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              controller.isScanning.value
                  ? 'Scanning for nearby devices…'
                  : 'Tap Scan to find nearby devices',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Device Tile
  // ---------------------------------------------------------------------------

  Widget _buildDeviceTile(
    BuildContext context,
    BleDeviceModel device, {
    bool isConnected = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          controller.platformIcon(device.platform),
          color: colorScheme.primary,
        ),
        title: Text(
          device.name.isEmpty ? 'Unknown Device' : device.name,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Row(
          children: [
            // Connection state
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: controller.connectionColor(device.connectionState),
                shape: BoxShape.circle,
              ),
            ),
            Text(device.connectionState.name, style: theme.textTheme.bodySmall),
            const SizedBox(width: 12),
            // RSSI
            Icon(
              controller.rssiIcon(device.rssi),
              size: 14,
              color: colorScheme.outline,
            ),
            const SizedBox(width: 4),
            Text(
              '${device.rssi} dBm',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.outline,
              ),
            ),
          ],
        ),
        trailing: _buildConnectionButton(context, device, isConnected),
      ),
    );
  }

  Widget _buildConnectionButton(
    BuildContext context,
    BleDeviceModel device,
    bool isConnected,
  ) {
    if (device.connectionState == BleConnectionState.connecting) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (isConnected || device.connectionState == BleConnectionState.connected) {
      return TextButton(
        onPressed: () => controller.disconnectDevice(device.id),
        child: const Text('Disconnect'),
      );
    }

    return TextButton(
      onPressed: () => controller.connectToDevice(device.id),
      child: const Text('Connect'),
    );
  }
}

// -----------------------------------------------------------------------------
// Reusable action chip widget
// -----------------------------------------------------------------------------

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _ActionChip({required this.icon, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: colorScheme.surfaceContainerHighest,
        foregroundColor: colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
