import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'csv_parser.dart';
import 'storage_service.dart';
import 'gait_analyzer.dart';

/// BLE服务 - 处理KneeGuard设备通信和数据存储
class BLEService {
  // BLE设备和特性
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;
  
  // UUID定义
  static const String serviceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String rxUuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  static const String txUuid = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
  
  // 服务
  final CSVParser _csvParser = CSVParser();
  final StorageService _storageService = StorageService();
  final GaitAnalyzer _gaitAnalyzer = GaitAnalyzer();
  
  // 数据缓存
  final List<Map<String, dynamic>> _dataCache = [];
  static const int batchSize = 200;
  
  // 超时定时器
  Timer? _timeoutTimer;
  static const Duration timeout = Duration(milliseconds: 150);
  
  // 定期保存定时器
  Timer? _saveTimer;
  
  // 统计
  int _samplesReceived = 0;
  int _packetsReceived = 0;
  int _stepsDetected = 0;
  bool _isSaving = false;
  
  // 当前会话ID
  String? _currentSessionId;
  
  // 状态流
  final _connectionStateController = StreamController<bool>.broadcast();
  final _statsController = StreamController<Map<String, int>>.broadcast();
  Stream<GaitWarning> get warnings => _gaitAnalyzer.warningStream;
  
  Stream<bool> get connectionState => _connectionStateController.stream;
  Stream<Map<String, int>> get stats => _statsController.stream;
  
  bool get isConnected => _device?.isConnected ?? false;
  
  /// 构造函数 - 监听步态分析事件
  BLEService() {
    _gaitAnalyzer.stepStream.listen((stepData) {
      _stepsDetected = stepData['step_count'];
      _updateStats();
    });
  }
  
  /// 扫描并连接设备
  Future<bool> connectToDevice() async {
    try {
      print('开始扫描设备...');
      
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
      );
      
      BluetoothDevice? kneeGuard;
      
      await for (var scanResult in FlutterBluePlus.scanResults) {
        for (var result in scanResult) {
          if (result.device.platformName.contains('KneeGuard')) {
            kneeGuard = result.device;
            break;
          }
        }
        if (kneeGuard != null) break;
      }
      
      await FlutterBluePlus.stopScan();
      
      if (kneeGuard == null) {
        print('未找到KneeGuard设备');
        return false;
      }
      
      print('找到设备: ${kneeGuard.platformName}');
      _device = kneeGuard;
      
      await _device!.connect(timeout: const Duration(seconds: 10));
      print('已连接到设备');
      
      List<BluetoothService> services = await _device!.discoverServices();
      
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUuid.toLowerCase()) {
          print('找到UART服务');
          
          for (var characteristic in service.characteristics) {
            String uuid = characteristic.uuid.toString().toLowerCase();
            
            if (uuid == txUuid.toLowerCase()) {
              _txCharacteristic = characteristic;
              print('找到TX特性');
              
              await _txCharacteristic!.setNotifyValue(true);
              _txCharacteristic!.lastValueStream.listen(_onDataReceived);
              
            } else if (uuid == rxUuid.toLowerCase()) {
              _rxCharacteristic = characteristic;
              print('找到RX特性');
            }
          }
        }
      }
      
      if (_txCharacteristic == null || _rxCharacteristic == null) {
        print('未找到必需的特性');
        await disconnect();
        return false;
      }
      
      _connectionStateController.add(true);
      _startPeriodicSave();
      print('✓ BLE连接成功！');
      return true;
      
    } catch (e) {
      print('连接错误: $e');
      _connectionStateController.add(false);
      return false;
    }
  }
  
  /// 接收BLE数据
  void _onDataReceived(List<int> data) {
    _packetsReceived++;
    
    String chunk = String.fromCharCodes(data);
    _csvParser.addChunk(chunk);
    
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(timeout, _processBuffer);
  }
  
  /// 处理缓冲区数据
  void _processBuffer() {
    if (_csvParser.hasCompleteData()) {
      List<Map<String, dynamic>> newData = _csvParser.parse();
      
      if (newData.isNotEmpty) {
        _samplesReceived += newData.length;
        _dataCache.addAll(newData);
        
        // 发送到步态分析器
        for (var sample in newData) {
          _gaitAnalyzer.addDataPoint(sample);
        }
        
        print('收到 ${newData.length} 个样本 (总计: $_samplesReceived)');
        
        // 批量保存
        if (_dataCache.length >= batchSize) {
          _saveCache();
        }
        
        _updateStats();
      }
    }
  }
  
  /// 保存缓存数据到本地CSV
  Future<void> _saveCache() async {
    if (_dataCache.isEmpty || _currentSessionId == null) return;
    
    if (_isSaving) return;
    
    _isSaving = true;
    
    const maxBatchSize = 200;
    int saveCount = _dataCache.length > maxBatchSize 
        ? maxBatchSize 
        : _dataCache.length;
    
    List<Map<String, dynamic>> toSave = _dataCache.take(saveCount).toList();
    
    bool success = await _storageService.appendData(toSave);
    
    if (success) {
      _dataCache.removeRange(0, saveCount);
      print('✓ Saved $saveCount samples, ${_dataCache.length} remaining in cache');
    } else {
      print('✗ Save failed, keeping ${_dataCache.length} samples in cache');
    }
    
    // 内存保护
    if (_dataCache.length > 10000) {
      int dropCount = 500;
      print('⚠️ Cache too large (${_dataCache.length}), dropping oldest $dropCount samples');
      _dataCache.removeRange(0, dropCount);
    }
    
    _isSaving = false;
    _updateStats();
  }
  
  /// 更新统计
  void _updateStats() {
    _statsController.add({
      'received': _samplesReceived,
      'steps': _stepsDetected,
      'cached': _dataCache.length,
    });
  }
  
  /// 启动定期保存
  void _startPeriodicSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (_dataCache.isNotEmpty && !_isSaving) {
        print('⏰ Periodic save: ${_dataCache.length} samples in cache');
        _saveCache();
      }
    });
    print('⏰ Periodic save timer started');
  }
  
  /// 停止定期保存
  void _stopPeriodicSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }
  
  /// 发送命令
  Future<bool> sendCommand(String command) async {
    if (_rxCharacteristic == null) {
      print('RX特性未初始化');
      return false;
    }
    
    try {
      await _rxCharacteristic!.write(command.codeUnits);
      print('发送命令: $command');
      return true;
    } catch (e) {
      print('发送命令失败: $e');
      return false;
    }
  }
  
  /// 开始采集
  Future<bool> startRecording() async {
    // 生成会话ID
    _currentSessionId = DateTime.now().millisecondsSinceEpoch.toString();
    
    // 创建新的CSV文件
    await _storageService.startNewSession(_currentSessionId!);
    
    // 重置统计
    _samplesReceived = 0;
    _packetsReceived = 0;
    _stepsDetected = 0;
    _dataCache.clear();
    _csvParser.clear();
    _storageService.resetStats();
    
    // 开始步态分析
    _gaitAnalyzer.startAnalysis();
    
    return await sendCommand('START');
  }
  
  /// 停止采集
  Future<bool> stopRecording() async {
    bool success = await sendCommand('STOP');
    
    // 保存所有剩余数据
    if (_dataCache.isNotEmpty) {
      print('📤 Saving remaining ${_dataCache.length} samples...');
      await _saveCache();
    }
    
    // 结束会话
    final filePath = await _storageService.endSession();
    if (filePath != null) {
      print('✓ Session data saved to: $filePath');
    }
    
    // 停止步态分析
    _gaitAnalyzer.stopAnalysis();
    
    _currentSessionId = null;
    
    return success;
  }
  
  /// 设置双传感器模式
  Future<bool> setModeDual() async {
    return await sendCommand('MODE DUAL');
  }
  
  /// 设置单传感器模式
  Future<bool> setModeShank() async {
    return await sendCommand('MODE SHANK');
  }
  
  /// 断开连接
  Future<void> disconnect() async {
    _timeoutTimer?.cancel();
    _stopPeriodicSave();
    
    // 保存剩余数据
    if (_dataCache.isNotEmpty) {
      print('📤 Saving remaining ${_dataCache.length} samples before disconnect...');
      await _saveCache();
    }
    
    // 结束会话
    if (_currentSessionId != null) {
      await _storageService.endSession();
    }
    
    if (_device != null) {
      await _device!.disconnect();
      _device = null;
    }
    
    _txCharacteristic = null;
    _rxCharacteristic = null;
    
    _connectionStateController.add(false);
    print('已断开连接');
  }
  
  /// 清理资源
  void dispose() {
    _timeoutTimer?.cancel();
    _stopPeriodicSave();
    _connectionStateController.close();
    _statsController.close();
    _gaitAnalyzer.dispose();
  }
}
