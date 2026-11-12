import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_mount.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';

class QuarkAccountLoader extends StatefulWidget {
  const QuarkAccountLoader({super.key, required this.mount, this.draft = false, required this.builder});

  final StorageMount mount;
  final bool draft;
  final AsyncWidgetBuilder<QuarkAccountInfo?> builder;

  @override
  State<QuarkAccountLoader> createState() => _QuarkAccountLoaderState();
}

class _QuarkAccountLoaderState extends State<QuarkAccountLoader> {
  late Future<QuarkAccountInfo?> _account;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _account = _loadAccount();
  }

  @override
  void didUpdateWidget(QuarkAccountLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.mount;
    final current = widget.mount;
    if (oldWidget.draft != widget.draft ||
        (!widget.draft && old.id != current.id) ||
        old.configString(MountKeys.quarkMode) != current.configString(MountKeys.quarkMode) ||
        old.secret(MountKeys.secretCookie) != current.secret(MountKeys.secretCookie)) {
      _account = _loadAccount();
    }
  }

  Future<QuarkAccountInfo?> _loadAccount() async {
    final request = ++_request;
    final mount = widget.mount;
    if (!widget.draft) {
      final driver = context.read<MountManager>().driverFor(mount);
      return driver is QuarkStorageDriver ? driver.accountInfo() : null;
    }

    // A manually entered cookie can change as the user types. Keep unsaved
    // credentials out of the shared mount driver.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || request != _request) return null;
    final driver = QuarkStorageDriver.fromMount(mount);
    try {
      return await driver.accountInfo();
    } finally {
      await driver.close();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<QuarkAccountInfo?>(future: _account, builder: widget.builder);
}

class QuarkAccountDetails extends StatelessWidget {
  const QuarkAccountDetails({super.key, required this.snapshot});

  final AsyncSnapshot<QuarkAccountInfo?> snapshot;

  String _formatCapacity(int bytes) {
    const bytesPerTb = 1024 * 1024 * 1024 * 1024;
    return bytes >= bytesPerTb ? '${(bytes / bytesPerTb).toStringAsFixed(2)} TB' : ByteFormatter.formatBytes(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    if (snapshot.connectionState != ConnectionState.done) {
      return Text(t.storage.quarkAccountLoading, style: style);
    }
    final account = snapshot.data;
    final memberType = account?.memberType;
    final tier = switch (memberType) {
      'NORMAL' => t.storage.quarkMemberNormal,
      'VIP' => t.storage.quarkMemberVip,
      'SUPER_VIP' || 'SVIP' => t.storage.quarkMemberSuperVip,
      final other => other,
    };
    final isVip = switch (memberType) {
      'VIP' || 'SUPER_VIP' || 'SVIP' || 'MINI_VIP' || 'Z_VIP' => true,
      _ => false,
    };
    final vipColor = theme.brightness == Brightness.dark ? const Color(0xFFF3C875) : const Color(0xFF815300);
    final used = account?.usedBytes;
    final total = account?.totalBytes;
    final hasQuota = used != null && total != null && total > 0;
    if (tier == null && !hasQuota) {
      return Text(t.storage.quarkAccountUnavailable, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tier != null)
          Row(
            children: [
              if (isVip) ...[AppIcon(Symbols.diamond_rounded, size: 15, color: vipColor), const SizedBox(width: 4)],
              Flexible(
                child: Text(tier, style: isVip ? style?.copyWith(color: vipColor) : style),
              ),
            ],
          ),
        if (hasQuota) ...[
          if (tier != null) const SizedBox(height: 2),
          Text(
            t.storage.quarkAccountCapacity(used: _formatCapacity(used), total: _formatCapacity(total)),
            style: style,
          ),
          const SizedBox(height: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: LinearProgressIndicator(
              value: (used / total).clamp(0.0, 1.0),
              backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.22),
              minHeight: 5,
              borderRadius: const BorderRadius.all(Radius.circular(3)),
              trackGap: 0,
              stopIndicatorRadius: 0,
            ),
          ),
        ],
      ],
    );
  }
}
