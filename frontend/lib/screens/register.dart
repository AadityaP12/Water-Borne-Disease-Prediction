import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/api.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  bool _loading = false;

  final _form = {
    'email': '',
    'password': '',
    'full_name': '',
    'phone_number': '',
    'role': 'asha',
    'state': '',
    'district': '',
    'block': '',
    'village': '',
    'preferred_language': 'en',
  };

  final _languages = const [
    {'label': 'English', 'value': 'en'},
    {'label': 'Hindi', 'value': 'hi'},
    {'label': 'Assamese', 'value': 'as'},
    {'label': 'Bengali', 'value': 'bn'},
    {'label': 'Manipuri', 'value': 'mni'},
  ];

  final _roles = const [
    {'label': 'ASHA Worker', 'value': 'asha'},
    {'label': 'Government Official', 'value': 'government'},
  ];

  Future<void> _handleRegister() async {
    if (_form['email']!.isEmpty ||
        _form['password']!.isEmpty ||
        _form['full_name']!.isEmpty) {
      _showError('Please fill in all required fields.');
      return;
    }
    setState(() => _loading = true);
    try {
      // Step 1: Create Firebase Auth account
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _form['email']!.trim(),
        password: _form['password']!,
      );

      // Step 2: Sync profile to Firestore via backend
      final data = await ApiService.request(
        '/auth/sync-user',
        method: 'POST',
        body: {
          'full_name':          _form['full_name'],
          'phone_number':       _form['phone_number'],
          'role':               _form['role'],
          'state':              _form['state'],
          'district':           _form['district'],
          'block':              _form['block'],
          'village':            _form['village'],
          'preferred_language': _form['preferred_language'],
        },
      );

      await ApiService.saveUser({
        'uid':      data['user_id'],
        'role':     data['role'],
        'email':    _form['email'],
        'state':    _form['state'],
        'district': _form['district'],
      });

      if (!mounted) return;
      final role = data['role'] as String? ?? '';
      if (role == 'government' || role == 'admin') {
        context.go('/dashboard/gov');
      } else {
        context.go('/dashboard/asha');
      }
    } on FirebaseAuthException catch (e) {
      _showError(_friendlyError(e.code));
    } catch (e) {
      _showError(e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'This email is already registered.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'network-request-failed':
        return 'Network error. Check your connection.';
      default:
        return 'Registration failed. Please try again.';
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFf5f7fa),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              const Text('Create Account',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1a1a2e))),
              const SizedBox(height: 4),
              const Text('Water Disease Monitoring System',
                  style: TextStyle(fontSize: 14, color: Color(0xFF666666))),
              const SizedBox(height: 28),

              _label('Full Name *'),
              _textField('Enter your full name', (v) => _form['full_name'] = v),
              _label('Email *'),
              _textField('Enter your email', (v) => _form['email'] = v,
                  keyboardType: TextInputType.emailAddress),
              _label('Password *'),
              _textField('Create a password (min 6 chars)',
                  (v) => _form['password'] = v,
                  obscure: true),
              _label('Phone Number'),
              _textField('+91XXXXXXXXXX', (v) => _form['phone_number'] = v,
                  keyboardType: TextInputType.phone),

              _label('Role *'),
              _dropdown(_roles, _form['role']!,
                  (v) => setState(() => _form['role'] = v)),

              _label('State'),
              _textField('e.g. Assam', (v) => _form['state'] = v),
              _label('District'),
              _textField('e.g. Kamrup', (v) => _form['district'] = v),
              _label('Block'),
              _textField('e.g. Guwahati', (v) => _form['block'] = v),
              _label('Village'),
              _textField('e.g. Jalukbari', (v) => _form['village'] = v),

              _label('Preferred Language'),
              _dropdown(_languages, _form['preferred_language']!,
                  (v) => setState(() => _form['preferred_language'] = v)),

              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _loading ? null : _handleRegister,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF007AFF),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Create Account',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('Already have an account? Sign in',
                      style:
                          TextStyle(color: Color(0xFF007AFF), fontSize: 14)),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333))),
      );

  Widget _textField(String hint, Function(String) onChanged,
          {TextInputType? keyboardType, bool obscure = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: TextField(
          obscureText: obscure,
          keyboardType: keyboardType,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFe0e0e0))),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFe0e0e0))),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          ),
        ),
      );

  Widget _dropdown(List<Map<String, String>> items, String value,
          Function(String) onChanged) =>
      Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFe0e0e0)),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            items: items
                .map((e) =>
                    DropdownMenuItem(value: e['value'], child: Text(e['label']!)))
                .toList(),
            onChanged: (v) => onChanged(v!),
          ),
        ),
      );
}