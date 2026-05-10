import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 本地存储服务 - 将数据保存为CSV文件
class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  // 当前会话的文件
  File? _currentFile;
  String? _currentSessionId;
  
  // 统计
  int _totalSaved = 0;
  int _failedSaves = 0;

  final _lastSessionController = StreamController<String?>.broadcast();
  Stream<String?> get lastSessionStream => _lastSessionController.stream;
  
  int get totalSaved => _totalSaved;
  int get failedSaves => _failedSaves;
  
  /// 开始新的采集会话
  Future<void> startNewSession(String sessionId) async {
    _currentSessionId = sessionId;
    
    // 获取应用文档目录
    final directory = await getApplicationDocumentsDirectory();
    final kneeguardDir = Directory('${directory.path}/KneeGuard');
    
    // 创建KneeGuard目录（如果不存在）
    if (!await kneeguardDir.exists()) {
      await kneeguardDir.create(recursive: true);
    }
    
    // 创建新文件
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final fileName = 'session_${sessionId}_$timestamp.csv';
    _currentFile = File('${kneeguardDir.path}/$fileName');
    
    // 写入CSV表头
    await _currentFile!.writeAsString(
      'session_id,device_id,sensor_id,t_us,ax,ay,az,gx,gy,gz\n',
      mode: FileMode.write,
    );
    
    print('✓ Created new CSV file: ${_currentFile!.path}');
  }
  
  /// 追加数据到CSV文件
  Future<bool> appendData(List<Map<String, dynamic>> data) async {
    if (_currentFile == null || data.isEmpty) {
      return false;
    }
    
    try {
      // 转换为CSV格式
      final csvLines = data.map((sample) {
        return '${sample['session_id']},'
            '${sample['device_id']},'
            '${sample['sensor_id']},'
            '${sample['t_us']},'
            '${sample['ax']},'
            '${sample['ay']},'
            '${sample['az']},'
            '${sample['gx']},'
            '${sample['gy']},'
            '${sample['gz']}\n';
      }).join();
      
      // 追加到文件
      await _currentFile!.writeAsString(
        csvLines,
        mode: FileMode.append,
      );
      
      _totalSaved += data.length;
      print('✓ Saved ${data.length} samples to CSV (Total: $_totalSaved)');
      return true;
      
    } catch (e) {
      _failedSaves++;
      print('✗ Failed to save data: $e');
      return false;
    }
  }
  
  /// 结束当前会话
  Future<String?> endSession() async {
    if (_currentFile == null) return null;
    
    final filePath = _currentFile!.path;
    _currentFile = null;
    _currentSessionId = null;
    
    print('✓ Session ended, file saved: $filePath');
    _lastSessionController.add(filePath);
    return filePath;
  }
  
  /// 获取所有保存的CSV文件
  Future<List<FileSystemEntity>> getSavedFiles() async {
    final directory = await getApplicationDocumentsDirectory();
    final kneeguardDir = Directory('${directory.path}/KneeGuard');
    
    if (!await kneeguardDir.exists()) {
      return [];
    }
    
    final files = await kneeguardDir.list().toList();
    files.sort((a, b) => b.path.compareTo(a.path)); // 最新的在前
    
    return files;
  }
  
  /// 删除指定文件
  Future<bool> deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        print('✓ Deleted file: $path');
        return true;
      }
      return false;
    } catch (e) {
      print('✗ Failed to delete file: $e');
      return false;
    }
  }
  
  /// 获取文件信息
  Future<Map<String, dynamic>?> getFileInfo(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      
      final stat = await file.stat();
      final lines = await file.readAsLines();
      
      return {
        'path': path,
        'name': path.split('/').last,
        'size': stat.size,
        'modified': stat.modified,
        'samples': lines.length - 1, // 减去表头
      };
    } catch (e) {
      print('✗ Failed to get file info: $e');
      return null;
    }
  }
  
  /// 重置统计
  void resetStats() {
    _totalSaved = 0;
    _failedSaves = 0;
  }

  void dispose() {
    _lastSessionController.close();
  }
  
  /// 获取存储目录路径
  Future<String> getStorageDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/KneeGuard';
  }
}
