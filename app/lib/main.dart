import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'screens/monitoring_screen.dart';
import 'screens/report_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Request permissions
  try {
    await _requestPermissions();
  } catch (e) {
    print('Permission request error: $e');
  }
  
  runApp(const KneeGuardianApp());
}

/// Request required permissions
Future<void> _requestPermissions() async {
  try {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.storage,
    ].request();
  } catch (e) {
    print('Permission request failed: $e');
  }
}

class KneeGuardianApp extends StatelessWidget {
  const KneeGuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KneeGuardian',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.light(
          primary: Color(0xFF2E3440),
          secondary: Color(0xFF434C5E),
          surface: Color(0xFFFFFFFF),
          background: Color(0xFFF8F9FA),
          error: Color(0xFFD32F2F),
        ),
        scaffoldBackgroundColor: Color(0xFFF8F9FA),
        cardTheme: CardThemeData(
          elevation: 2,
          shadowColor: Colors.black12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        appBarTheme: AppBarTheme(
          elevation: 0,
          centerTitle: true,
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF2E3440),
        ),
        textTheme: TextTheme(
          displayLarge: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2E3440),
            letterSpacing: -0.5,
          ),
          headlineMedium: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: Color(0xFF2E3440),
          ),
          bodyLarge: TextStyle(
            fontSize: 16,
            color: Color(0xFF5E6C7E),
          ),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

/// Main screen with tab navigation
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        toolbarHeight: 100,
        title: Padding(
          padding: EdgeInsets.symmetric(vertical: 12.0),
          child: Image.asset(
            'assets/images/logo_title.png',
            height: 40,  // logo高度
            fit: BoxFit.contain,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(60),
          child: Container(
            margin: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(25),
              color: Colors.white,
              border: Border.all(
                color: Color(0xFFE5E9F0),
                width: 1,
              ),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: UnderlineTabIndicator(
                borderSide: BorderSide(
                  color: Color(0xFF2E3440),
                  width: 3,
                ),
                insets: EdgeInsets.symmetric(horizontal: 40),
              ),
              dividerColor: Colors.transparent,
              labelColor: Color(0xFF2E3440),
              unselectedLabelColor: Color(0xFF8896A8),
              labelStyle: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
              tabs: [
                Tab(
                  icon: Icon(Icons.monitor_heart_outlined, size: 24),
                  text: 'LIVE',
                ),
                Tab(
                  icon: Icon(Icons.analytics_outlined, size: 24),
                  text: 'ANALYTICS',
                ),
              ],
            ),
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          color: Color(0xFFF8F9FA),
        ),
        child: TabBarView(
          controller: _tabController,
          children: const [
            MonitoringScreen(),
            ReportScreen(),
          ],
        ),
      ),
    );
  }
}

