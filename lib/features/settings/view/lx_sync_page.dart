import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_back_navigation.dart';
import '../../library/data/lx_sync_service.dart';
import '../../library/state/library_controller.dart';

enum _LxStatus { disabled, connecting, syncing, completed, error }

class LxSyncPage extends ConsumerStatefulWidget {
  const LxSyncPage({super.key});

  @override
  ConsumerState<LxSyncPage> createState() => _LxSyncPageState();
}

class _LxSyncPageState extends ConsumerState<LxSyncPage> {
  final _host = TextEditingController();
  final _code = TextEditingController();
  var _enabled = false;
  var _showCode = false;
  var _status = _LxStatus.disabled;
  var _statusMessage = '同步已关闭';
  var _statusDetail = '打开开关后，使用客户端地址连接落雪同步服务。';
  var _working = false;

  @override
  void dispose() {
    _host.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 20, 24),
      children: [
        Row(children: [
          const AppBackButton(),
          Text('同步',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  )),
        ]),
        const SizedBox(height: 18),
        _Section(
          title: '启用同步',
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: _working ? null : _setEnabled,
            title: const Text('启用落雪列表同步'),
            subtitle: const Text('移动端作为客户端连接已配置的同步服务'),
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '同步模式',
          child: SegmentedButton<String>(
            selected: const {'client'},
            segments: const [
              ButtonSegment(
                value: 'server',
                label: Text('服务端'),
                icon: Icon(Icons.dns_outlined),
                enabled: false,
              ),
              ButtonSegment(
                value: 'client',
                label: Text('客户端'),
                icon: Icon(Icons.phone_android_outlined),
              ),
            ],
            onSelectionChanged: (_) {},
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '客户端地址',
          child: TextField(
            controller: _host,
            enabled: !_working && !_enabled,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: '请输入同步服务地址，例如 https://example.com',
              prefixIcon: Icon(Icons.link_outlined),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '连接码',
          child: TextField(
            controller: _code,
            enabled: !_working,
            obscureText: !_showCode,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: '首次配对时输入；成功后可留空',
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                tooltip: _showCode ? '隐藏连接码' : '显示连接码',
                onPressed: () => setState(() => _showCode = !_showCode),
                icon: Icon(
                  _showCode
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _StatusPanel(
          status: _status,
          title: _statusMessage,
          detail: _statusDetail,
          color: colors,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _working || _enabled ? null : _connect,
                icon: _working
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(_working ? '正在连接…' : '连接并同步'),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed:
                  _working || !_enabled ? null : () => _setEnabled(false),
              icon: const Icon(Icons.link_off_outlined),
              label: const Text('断开'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '同步只会将远端列表和收藏合并到本机，不会删除本机资料或写回覆盖服务端。连接码仅用于首次配对，凭据保存在系统安全存储中。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _setEnabled(bool enabled) async {
    if (!enabled) {
      setState(() {
        _enabled = false;
        _status = _LxStatus.disabled;
        _statusMessage = '同步已关闭';
        _statusDetail = '下次打开开关时将重新连接。';
      });
      return;
    }
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() {
        _status = _LxStatus.error;
        _statusMessage = '未连接';
        _statusDetail = '请先填写客户端地址。';
      });
      return;
    }
    setState(() => _enabled = true);
    await _sync();
  }

  Future<void> _connect() async {
    if (_host.text.trim().isEmpty) {
      setState(() {
        _status = _LxStatus.error;
        _statusMessage = '未连接';
        _statusDetail = '请先填写客户端地址。';
      });
      return;
    }
    setState(() => _enabled = true);
    await _sync();
  }

  Future<void> _sync() async {
    setState(() {
      _working = true;
      _status = _LxStatus.connecting;
      _statusMessage = '正在连接';
      _statusDetail = '正在检查服务地址并验证连接码…';
    });
    try {
      final snapshot = await LxSyncService().pull(
        host: _host.text,
        connectionCode: _code.text,
      );
      if (!mounted) return;
      setState(() {
        _status = _LxStatus.syncing;
        _statusMessage = '正在同步';
        _statusDetail = '已连接服务，正在读取远端列表并合并到本机…';
      });
      _code.clear();
      final result =
          await ref.read(libraryProvider.notifier).importLxSnapshot(snapshot);
      if (!mounted || result == null) return;
      setState(() {
        _status = _LxStatus.completed;
        _statusMessage = '同步完成';
        _statusDetail =
            '新增 ${result.playlists} 个列表、${result.tracks} 首歌曲、${result.favorites} 首收藏。';
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '已合并：${result.playlists} 个列表、${result.tracks} 首歌曲、${result.favorites} 首收藏。',
        ),
      ));
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _LxStatus.error;
        _statusMessage = '连接失败';
        _statusDetail = error.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _status = _LxStatus.error;
        _statusMessage = '连接失败';
        _statusDetail = '请检查地址、网络和连接码。';
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ],
      );
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.status,
    required this.title,
    required this.detail,
    required this.color,
  });

  final _LxStatus status;
  final String title;
  final String detail;
  final ColorScheme color;

  @override
  Widget build(BuildContext context) {
    final (icon, tint) = switch (status) {
      _LxStatus.completed => (Icons.check_circle_outline, color.primary),
      _LxStatus.connecting || _LxStatus.syncing => (Icons.sync, color.primary),
      _LxStatus.error => (Icons.error_outline, color.error),
      _ => (Icons.info_outline, color.onSurfaceVariant),
    };
    final busy = status == _LxStatus.connecting || status == _LxStatus.syncing;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint.withValues(alpha: .45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (busy)
            SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: tint,
              ),
            )
          else
            Icon(icon, color: tint, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(detail),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
