import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/gait_analyzer.dart';
import '../services/storage_service.dart';
import '../widgets/custom_widgets.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final StorageService _storageService = StorageService();
  StreamSubscription<String?>? _sessionSub;
  final Map<String, dynamic> _reportData = {
    'durationSec': 0.0,
    'cadence': 0.0,
    'avgPeakImpact': 0.0,
    'highImpactRate': 0.0,
    'heelStrikeRate': 0.0,
    'stiffLandingRate': 0.0,
    'overallScore': 0,
    'totalSteps': 0,
    'reportDate': null,
  };
  List<Map<String, dynamic>> _insights = [];
  
  bool _hasData = false;
  
  @override
  void initState() {
    super.initState();
    _sessionSub = _storageService.lastSessionStream.listen((path) {
      if (mounted) {
        _loadReport(filePath: path);
      }
    });
    _loadReport();
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    super.dispose();
  }
  
  Future<void> _loadReport({String? filePath}) async {
    try {
      final files = await _storageService.getSavedFiles();

      File? latestFile;

      if (filePath != null && filePath.isNotEmpty) {
        final candidate = File(filePath);
        if (await candidate.exists()) {
          latestFile = candidate;
        }
      }

      final fileEntries = files.whereType<File>().toList();
      if (latestFile == null) {
        if (fileEntries.isEmpty) {
          setState(() {
            _hasData = false;
          });
          return;
        }
        latestFile = fileEntries.first;
      }

      if (latestFile == null) {
        setState(() {
          _hasData = false;
        });
        return;
      }
      final lines = await latestFile.readAsLines();

      if (lines.length <= 1) {
        setState(() {
          _hasData = false;
        });
        return;
      }

      final analyzer = GaitAnalyzer();
      final peaks = <double>[];
      StreamSubscription? stepSub;

      double? firstTsUs;
      double? lastTsUs;

      try {
        stepSub = analyzer.stepStream.listen((step) {
          final peak = step['peak_g'];
          if (peak is num) {
            peaks.add(peak.toDouble());
          }
        });

        analyzer.startAnalysis();

        for (int i = 1; i < lines.length; i++) {
          final parts = lines[i].split(',');
          if (parts.length < 10) continue;

          final tUs = int.tryParse(parts[3]);
          final ay = double.tryParse(parts[5]);
          if (tUs == null || ay == null) continue;

          firstTsUs ??= tUs.toDouble();
          lastTsUs = tUs.toDouble();

          analyzer.addDataPoint({'ay': ay, 't_us': tUs});
        }
      } finally {
        analyzer.stopAnalysis();
        await stepSub?.cancel();
      }

      final totalSteps = analyzer.totalSteps;
      final stats = analyzer.globalStats;
      int highImpactCount = stats['high_impact'] ?? 0;
      final heelStrikeCount = stats['heel_strike'] ?? 0;
      int stiffLandingCount = stats['sharp_peak'] ?? 0;
      int lowCadenceCount = stats['low_cadence'] ?? 0;

      if (totalSteps == 0 || firstTsUs == null || lastTsUs == null) {
        setState(() {
          _hasData = false;
        });
        return;
      }

      final totalTimeSec =
          max(0.0, (lastTsUs - firstTsUs) / 1e6); // 微秒 -> 秒
      if (totalTimeSec == 0) {
        setState(() {
          _hasData = false;
        });
        return;
      }

      // BLE only measures one leg; double to get full-step cadence
      final cadence = (totalSteps / totalTimeSec) * 120.0;
      final avgPeakImpact = peaks.isNotEmpty
          ? peaks.map((p) => p.abs()).reduce((a, b) => a + b) / peaks.length
          : analyzer.averagePeakImpact;

      // Heuristic fallbacks if analyzer flags missed during replay
      const highImpactThresholdG = 1.8;
      const stiffLandingThresholdG = 1.4;
      if (peaks.isNotEmpty) {
        final fallbackHigh =
            peaks.where((p) => p.abs() >= highImpactThresholdG).length;
        if (highImpactCount == 0 && fallbackHigh > 0) {
          highImpactCount = fallbackHigh;
        }

        final fallbackStiff = peaks
            .where((p) =>
                p.abs() >= stiffLandingThresholdG ||
                p.abs() >= avgPeakImpact * 1.1)
            .length;
        if (stiffLandingCount == 0 && fallbackStiff > 0) {
          stiffLandingCount = fallbackStiff;
        }
      }

      final highImpactRate = highImpactCount / totalSteps;
      final heelStrikeRate = heelStrikeCount / totalSteps;
      final stiffLandingRate = GaitAnalyzer.enableStiffLandingAlerts
          ? stiffLandingCount / totalSteps
          : 0.0;
      final lowCadenceRate = lowCadenceCount / totalSteps;

      final overallScore = _calculateScore(
        totalTimeSec,
        cadence,
        avgPeakImpact,
        highImpactRate,
        heelStrikeRate,
        stiffLandingRate,
        lowCadenceRate,
      );
      final insights = _buildInsights(
        highImpactRate,
        heelStrikeRate,
        stiffLandingRate,
        lowCadenceRate,
      );

      final stat = await latestFile.stat();

      setState(() {
        _reportData['durationSec'] = totalTimeSec;
        _reportData['cadence'] = cadence;
        _reportData['avgPeakImpact'] = avgPeakImpact;
        _reportData['highImpactRate'] = highImpactRate;
        _reportData['heelStrikeRate'] = heelStrikeRate;
        _reportData['stiffLandingRate'] = stiffLandingRate;
        _reportData['lowCadenceRate'] = lowCadenceRate;
        _reportData['overallScore'] = overallScore;
        _reportData['totalSteps'] = totalSteps;
        _reportData['reportDate'] = stat.modified;
        _insights = insights;
        _hasData = true;
      });
    } catch (e) {
      print('Error loading report: $e');
      setState(() {
        _hasData = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    if (!_hasData) {
      return _buildNoDataView();
    }
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 200),
          
          _buildHeaderCard(),
          const SizedBox(height: 20),
          
          _buildOverallScoreCard(),
          const SizedBox(height: 20),
          
          _buildMetricsGrid(),
          const SizedBox(height: 20),
          
          _buildInsightsCard(),
        ],
      ),
    );
  }
  
  Widget _buildNoDataView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF667eea).withOpacity(0.2),
                  const Color(0xFF764ba2).withOpacity(0.2),
                ],
              ),
            ),
            child: const Icon(
              Icons.analytics_outlined,
              size: 80,
              color: Color(0xFF2E3440),
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'NO ANALYSIS YET',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: Color(0xFF2E3440),
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Complete a recording session to\nview detailed analytics here',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: Color(0xFF5E6C7E),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildHeaderCard() {
    return GlassCard(
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF667eea), Color(0xFF764ba2)],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.insert_chart,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PERFORMANCE REPORT',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF2E3440),
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _formatDate(_reportData['reportDate'] as DateTime?),
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF5E6C7E),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildOverallScoreCard() {
    final score = _reportData['overallScore'] as int;
    final color = _getScoreColor(score);
    
    return GlassCard(
      gradientColors: [
        color.withOpacity(0.1),
        color.withOpacity(0.05),
      ],
      child: Column(
        children: [
          const Text(
            'OVERALL SCORE',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF5E6C7E),
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 32),
          
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 180,
                height: 180,
                child: CircularProgressIndicator(
                  value: score / 100,
                  strokeWidth: 16,
                  backgroundColor: const Color(0xFFE5E9F0),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              Column(
                children: [
                  ShaderMask(
                    shaderCallback: (bounds) => LinearGradient(
                      colors: [color.withOpacity(0.8), color],
                    ).createShader(bounds),
                    child: Text(
                      score.toString(),
                      style: const TextStyle(
                        fontSize: 64,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF2E3440),
                      ),
                    ),
                  ),
                  Text(
                    _getScoreLabel(score),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF5E6C7E),
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ],
          ),
          
          const SizedBox(height: 32),
          
          const Text(
            'Based on comprehensive gait analysis',
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFF8896A8),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildMetricsGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'KEY METRICS',
          icon: Icons.assessment,
        ),
        const SizedBox(height: 16),
        
        Row(
          children: [
            Expanded(
              child: _buildMetricCard(
                'TOTAL TIME',
                _formatDuration(_reportData['durationSec'] as double),
                'mm:ss',
                Icons.timer,
                [const Color(0xFF4CAF50), const Color(0xFF45B69C)],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMetricCard(
                'CADENCE',
                (_reportData['cadence'] as double).toStringAsFixed(1),
                'spm',
                Icons.speed,
                [const Color(0xFF00E5FF), const Color(0xFF00BCD4)],
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 12),
        
        Row(
          children: [
            Expanded(
              child: _buildMetricCard(
                'AVG PEAK IMPACT',
                (_reportData['avgPeakImpact'] as double).toStringAsFixed(2),
                'g',
                Icons.flash_on,
                [const Color(0xFFFF6B6B), const Color(0xFFFF5252)],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMetricCard(
                'HIGH IMPACT',
                _formatPercent(_reportData['highImpactRate'] as double),
                '%',
                Icons.warning_amber_rounded,
                [const Color(0xFFFFAB00), const Color(0xFFFF7043)],
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 12),
        
        Row(
          children: [
            Expanded(
              child: _buildMetricCard(
                'HEEL STRIKE',
                _formatPercent(_reportData['heelStrikeRate'] as double),
                '%',
                Icons.directions_walk,
                [const Color(0xFFBA68C8), const Color(0xFF9C27B0)],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMetricCard(
                'LOW CADENCE',
                _formatPercent(_reportData['lowCadenceRate'] as double),
                '%',
                Icons.speed,
                [const Color(0xFF5C6BC0), const Color(0xFF3F51B5)],
              ),
            ),
          ],
        ),
      ],
    );
  }
  
  Widget _buildMetricCard(
    String title,
    String value,
    String unit,
    IconData icon,
    List<Color> colors,
  ) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors.map((c) => c.withOpacity(0.3)).toList(),
        ),
        border: Border.all(
          color: colors[0].withOpacity(0.4),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: colors[0].withOpacity(0.2),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colors[0], size: 28),
          const SizedBox(height: 12),
          FittedBox(
            alignment: Alignment.centerLeft,
            fit: BoxFit.scaleDown,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF2E3440),
                    height: 1,
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    unit,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF5E6C7E),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF8896A8),
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildInsightsCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'INSIGHTS',
          icon: Icons.lightbulb_outline,
        ),
        const SizedBox(height: 16),
        
        GlassCard(
          child: Column(
            children: [
              for (int i = 0; i < _insights.length; i++) ...[
                _buildInsightItem(
                  _insights[i]['title'] as String,
                  _insights[i]['description'] as String,
                  _insights[i]['icon'] as IconData,
                  _insights[i]['color'] as Color,
                ),
                if (i != _insights.length - 1) const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ],
    );
  }
  
  Widget _buildInsightItem(
    String title,
    String description,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2E3440),
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF5E6C7E),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Color _getScoreColor(int score) {
    if (score >= 80) return const Color(0xFF4CAF50);
    if (score >= 60) return const Color(0xFFFFAB00);
    return const Color(0xFFFF5252);
  }
  
  String _getScoreLabel(int score) {
    if (score >= 80) return 'EXCELLENT';
    if (score >= 60) return 'GOOD';
    if (score >= 40) return 'FAIR';
    return 'NEEDS WORK';
  }

  String _formatDuration(double seconds) {
    if (seconds <= 0) return '--:--';
    final d = Duration(milliseconds: (seconds * 1000).round());
    final minutes = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _formatPercent(double rate) {
    final pct = max(0.0, min(100.0, rate * 100));
    return pct.toStringAsFixed(0);
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '--';
    return DateFormat('MMM d, yyyy – HH:mm').format(date);
  }

  int _calculateScore(
    double durationSec,
    double cadence,
    double avgImpact,
    double highImpactRate,
    double heelStrikeRate,
    double stiffLandingRate,
    double lowCadenceRate,
  ) {
    final durationScore = _clamp01(durationSec / 1800); // 30分钟跑满记满分
    final cadenceScore =
        1 - _clamp01(((cadence - 170).abs()) / 40); // 170spm最佳，正负40衰减
    final impactScore = avgImpact <= 0
        ? 1.0
        : 1 - _clamp01((avgImpact - 1.6) / (3.5 - 1.6)); // >3.5g 记0分
    final highScore = 1 - _clamp01(highImpactRate);
    final heelScore = 1 - _clamp01(heelStrikeRate);
    final stiffScore = 1 - _clamp01(stiffLandingRate);

    final weighted = durationScore * 0.15 +
        cadenceScore * 0.2 +
        impactScore * 0.2 +
        highScore * 0.2 +
        heelScore * 0.15 +
        stiffScore * 0.1;

    return max(0, min(100, (weighted * 100).round()));
  }

  double _clamp01(double value) => value.clamp(0.0, 1.0);

  List<Map<String, dynamic>> _buildInsights(
    double highImpactRate,
    double heelStrikeRate,
    double stiffLandingRate,
    double lowCadenceRate,
  ) {
    const threshold = 0.2; // 20% 触发提醒
    final insights = <Map<String, dynamic>>[];

    if (highImpactRate >= threshold) {
      insights.add({
        'title': 'High impact frequency',
        'description':
            'Impact spikes on ${_formatPercent(highImpactRate)}% of steps. Shorten stride and soften landing to reduce load.',
        'icon': Icons.flash_on,
        'color': const Color(0xFFFF6B6B),
      });
    }

    if (heelStrikeRate >= threshold) {
      insights.add({
        'title': 'Heel strike dominant',
        'description':
            'Heel-first landings on ${_formatPercent(heelStrikeRate)}% of steps. Try a midfoot strike and increase cadence.',
        'icon': Icons.directions_walk,
        'color': const Color(0xFF00E5FF),
      });
    }

    if (GaitAnalyzer.enableStiffLandingAlerts &&
        stiffLandingRate >= threshold) {
      insights.add({
        'title': 'Stiff landing detected',
        'description':
            'Limited knee flex on ${_formatPercent(stiffLandingRate)}% of steps. Add gentle knee bend and ankle mobility drills.',
        'icon': Icons.self_improvement,
        'color': const Color(0xFF5C6BC0),
      });
    }

    if (lowCadenceRate >= threshold) {
      insights.add({
        'title': 'Cadence is low',
        'description':
            'Cadence low on ${_formatPercent(lowCadenceRate)}% of steps. Shorten stride and target 160+ spm.',
        'icon': Icons.speed,
        'color': const Color(0xFFFFAB00),
      });
    }

    if (insights.isEmpty) {
      insights.add({
        'title': 'Solid form',
        'description': 'Low red flags this run. Maintain cadence and soft landings.',
        'icon': Icons.check_circle_outline,
        'color': const Color(0xFF4CAF50),
      });
    }

    return insights;
  }
}
