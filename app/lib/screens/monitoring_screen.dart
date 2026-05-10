import 'dart:io';
import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../services/gait_analyzer.dart'; // Import for GaitWarning class
import '../services/storage_service.dart';
import '../services/tts_service.dart';
import '../widgets/custom_widgets.dart';

class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({super.key});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> 
    with AutomaticKeepAliveClientMixin {
  
  @override
  bool get wantKeepAlive => true;
  
  BLEService? _bleService;
  final TTSService _ttsService = TTSService();
  final StorageService _storageService = StorageService();

  static const Set<String> _ttsEnabledTypes = {
    'voice_alert',
    'high_impact', // 虽然这里保留了，但在逻辑里我们会优先单独处理它
    'heel_strike',
    'sharp_peak',
    'low_cadence',
  };
  
  bool _isConnected = false;
  bool _isRecording = false;
  bool _isDualMode = false;
  bool _modeSelected = false; 
  
  Map<String, int> _stats = {
    'received': 0,
    'steps': 0,
    'cached': 0,
  };
  
  // Only keep the latest few warnings to show
  List<GaitWarning> _warnings = [];
  
  @override
  void initState() {
    super.initState();
    // 确保 TTS 初始化
    _ttsService.init();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeServices();
    });
  }
  
  void _initializeServices() {
    try {
      _bleService = BLEService();
      
      // Listen to connection state
      _bleService!.connectionState.listen((connected) {
        if (mounted) {
          setState(() {
            _isConnected = connected;
            if (!connected) {
              _isRecording = false;
              _modeSelected = false; // Reset mode on disconnect
            }
          });
        }
      });
      
      // Listen to stats (packets, steps, cache size)
      _bleService!.stats.listen((stats) {
        if (mounted) {
          setState(() {
            _stats = stats;
          });
        }
      });
      
      // =========================================================
      // ⭐ 核心修改：区分 High Impact 和 普通报警
      // =========================================================
      _bleService!.warnings.listen((warning) {
        if (mounted) {
          // Debug log
          print('⚠️ Warning received: ${warning.type} - ${warning.message}');
          
          setState(() {
            _warnings.insert(0, warning);
            if (_warnings.length > 5) {
              _warnings.removeLast();
            }
          });

          // 获取播报文案
          final message = _ttsMessageForWarning(warning);

          if (warning.type == 'high_impact') {
            // ⭐ 1. 高冲击：强制播报 (force: true)，无视冷却时间，立即打断
            _ttsService.speak(message, force: true);
          } 
          else if (_ttsEnabledTypes.contains(warning.type)) {
            // ⭐ 2. 其他报警：普通播报 (force: false)，受 3秒 冷却时间限制
            _ttsService.speak(message, force: false);
          }
        }
      });

    } catch (e) {
      print('Service initialization error: $e');
      if (mounted) {
        _showSnackBar('Initialization failed: $e', isError: true);
      }
    }
  }
  
  @override
  void dispose() {
    _ttsService.stop();
    // Note: In a real app, you might maintain the service singleton 
    // rather than disposing it when switching tabs.
    // _bleService?.dispose(); 
    super.dispose();
  }
  
  Future<void> _connect() async {
    if (_bleService == null) {
      _showSnackBar('Service not initialized', isError: true);
      return;
    }
    
    // Show loading indicator logic could go here
    final success = await _bleService!.connectToDevice();
    if (!success && mounted) {
      _showSnackBar('Connection failed', isError: true);
    }
  }
  
  Future<void> _disconnect() async {
    if (_bleService == null) return;
    await _bleService!.disconnect();
    setState(() {
      _warnings.clear(); // Clear warnings on disconnect
    });
  }
  
  Future<void> _startRecording() async {
    if (_bleService == null) return;
    
    final success = await _bleService!.startRecording();
    if (success) {
      setState(() {
        _isRecording = true;
        _warnings.clear(); // Clear old warnings on new session
      });
      _showSnackBar('Recording started');
    }
  }
  
  Future<void> _stopRecording() async {
    if (_bleService == null) return;
    
    final success = await _bleService!.stopRecording();
    if (success) {
      setState(() => _isRecording = false);
      _showSnackBar('Recording stopped');
    }
  }

  Future<void> _previewLatestCsv() async {
    try {
      final files = await _storageService.getSavedFiles();
      if (files.isEmpty) {
        _showSnackBar('No saved CSV found');
        return;
      }

      final latest = files.first;
      if (latest is! File) {
        _showSnackBar('Latest item is not a file');
        return;
      }

      final lines = await latest.readAsLines();
      if (lines.length <= 1) {
        _showSnackBar('File is empty');
        return;
      }

      final headers = lines.first.split(',');
      final dataRows = lines.skip(1).where((l) => l.trim().isNotEmpty).toList();
      const maxRows = 15;
      final previewRows = dataRows.take(maxRows).map((row) => row.split(',')).toList();
      final truncated = dataRows.length > maxRows;

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: Text('Latest CSV: ${latest.path.split('/').last}'),
            content: SizedBox(
              width: MediaQuery.of(ctx).size.width * 0.9,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: SingleChildScrollView(
                    child: DataTable(
                      headingRowColor: MaterialStateProperty.all(Color(0xFFE5E9F0)),
                      columnSpacing: 12,
                      columns: headers
                          .map((h) => DataColumn(
                                label: Text(
                                  h.trim(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ))
                          .toList(),
                      rows: previewRows
                          .map(
                            (cells) => DataRow(
                              cells: List.generate(
                                headers.length,
                                (idx) => DataCell(
                                  Text(
                                    idx < cells.length ? cells[idx] : '',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ),
            ),
            actions: [
              if (truncated)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text(
                    '${dataRows.length - maxRows} more rows not shown',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      _showSnackBar('Preview failed: $e', isError: true);
    }
  }
  
  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red[600] : Color(0xFF2E3440),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: Duration(seconds: 2),
      ),
    );
  }

  String _ttsMessageForWarning(GaitWarning warning) {
    switch (warning.type) {
      case 'high_impact':
        // 这里的文案可以更简洁有力，因为是紧急播报
        return 'High impact! Soften landing!'; 
      case 'heel_strike':
        return 'Heel strike. Land midfoot.';
      case 'sharp_peak':
        return 'Stiff landing. Bend knees.';
      case 'low_cadence':
        return 'Cadence low. Speed up.';
      default:
        return warning.message;
    }
  }
  
  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    return Scaffold(
      backgroundColor: Colors.transparent,
      
      // ← 添加浮动按钮
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          print('🧪 === TTS TEST START ===');
          try {
            await _ttsService.init();
            print('✅ TTS initialized');
            
            await _ttsService.speak('Testing one two three');
            print('✅ TTS speak called');
            
            _showSnackBar('TTS test triggered');
          } catch (e) {
            print('❌ TTS error: $e');
            _showSnackBar('TTS error: $e', isError: true);
          }
        },
        child: Icon(Icons.volume_up),
        backgroundColor: Color(0xFF2E3440),
      ),
      
      // 原来的内容
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 200),
              
              _buildCompactControlCard(),
              
              SizedBox(height: 16),
              
              _buildStatsSection(),
              
              SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactControlCard() {
    return GlassCard(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          // Device info row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _isConnected
                            ? [Color(0xFF2E3440), Color(0xFF434C5E)]
                            : [Colors.grey[300]!, Colors.grey[400]!],
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.bluetooth,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isConnected ? 'CONNECTED' : 'DISCONNECTED',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2E3440),
                          letterSpacing: 1,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Samples: ${_stats['received']} • Buffer: ${_stats['cached']}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8896A8),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              PulseIndicator(isActive: _isConnected, size: 10),
            ],
          ),
          
          SizedBox(height: 12),
          
          // Connect Button
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _isConnected ? _disconnect : _connect,
              style: TextButton.styleFrom(
                foregroundColor: _isConnected ? Colors.red[400] : Color(0xFF2E3440),
                padding: EdgeInsets.symmetric(vertical: 12),
                backgroundColor: _isConnected 
                    ? Colors.red[50]
                    : Color(0xFF2E3440).withOpacity(0.05),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                    color: _isConnected ? Colors.red[400]! : Color(0xFF2E3440),
                    width: 1.5,
                  ),
                ),
              ),
              child: Text(
                _isConnected ? 'DISCONNECT' : 'SCAN & CONNECT',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
          
          // Sensor Mode Selection
          if (_isConnected) ...[
            SizedBox(height: 12),
            Divider(color: Color(0xFFE5E9F0), height: 1),
            SizedBox(height: 12),
            
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _isRecording ? null : () async {
                      await _bleService!.setModeShank();
                      setState(() {
                        _isDualMode = false;
                        _modeSelected = true;
                      });
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: !_isDualMode && _modeSelected
                            ? Color(0xFF2E3440)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: !_isDualMode && _modeSelected
                              ? Color(0xFF2E3440)
                              : Color(0xFFE5E9F0),
                          width: 1.5,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          'SINGLE MODE',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: !_isDualMode && _modeSelected
                                ? Colors.white
                                : Color(0xFF5E6C7E),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: _isRecording ? null : () async {
                      await _bleService!.setModeDual();
                      setState(() {
                        _isDualMode = true;
                        _modeSelected = true;
                      });
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _isDualMode && _modeSelected
                            ? Color(0xFF2E3440)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _isDualMode && _modeSelected
                              ? Color(0xFF2E3440)
                              : Color(0xFFE5E9F0),
                          width: 1.5,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          'DUAL MODE',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _isDualMode && _modeSelected
                                ? Colors.white
                                : Color(0xFF5E6C7E),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            
            SizedBox(height: 12),
            
            // Recording Controls
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _isRecording 
                            ? Colors.red.withOpacity(0.2)
                            : Colors.grey.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        Icons.fiber_manual_record,
                        color: _isRecording ? Colors.red : Colors.grey,
                        size: 16,
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      _isRecording ? 'RECORDING...' : 'READY',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF2E3440),
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: (!_modeSelected && !_isRecording) 
                      ? null 
                      : (_isRecording ? _stopRecording : _startRecording),
                  style: TextButton.styleFrom(
                    foregroundColor: _isRecording ? Colors.orange : Color(0xFF2E3440),
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    backgroundColor: _isRecording 
                        ? Colors.orange.withOpacity(0.1)
                        : (_modeSelected 
                            ? Color(0xFF2E3440).withOpacity(0.1)
                            : Colors.grey.withOpacity(0.05)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isRecording ? Icons.stop : Icons.play_arrow,
                        size: 16,
                      ),
                      SizedBox(width: 4),
                      Text(
                        _isRecording ? 'STOP' : 'START',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
  
  Widget _buildStatsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            SectionHeader(
              title: 'LIVE ALERTS',
              icon: Icons.notifications_active,
            ),
            TextButton(
              onPressed: _previewLatestCsv,
              child: Text('Debug CSV', style: TextStyle(fontSize: 12)),
            )
          ],
        ),
        SizedBox(height: 12),
        
        if (_warnings.isNotEmpty) ...[
          // Show top 3 warnings
          ..._warnings.take(3).map((w) => _buildWarningItem(w)),
        ] else ...[
          GlassCard(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  _isRecording ? Icons.check_circle_outline : Icons.info_outline,
                  color: _isRecording ? Color(0xFF4CAF50) : Color(0xFF8896A8),
                  size: 24,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _isRecording 
                        ? 'Running form looks good.' 
                        : 'Start recording to monitor your gait.',
                    style: TextStyle(
                      fontSize: 14,
                      color: Color(0xFF5E6C7E),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
  
  Widget _buildWarningItem(GaitWarning warning) {
    // Map warning type to visual properties
    Color color;
    IconData icon;
    
    switch (warning.type) {
      case 'high_impact':
        color = Color(0xFFFF5252); // Red
        icon = Icons.bolt;
        break;
      case 'heel_strike':
        color = Color(0xFFFFAB00); // Amber
        icon = Icons.do_not_step;
        break;
      case 'sharp_peak':
        color = Color(0xFF2196F3); // Blue
        icon = Icons.show_chart;
        break;
      case 'voice_alert':
        color = Color(0xFF9C27B0); // Purple
        icon = Icons.record_voice_over;
        break;
      default:
        color = Colors.grey;
        icon = Icons.info;
    }
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: WarningAlert(
        title: warning.title.toUpperCase(),
        message: warning.message,
        icon: icon,
        color: color,
      ),
    );
  }
}