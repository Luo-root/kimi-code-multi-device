import 'package:flutter/material.dart';
import '../relay/models.dart';
import '../relay/relay_client.dart';
import '../relay/session_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';
import '../widgets/stream_block.dart';

/// 连接验证页：在干净环境验证 中继↔Flutter 数据通路（连通/流式/批准/发送/三态）。
/// 验证通过后，数据层与 StreamBlockView 接进 home_shell。
class RelayTestPage extends StatefulWidget {
  const RelayTestPage({super.key});

  @override
  State<RelayTestPage> createState() => _RelayTestPageState();
}

enum _Conn { idle, connecting, connected, failed }

class _RelayTestPageState extends State<RelayTestPage> {
  final _client = RelayClient();
  final _store = SessionStore();
  final _urlCtrl =
      TextEditingController(text: 'ws://127.0.0.1:7331/ws');
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  _Conn _conn = _Conn.idle;

  @override
  void initState() {
    super.initState();
    _client.onMessage = _store.handle;
    _client.onOpen = () => setState(() => _conn = _Conn.connected);
    _client.onClose = () => setState(() {
          if (_conn == _Conn.connecting) {
            _conn = _Conn.failed;
          } else if (_conn == _Conn.connected) {
            _conn = _Conn.idle;
          }
        });
    _store.addListener(_onStore);
  }

  void _onStore() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _connect() async {
    setState(() => _conn = _Conn.connecting);
    try {
      await _client.connect(_urlCtrl.text.trim());
    } catch (_) {
      setState(() => _conn = _Conn.failed);
    }
  }

  void _send() {
    final t = _inputCtrl.text.trim();
    final sid = _store.currentSid;
    if (t.isEmpty || sid == null) return;
    _store.addUser(sid, t);
    _client.send('prompt', sid: sid, payload: {'text': t});
    _inputCtrl.clear();
  }

  void _decide(PermOption opt) {
    final p = _store.pendingOf(_store.currentSid);
    if (p == null) return;
    _client.send('permission.decision',
        sid: p.sid, payload: {'permissionId': p.permissionId, 'optionId': opt.optionId});
    _store.resolvePermission(p);
  }

  @override
  void dispose() {
    _client.disconnect();
    _store.removeListener(_onStore);
    _urlCtrl.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _store.blocksOf(_store.currentSid);
    final perm = _store.pendingOf(_store.currentSid);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: blocks.isEmpty
                  ? const _EmptyHint()
                  : ListView.separated(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(AppSpacing.pageMargin),
                      itemCount: blocks.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: AppSpacing.lg),
                      itemBuilder: (_, i) => StreamBlockView(block: blocks[i]),
                    ),
            ),
            if (perm != null) _permSheet(perm),
            _inputBar(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final dot = switch (_store.relayState) {
      'ok' => AppColors.approve,
      'degraded' => AppColors.warning,
      _ => AppColors.placeholder,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text('SENTINEL · 连接验证', style: AppText.title2),
              const Spacer(),
              Text(
                switch (_conn) {
                  _Conn.idle => '未连接',
                  _Conn.connecting => '连接中…',
                  _Conn.connected => '已连接',
                  _Conn.failed => '连接失败',
                },
                style: AppText.caption,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    boxShadow: AppShadows.input,
                  ),
                  child: TextField(
                    controller: _urlCtrl,
                    style: AppText.monoCaption,
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _connect,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: AppColors.textPrimary,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text('连接',
                      style: AppText.callout.copyWith(
                          color: AppColors.surface,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
          if (_store.currentSid != null) ...[
            const SizedBox(height: 8),
            Text('sid: ${_store.currentSid}', style: AppText.monoCaption),
          ],
          if (_store.lastError != null) ...[
            const SizedBox(height: 6),
            Text(_store.lastError!,
                style: AppText.caption.copyWith(color: AppColors.reject)),
          ],
        ],
      ),
    );
  }

  Widget _permSheet(PermissionRequest p) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.card,
        border: Border.all(color: AppColors.warning, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(AppIcons.terminal, size: 16, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(child: Text(p.title, style: AppText.title2)),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.warningSoft,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text('待批准',
                    style:
                        AppText.monoCaption.copyWith(color: AppColors.warning)),
              ),
            ],
          ),
          if (p.command.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(AppRadius.thumbnail),
              ),
              child: Text(p.command, style: AppText.mono),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              for (final opt in p.options) ...[
                Expanded(child: _permButton(opt)),
                if (opt != p.options.last) const SizedBox(width: AppSpacing.sm),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _permButton(PermOption opt) {
    final (bg, fg, label) = switch (opt.kind) {
      'allow_once' => (AppColors.approve, AppColors.surface, '批准'),
      'allow_always' => (AppColors.keyCap, AppColors.textPrimary, '本会话'),
      'reject_once' => (AppColors.rejectSoft, AppColors.reject, '拒绝'),
      _ => (AppColors.keyCap, AppColors.textPrimary, opt.name ?? opt.optionId),
    };
    return GestureDetector(
      onTap: () => _decide(opt),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: AppText.callout.copyWith(color: fg, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _inputBar() {
    final enabled = _conn == _Conn.connected && _store.currentSid != null;
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, 12 + MediaQuery.of(context).padding.bottom),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          boxShadow: AppShadows.input,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                enabled: enabled,
                style: AppText.body,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: enabled ? '尽管问…' : '先连接中继',
                  hintStyle: AppText.placeholder,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            GestureDetector(
              onTap: enabled ? _send : null,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: enabled
                      ? AppColors.textPrimary
                      : AppColors.keyCap,
                  shape: BoxShape.circle,
                ),
                child: Icon(AppIcons.send,
                    size: 16,
                    color: enabled ? AppColors.surface : AppColors.placeholder),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          '连接中继后，这里会逐字滚出 Kimi 的实时流：\n思考、回复、工具调用，以及需要你拍板的批准卡。',
          textAlign: TextAlign.center,
          style: AppText.caption,
        ),
      ),
    );
  }
}