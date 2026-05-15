import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'firebase_options.dart';
import 'services/api.dart';
import 'screens/login.dart';
import 'screens/register.dart';
import 'screens/asha_dashboard.dart';
import 'screens/gov_dashboard.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel alertChannel = AndroidNotificationChannel(
  'high_risk_alerts',
  'High Risk Alerts',
  description: 'Water contamination and disease outbreak alerts',
  importance: Importance.max,
  playSound: true,
);

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _showLocalNotification(message);
}

Future<void> _showLocalNotification(RemoteMessage message) async {
  if (message.notification == null) return;

  // FIX: show() now uses ALL named parameters — id: title: body: etc.
  await flutterLocalNotificationsPlugin.show(
    id: 0,
    title: message.notification!.title,
    body: message.notification!.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        alertChannel.id,
        alertChannel.name,
        channelDescription: alertChannel.description,
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        fullScreenIntent: true,
        visibility: NotificationVisibility.public,
      ),
    ),
    payload: message.data['click_action'],
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  // FIX: InitializationSettings uses named params — android: not positional
  const initSettings = InitializationSettings(
    android: androidSettings,
  );

  // FIX: initialize() now requires named param: settings:
  await flutterLocalNotificationsPlugin.initialize(
    settings: initSettings,
    onDidReceiveNotificationResponse: (NotificationResponse details) {},
  );

await flutterLocalNotificationsPlugin
    .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
    ?.createNotificationChannel(alertChannel);

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(const MyApp());
}

final _navigatorKey = GlobalKey<NavigatorState>();

final _router = GoRouter(
  navigatorKey: _navigatorKey,
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/register', builder: (context, state) => const RegisterScreen()),
    GoRoute(path: '/dashboard/asha', builder: (context, state) => const AshaDashboard()),
    GoRoute(path: '/dashboard/gov', builder: (context, state) => const GovDashboard()),
  ],
);

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      await _showLocalNotification(message);

      if (message.notification == null) return;
      final ctx = _navigatorKey.currentContext;
      if (ctx == null) return;

      showDialog(
        context: ctx,
        builder: (_) => AlertDialog(
          title: Row(children: [
            const Text('⚠️ ', style: TextStyle(fontSize: 20)),
            Expanded(
              child: Text(
                message.notification!.title ?? 'Alert',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ]),
          content: Text(message.notification!.body ?? ''),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK',
                  style: TextStyle(color: Color(0xFF007AFF))),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Water Disease Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007AFF)),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    await Future.delayed(const Duration(milliseconds: 300));
    final token = await ApiService.getToken();
    final user = await ApiService.getUser();
    if (!mounted) return;
    if (token != null && user != null) {
      final role = user['role'] as String? ?? '';
      if (role == 'government' || role == 'admin') {
        context.go('/dashboard/gov');
      } else {
        context.go('/dashboard/asha');
      }
    } else {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFf5f7fa),
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFF007AFF)),
      ),
    );
  }
}