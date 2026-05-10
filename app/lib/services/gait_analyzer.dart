import 'dart:async';
import 'dart:math';
import 'tts_service.dart';

/// 步态警告数据模型
class GaitWarning {
  final String title;
  final String message;
  final String type; // 'high_impact', 'heel_strike', 'sharp_peak', 'voice_alert'
  final DateTime timestamp;

  GaitWarning({
    required this.title,
    required this.message,
    required this.type,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// 内部使用的步态片段类
class _StepSegment {
  double start;
  double end;
  List<double> data;

  _StepSegment({
    required this.start,
    required this.end,
    required this.data,
  });
}

class GaitAnalyzer {
  // =========================================================
  // 1. 参数配置
  // =========================================================
  final double fs;
  final double lowThresh;
  final double highThresh;
  
  // 报警阈值
  final double alertMagnitudeG;      // 冲击力阈值 (e.g. -2.0g)
  final double alertSlopeThresh;     // ⭐ 冲击斜率阈值 (VALR), 跑步机建议 40.0
  final double doublePeakProminence; // 找峰的最小突起 (e.g. 0.5g)
  final double heelStrikeRatio;      // 第二峰/第一峰的比例 (0.6)
  final double minRunningCadence;    // 最低步频阈值 (spm)

  // 缝合逻辑参数
  final double maxMergeGapSec;       // 0.12s (小于此间隙则缝合)
  final double maxStepDuration;      // 0.60s (熔断保护)
  final double maxValidImpactG;      // 超过此阈值视为噪声/异常 (e.g. 10g)
  static const bool _enableStiffLandingAlerts = false; // 暂时隐藏 stiff landing 告警
  static const int _cadenceWindowSize = 5;
  static const bool enableStiffLandingAlerts = _enableStiffLandingAlerts;

  // 语音触发逻辑参数
  final int voiceWindowSize;         // 窗口大小 (20步)
  final double voiceAlertThreshold;  // 错误率阈值 (40%)

  // =========================================================
  // 2. 30Hz 滤波器系数 (4阶 Butterworth Low-pass @ 200Hz)
  // =========================================================
  static const List<double> _b = [
    0.01856301, 0.07425204, 0.11137806, 0.07425204, 0.01856301
  ];
  static const List<double> _a = [
    1.00000000, -1.57039885, 1.27561332, -0.48440337, 0.07619706
  ];

  // 滤波器状态缓存
  List<double> _zi = [0.0, 0.0, 0.0, 0.0];

  // =========================================================
  // 3. 运行时状态
  // =========================================================
  bool _isAnalyzing = false;
  bool _inStance = false;
  double? _stepStartTime;
  int? _startTimestampUs;
  double? _lastCadenceAlertSec;
  
  // 实时数据缓冲
  final List<double> _currentStepRawBuffer = [];
  final List<double> _recentStepTimes = [];
  
  // 待定步子
  _StepSegment? _pendingStep;

  // =========================================================
  // 4. 统计与输出
  // =========================================================
  int _totalSteps = 0;
  double _peakImpactSum = 0.0;
  int _lastVoiceAlertStep = -9999;
  
  // 窗口统计 (每20步清空)
  final Map<String, int> _windowStats = {
    'total': 0,
    'high_impact': 0,
    'heel_strike': 0,
    'sharp_peak': 0,
    'low_cadence': 0,
  };

  // 全局统计
  final Map<String, int> _globalStats = {
    'high_impact': 0,
    'heel_strike': 0,
    'sharp_peak': 0,
    'low_cadence': 0,
  };

  // Streams
  final _stepController = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _warningController = StreamController<GaitWarning>.broadcast(sync: true);

  Stream<Map<String, dynamic>> get stepStream => _stepController.stream;
  Stream<GaitWarning> get warningStream => _warningController.stream;

  final TTSService _ttsService = TTSService();

  int get totalSteps => _totalSteps;
  Map<String, int> get globalStats => Map.unmodifiable(_globalStats);
  double get averagePeakImpact =>
      _totalSteps == 0 ? 0.0 : _peakImpactSum / _totalSteps;

  GaitAnalyzer({
    this.fs = 200,
    this.lowThresh = -0.3,
    this.highThresh = 0.1,
    this.alertMagnitudeG = -2.0,
    this.alertSlopeThresh = 40.0,
    this.doublePeakProminence = 0.5,
    this.heelStrikeRatio = 1.0,
    this.minRunningCadence = 100,
    this.maxMergeGapSec = 0.12,
    this.maxStepDuration = 0.60,
    this.voiceWindowSize = 3,
    this.voiceAlertThreshold = 0.2,
    this.maxValidImpactG = 10.0,
  });

  // ... (startAnalysis, stopAnalysis, addDataPoint, _applyFilter, _processSample, _submitSegment 保持不变) ...
  
  void startAnalysis() {
    _resetState();
    _isAnalyzing = true;
    print('Gait Analyzer Started (Filter: 30Hz)');
  }

  void stopAnalysis() {
    if (_pendingStep != null) {
      _flushStep(_pendingStep!);
      _pendingStep = null;
    }
    _isAnalyzing = false;
    print('Gait Analyzer Stopped. Total Steps: $_totalSteps');
  }

  void addDataPoint(Map<String, dynamic> sample) {
    if (!_isAnalyzing) return;
    final ayRaw = (sample['ay'] as num).toDouble();
    final tUs = (sample['t_us'] as num).toInt();
    _startTimestampUs ??= tUs;
    final tSec = (tUs - _startTimestampUs!) / 1e6;
    final aySmooth = _applyFilter(ayRaw);
    _processSample(tSec, ayRaw, aySmooth);
  }

  double _applyFilter(double x) {
    double y = _b[0] * x + _zi[0];
    _zi[0] = _b[1] * x + _zi[1] - _a[1] * y;
    _zi[1] = _b[2] * x + _zi[2] - _a[2] * y;
    _zi[2] = _b[3] * x + _zi[3] - _a[3] * y;
    _zi[3] = _b[4] * x - _a[4] * y;
    return y;
  }

  void _processSample(double t, double ayRaw, double aySmooth) {
    if (!_inStance) {
      if (aySmooth < lowThresh) {
        _inStance = true;
        _stepStartTime = t;
        _currentStepRawBuffer.clear();
        _currentStepRawBuffer.add(ayRaw);
      }
    } else {
      _currentStepRawBuffer.add(ayRaw);
      if (aySmooth > highThresh) {
        _inStance = false;
        if (_stepStartTime != null) {
          _submitSegment(t, List<double>.from(_currentStepRawBuffer));
        }
      }
    }
  }

  void _submitSegment(double endTime, List<double> rawData) {
    final startTime = endTime - (rawData.length / fs);
    if (_pendingStep == null) {
      _pendingStep = _StepSegment(start: startTime, end: endTime, data: rawData);
      return;
    }
    final gap = startTime - _pendingStep!.end;
    final potentialTotalDur = endTime - _pendingStep!.start;
    bool shouldMerge = false;
    if (gap < maxMergeGapSec) shouldMerge = true;
    if (potentialTotalDur > maxStepDuration) shouldMerge = false;

    if (shouldMerge) {
      final gapSamples = (gap * fs).toInt();
      final gapFiller = List<double>.filled(max(0, gapSamples), 0.0);
      final mergedData = [..._pendingStep!.data, ...gapFiller, ...rawData];
      _pendingStep!.end = endTime;
      _pendingStep!.data = mergedData;
    } else {
      _flushStep(_pendingStep!);
      _pendingStep = _StepSegment(start: startTime, end: endTime, data: rawData);
    }
  }

  // =========================================================
  // ⭐ 核心工具：线性插值找精确时间点
  // =========================================================
  double _getFractionalIndex(List<double> data, int startIdx, double targetVal) {
    // 从 startIdx 向左搜索，找到 exact 穿过 targetVal 的小数索引
    int i = startIdx;
    while (i > 0) {
      double valCurr = data[i];
      double valPrev = data[i - 1];

      // 检查是否穿过阈值 (因为 inverted 信号在下降沿往回找，所以 prev 应该小于 target)
      // 注意：这里 data 是 inverted (正值)，峰值在右，往左找应该是变小
      if ((valCurr >= targetVal && valPrev <= targetVal) ||
          (valCurr <= targetVal && valPrev >= targetVal)) {
        
        if (valCurr == valPrev) return i.toDouble();

        // 线性插值公式
        double fraction = (targetVal - valPrev) / (valCurr - valPrev);
        // 真实位置是 i-1 + fraction
        return (i - 1) + fraction;
      }
      i--;
    }
    return startIdx.toDouble(); // 没找到
  }

  // =========================================================
  // ⭐ 核心逻辑：最终分析 (Analysis)
  // =========================================================
  void _flushStep(_StepSegment step) {
    final duration = step.end - step.start;
    final rawVals = step.data;
    
    // 1. 基础过滤
    if (duration < 0.1) return;
    final peakImpact = rawVals.reduce(min);
    if (peakImpact > -0.5) return;
    if (peakImpact.abs() > maxValidImpactG) return; // 异常值过滤

    _totalSteps++;
    _peakImpactSum += peakImpact.abs();
    _windowStats['total'] = (_windowStats['total'] ?? 0) + 1;
    _recentStepTimes.add(step.end);
    if (_recentStepTimes.length > _cadenceWindowSize) {
      _recentStepTimes.removeAt(0);
    }

    final stepInfo = <String, dynamic>{
      'step_count': _totalSteps,
      'duration': duration,
      'peak_g': peakImpact,
      'p1_val': null,
      'p2_val': null,
      'ratio': null,
      'valr': null, // 记录斜率供 UI 展示
    };
    
    // 倒置信号用于找峰 (正值化)
    final inverted = rawVals.map((e) => -e).toList();
    
    // 找峰
    final peaksIdx = _findPeaks(inverted, prominence: doublePeakProminence, distance: 10);
    
    // === 警报 1: 冲击过大 (High Impact) ===
    if (peakImpact < alertMagnitudeG) {
      _addStat('high_impact');
      _warningController.add(GaitWarning(
        title: 'High Impact',
        message: '${peakImpact.toStringAsFixed(1)}g',
        type: 'high_impact',
      ));
    }

    if (peaksIdx.isNotEmpty) {
      // P1: 时间最早的显著峰 (Impact Peak)
      // peaksIdx 默认就是按时间排序的（index 从小到大）
      final p1Idx = peaksIdx.first;
      final p1Val = inverted[p1Idx];
      
      stepInfo['p1_val'] = rawVals[p1Idx];
      
      // =========================================================
      // ⭐ 警报 2: 触地僵硬 (VALR - 20-80% Loading Rate)
      // =========================================================
      
      final val20 = p1Val * 0.2;
      final val80 = p1Val * 0.8;
      
      // 1. 找 80% 点的小数索引 (从峰值向左找)
      double idx80Float = _getFractionalIndex(inverted, p1Idx, val80);
      
      // 2. 找 20% 点的小数索引 (从 80% 点整数位继续向左找)
      double idx20Float = _getFractionalIndex(inverted, idx80Float.toInt(), val20);
      
      // 3. 计算时间差 (s)
      double dt = (idx80Float - idx20Float) / fs;
      if (dt < 0.001) dt = 0.001; // 保护，防止除以0
      
      // 4. 计算幅度差 (g)
      double dg = val80 - val20;
      
      // 5. 计算斜率 (g/s)
      double valr = dg / dt;
      stepInfo['valr'] = valr;
      
      if (_enableStiffLandingAlerts && valr > alertSlopeThresh) {
        _addStat('sharp_peak');
        _warningController.add(GaitWarning(
          title: 'Stiff Landing',
          message: 'Slope: ${valr.toStringAsFixed(0)} g/s',
          type: 'sharp_peak',
        ));
      }
      
      // =========================================================
      // ⭐ 警报 3: 双峰检测 (Ratio Check)
      // =========================================================
      
      // 遍历 P1 之后的所有峰
      for (int i = 1; i < peaksIdx.length; i++) {
        final p2Idx = peaksIdx[i];
        final p2Val = inverted[p2Idx];
        
        final ratio = p2Val / p1Val;
        
        if (ratio > heelStrikeRatio) {
          _addStat('heel_strike');
          stepInfo['p2_val'] = rawVals[p2Idx];
          stepInfo['ratio'] = ratio;
          
          _warningController.add(GaitWarning(
            title: 'Heel Strike',
            message: 'Ratio: ${ratio.toStringAsFixed(2)}',
            type: 'heel_strike',
          ));
          break; 
        }
      }
    }

    // 步频检测（滑动窗口）
    final spm = _computeCadence();
    if (spm != null && spm < minRunningCadence) {
      final nowSec = step.end;
      if (_lastCadenceAlertSec == null || (nowSec - _lastCadenceAlertSec!) >= 3) {
        _addStat('low_cadence');
        _warningController.add(GaitWarning(
          title: 'Cadence Low',
          message: '${spm.toStringAsFixed(0)} spm',
          type: 'low_cadence',
        ));
        _lastCadenceAlertSec = nowSec;
      }
    }

    _stepController.add(stepInfo);

    // 检查语音触发
    if ((_windowStats['total'] ?? 0) >= voiceWindowSize) {
      _checkVoiceTrigger();
    }
  }

  List<int> _findPeaks(List<double> x, {double prominence = 0.5, int distance = 1}) {
    List<int> peaks = [];
    if (x.length < 3) return peaks;
    int lastPeakIdx = -distance; 
    for (int i = 1; i < x.length - 1; i++) {
      if (x[i] > x[i - 1] && x[i] > x[i + 1]) {
        if (i - lastPeakIdx < distance) continue;
        if (x[i] < prominence) continue; 
        peaks.add(i);
        lastPeakIdx = i;
      }
    }
    return peaks;
  }

  void _addStat(String key) {
    _windowStats[key] = (_windowStats[key] ?? 0) + 1;
    _globalStats[key] = (_globalStats[key] ?? 0) + 1;
  }

  void _checkVoiceTrigger() {
    final total = _windowStats['total']!;
    if (total == 0) return;
    if ((_totalSteps - _lastVoiceAlertStep) < voiceWindowSize) {
      _windowStats.updateAll((key, value) => 0);
      return;
    }

    double rateImpact = (_windowStats['high_impact'] ?? 0) / total;
    double rateHeel = (_windowStats['heel_strike'] ?? 0) / total;
    double rateSharp = (_windowStats['sharp_peak'] ?? 0) / total;
    double rateCadence = (_windowStats['low_cadence'] ?? 0) / total;

    GaitWarning? alert;

    if (rateImpact >= voiceAlertThreshold) {
      alert = GaitWarning(
        title: 'Voice Alert',
        message: 'High impact detected. Land more softly.',
        type: 'voice_alert',
      );
    } else if (rateHeel >= voiceAlertThreshold) {
      alert = GaitWarning(
        title: 'Voice Alert',
        message: 'Heel striking detected. Try to land midfoot.',
        type: 'voice_alert',
      );
    } else if (rateCadence >= voiceAlertThreshold) {
      alert = GaitWarning(
        title: 'Voice Alert',
        message: 'Cadence too low. Speed up your steps.',
        type: 'voice_alert',
      );
    } else if (rateSharp >= voiceAlertThreshold) {
      alert = GaitWarning(
        title: 'Voice Alert',
        message: 'Stiff landing detected. Soften your knees.',
        type: 'voice_alert',
      );
    }

    if (alert != null) {
      _warningController.add(alert);
      _lastVoiceAlertStep = _totalSteps;
    }

    _windowStats.updateAll((key, value) => 0);
  }

  void _resetState() {
    _zi = [0.0, 0.0, 0.0, 0.0];
    _inStance = false;
    _stepStartTime = null;
    _pendingStep = null;
    _startTimestampUs = null;
    _currentStepRawBuffer.clear();
    _totalSteps = 0;
    _peakImpactSum = 0.0;
    _recentStepTimes.clear();
    _lastCadenceAlertSec = null;
    _lastVoiceAlertStep = -9999;
    
    _windowStats.updateAll((key, value) => 0);
    _globalStats.updateAll((key, value) => 0);
  }

  void dispose() {
    _stepController.close();
    _warningController.close();
  }

  double? _computeCadence() {
    if (_recentStepTimes.length < _cadenceWindowSize) return null;
    final first = _recentStepTimes.first;
    final last = _recentStepTimes.last;
    if (last <= first) return null;
    final avgStepSec = (last - first) / (_recentStepTimes.length - 1);
    if (avgStepSec <= 0) return null;
    // BLE comes from one leg; double to estimate full cadence (both legs)
    return 120.0 / avgStepSec;
  }
}
