/// CSV解析器 - 专门处理KneeGuard的CSV数据
class CSVParser {
  // CSV数据缓冲区
  String _buffer = '';
  
  // 解析后的数据缓存
  final List<Map<String, dynamic>> _cache = [];
  
  /// 添加接收到的数据块
  void addChunk(String chunk) {
    _buffer += chunk;
  }
  
  /// 检查是否有完整的数据可以解析
  bool hasCompleteData() {
    return _buffer.contains('\n');
  }
  
  /// 解析CSV并返回数据行
  List<Map<String, dynamic>> parse() {
    if (_buffer.isEmpty) return [];
    
    List<Map<String, dynamic>> result = [];
    
    // 找到最后一个换行符位置
    int lastNewline = _buffer.lastIndexOf('\n');
    
    if (lastNewline == -1) {
      // 没有完整行，保留buffer等待更多数据
      print('📝 No complete line yet, buffer size: ${_buffer.length} bytes');
      return [];
    }
    
    // 分离完整部分和不完整部分
    String completePart = _buffer.substring(0, lastNewline + 1);
    String incompletePart = _buffer.substring(lastNewline + 1);
    
    print('✂️ Splitting buffer: ${completePart.length} complete, ${incompletePart.length} incomplete');
    
    // 解析完整部分
    List<String> lines = completePart.split('\n');
    
    // 处理每一行
    for (int i = 0; i < lines.length; i++) {
      String line = lines[i].trim();
      
      // 跳过空行和表头
      if (line.isEmpty || line.startsWith('session_id')) continue;
      
      // 解析CSV行
      try {
        List<String> values = line.split(',');
        
        // 严格验证：必须是10列
        if (values.length != 10) {
          print('⚠️ Invalid CSV line (expected 10 columns, got ${values.length})');
          print('   Line: $line');
          continue;
        }
        
        // 解析数值
        double ax = double.parse(values[4]);
        double ay = double.parse(values[5]);
        double az = double.parse(values[6]);
        double gx = double.parse(values[7]);
        double gy = double.parse(values[8]);
        double gz = double.parse(values[9]);
        
        // 检查异常值并打印警告（但不跳过）
        if (ax.abs() > 20 || ay.abs() > 20 || az.abs() > 20) {
          print('⚠️ Large acceleration detected: ax=$ax, ay=$ay, az=$az at t=${values[3]}');
        }
        
        if (gx.abs() > 2000 || gy.abs() > 2000 || gz.abs() > 2000) {
          print('⚠️ Large gyro detected: gx=$gx, gy=$gy, gz=$gz at t=${values[3]}');
        }
        
        // 全部添加到结果（包括异常值）
        result.add({
          'session_id': values[0],
          'device_id': values[1],
          'sensor_id': values[2],
          't_us': int.parse(values[3]),
          'ax': ax,
          'ay': ay,
          'az': az,
          'gx': gx,
          'gy': gy,
          'gz': gz,
        });
      } catch (e) {
        print('❌ Parse error: $e');
        print('   Line: $line');
      }
    }
    
    // 重要：保留不完整的部分到buffer
    _buffer = incompletePart;
    
    if (result.isNotEmpty) {
      print('✅ Parsed ${result.length} samples successfully');
    }
    
    return result;
  }
  
  /// 清空缓冲区
  void clear() {
    _buffer = '';
    _cache.clear();
  }
  
  /// 获取缓冲区大小
  int get bufferSize => _buffer.length;
}
