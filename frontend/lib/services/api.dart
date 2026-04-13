import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static const String baseUrl = 'http://192.168.1.7:8080/api/v1';

  static final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    headers: {'Content-Type': 'application/json'},
  ));

  // --- Get fresh Firebase ID token ---
  static Future<String?> getToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    return await user.getIdToken();
  }

  // --- User profile storage (role, district, state etc from Firestore) ---
  static Future<void> saveUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user', jsonEncode(user));
  }

  static Future<Map<String, dynamic>?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString('user');
    if (u == null) return null;
    return jsonDecode(u) as Map<String, dynamic>;
  }

  static Future<void> clearUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user');
  }

  // --- Sign out ---
  static Future<void> signOut() async {
    await FirebaseAuth.instance.signOut();
    await clearUser();
  }

  // --- API call helper ---
  static Future<dynamic> request(
    String endpoint, {
    String method = 'GET',
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    final options = Options(method: method);
    if (auth) {
      final token = await getToken();
      if (token != null) {
        options.headers = {'Authorization': 'Bearer $token'};
      }
    }

    try {
      final response = await _dio.request(
        endpoint,
        data: body,
        options: options,
      );
      return response.data;
    } on DioException catch (e) {
      final detail = e.response?.data?['detail'];
      throw Exception(detail ?? 'Error ${e.response?.statusCode ?? 'unknown'}');
    }
  }
}
