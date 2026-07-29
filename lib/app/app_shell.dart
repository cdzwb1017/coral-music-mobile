import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/http_client.dart';
import '../features/player/view/mini_player.dart';
import '../features/update/data/app_update_service.dart';
import '../features/webdav/view/webdav_page.dart';
import 'app_theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    required this.navigationShell,
    super.key,
  });

  final StatefulNavigationShell navigationShell;
  static const _taskChannel = MethodChannel('coral_music/app_task');

  static const _mobileDestinations = [
    _ShellDestination('/leaderboard', '发现', Icons.home_outlined),
    _ShellDestination('/search', '搜索', Icons.search_outlined),
    _ShellDestination('/player', '播放', Icons.play_circle_outline),
    _ShellDestination('/more', '我的', Icons.person_outline),
  ];

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final _updates = AppUpdateService(createHttpClient());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_checkForUpdate()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final navigationShell = widget.navigationShell;
    final size = MediaQuery.sizeOf(context);
    final useNavigationRail = size.width >= 720 && size.height >= 720;
    final selectedIndex =
        navigationShell.currentIndex == 2 ? 3 : navigationShell.currentIndex;
    final content = useNavigationRail
        ? Row(
            children: [
              _CoralRail(
                selectedIndex: selectedIndex,
                onSelected: (index) => _go(context, index),
              ),
              VerticalDivider(
                width: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: navigationShell),
            ],
          )
        : navigationShell;

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (GoRouterState.of(context).uri.path == '/webdav') {
            webDavSystemBackHandler.value?.call();
            return;
          }
          shouldMoveTaskToBack(navigationShell.currentIndex)
              ? _moveTaskToBack()
              : navigationShell.goBranch(0);
        }
      },
      child: Scaffold(
        // Keep the live mini player above the bottom navigation on phones.
        extendBody: false,
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: coralPageGradientOf(context)),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(child: content),
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: MiniPlayer(),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: useNavigationRail
            ? null
            : _CoralBottomBar(
                selectedIndex: selectedIndex,
                onSelected: (index) => _go(context, index),
              ),
      ),
    );
  }

  Future<void> _moveTaskToBack() async {
    try {
      await AppShell._taskChannel.invokeMethod<void>('moveTaskToBack');
    } on MissingPluginException {
      // Only Android can move this task behind the launcher.
    }
  }

  void _go(BuildContext context, int index) {
    if (index == 2) {
      context.push('/player');
      return;
    }
    final branchIndex = index == 3 ? 2 : index;
    widget.navigationShell.goBranch(
      branchIndex,
      initialLocation: branchIndex == widget.navigationShell.currentIndex,
    );
  }

  Future<void> _checkForUpdate() async {
    final release = await _updates.checkForUpdate();
    if (!mounted ||
        release == null ||
        widget.navigationShell.currentIndex != 0) {
      return;
    }
    final action = await showDialog<_UpdateAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 ${release.title}'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(release.notes.trim().isEmpty
                ? '新版本已发布，是否立即更新？'
                : release.notes),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, _UpdateAction.ignore),
            child: const Text('不再提醒'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, _UpdateAction.cancel),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, _UpdateAction.update),
            child: Text(release.downloadUrl == null ? '前往 GitHub' : '更新'),
          ),
        ],
      ),
    );
    if (action == _UpdateAction.ignore) {
      await _updates.ignore(release);
      return;
    }
    if (action != _UpdateAction.update || !mounted) return;
    final started = release.downloadUrl == null
        ? await _updates.openRelease(release)
        : await _updates.downloadAndInstall(release);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(started
          ? release.downloadUrl == null
              ? '已打开 GitHub Release 页面'
              : '已开始后台下载，完成后将打开系统安装界面'
          : '操作失败，请稍后重试'),
    ));
  }
}

enum _UpdateAction { update, cancel, ignore }

bool shouldMoveTaskToBack(int branchIndex) => branchIndex == 0;

class _CoralRail extends StatelessWidget {
  const _CoralRail({required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NavigationRail(
      backgroundColor: scheme.surface,
      selectedIndex: selectedIndex,
      labelType: NavigationRailLabelType.all,
      indicatorColor: Colors.transparent,
      leading: const Padding(
        padding: EdgeInsets.only(top: 16, bottom: 24),
        child: _BrandMark(),
      ),
      destinations: [
        for (final item in AppShell._mobileDestinations)
          NavigationRailDestination(
            icon: Icon(item.icon),
            selectedIcon: Icon(item.icon),
            label: Text(item.label),
          ),
      ],
      onDestinationSelected: onSelected,
    );
  }
}

class _CoralBottomBar extends StatelessWidget {
  const _CoralBottomBar(
      {required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        height: 68,
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: .96),
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            for (var index = 0;
                index < AppShell._mobileDestinations.length;
                index++)
              Expanded(
                child: _BottomItem(
                  destination: AppShell._mobileDestinations[index],
                  selected: index == selectedIndex,
                  onTap: () => onSelected(index),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomItem extends StatelessWidget {
  const _BottomItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _ShellDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(destination.icon, size: 22, color: color),
          const SizedBox(height: 4),
          Text(
            destination.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.surface.withValues(alpha: .52),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          boxShadow: [
            BoxShadow(
              color:
                  Theme.of(context).colorScheme.shadow.withValues(alpha: .12),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          Icons.music_note_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
      );
}

class _ShellDestination {
  const _ShellDestination(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;
}
