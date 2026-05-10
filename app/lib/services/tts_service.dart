import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';

class TTSService {
  static final TTSService _instance = TTSService._internal();
  factory TTSService() => _instance;
  TTSService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;

  // ⭐ 新增：冷却时间控制
  DateTime? _lastSpeakTime;
  static const Duration _cooldownDuration = Duration(seconds: 3); // 3秒冷却

  Future<void> init() async {
    if (_isInitialized) return;

    _flutterTts.setErrorHandler((msg) {
      print("🔴 TTS Error: $msg");
    });

    await _flutterTts.awaitSpeakCompletion(true);

    if (Platform.isAndroid) {
      var engines = await _flutterTts.getEngines;
      bool isGoogleInstalled = false;
      for (var engine in engines) {
        if (engine.toString().contains("google")) {
          isGoogleInstalled = true;
          break;
        }
      }
      if (isGoogleInstalled) {
        await _flutterTts.setEngine("com.google.android.tts");
      }
    } else if (Platform.isIOS) {
      await _flutterTts.setSharedInstance(true);
      await _flutterTts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
          IosTextToSpeechAudioCategoryOptions.duckOthers,
        ],
      );
    }

    // 语言设置
    var isEnAvailable = await _flutterTts.isLanguageAvailable("en-US");
    if (isEnAvailable) {
      await _flutterTts.setLanguage("en-US");
    } else {
      await _flutterTts.setLanguage("zh-CN");
    }

    await _flutterTts.setSpeechRate(0.55);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);

    _isInitialized = true;
    print('TTS Service Initialized');
  }

  /// 说话
  /// [text] 播报内容
  /// [force] 是否强制播报（忽略冷却时间），用于 High Impact
  Future<void> speak(String text, {bool force = false}) async {
    if (!_isInitialized) await init();

    final now = DateTime.now();

    // ⭐ 冷却逻辑：如果不是强制播报，且距离上次播报不足3秒，则忽略
    if (!force && _lastSpeakTime != null) {
      final difference = now.difference(_lastSpeakTime!);
      if (difference < _cooldownDuration) {
        print('🤐 TTS Cooldown (${difference.inMilliseconds}ms < 3000ms). Ignored: "$text"');
        return; 
      }
    }

    // 更新最后播报时间
    _lastSpeakTime = now;

    // 如果正在说话，先停止当前内容，播报最新的
    await _flutterTts.stop(); 
    
    print('🗣️ TTS Speaking (Force: $force): $text');
    await _flutterTts.speak(text);
  }

  void stop() {
    _flutterTts.stop();
  }
}