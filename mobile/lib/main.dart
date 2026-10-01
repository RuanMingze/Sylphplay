import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 后台播放：接管通知栏 / 锁屏 / 耳机按键，并让 Android 起前台服务
  // （必须在创建 AudioPlayer 之前初始化）
  await JustAudioBackground.init(
    androidNotificationChannelId: 'cn.ruanftrix.sylphplay_mobile.channel.audio',
    androidNotificationChannelName: 'Sylphplay 播放',
    androidNotificationOngoing: true,
  );

  // 音频会话设为 music（playback 类别）：iOS 上这是后台音频能持续播放的前提，
  // 同时让「静音键拨到静音」不再掐掉本 App 的播放。
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  final state = AppState();
  await state.init();
  runApp(SylphApp(state: state));
}

class SylphApp extends StatelessWidget {
  final AppState state;
  const SylphApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const _ThemedApp(),
    );
  }
}

/// 把当前配色提升到 MaterialApp 层：让弹窗 / 底部弹层等 Navigator overlay
/// 也能取到 SylphColorsScope 与对应 Theme（否则会退回默认浅色主题）。
class _ThemedApp extends StatelessWidget {
  const _ThemedApp();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final platformDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    final c = resolveColors(
      settings: st.settings,
      systemDark: platformDark,
      nationalActive: st.nationalActive,
    );
    return MaterialApp(
      title: 'Sylphplay',
      debugShowCheckedModeBanner: false,
      theme: c.toThemeData(),
      builder: (ctx, child) => SylphColorsScope(
        colors: c,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const AppShell(),
    );
  }
}