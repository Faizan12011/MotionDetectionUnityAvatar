import 'package:flutter/material.dart';

import 'main.dart';
import 'pose_frame_db.dart';
import 'package:flutter/foundation.dart';

/// A simple login screen with two buttons:
/// 1. Login / Set PIN (depending on whether a PIN already exists)
/// 2. Demo User – bypasses PIN and goes straight to the app
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final PinDb _pinDb = PinDb();
  String? _userName;
  String? _storedPin;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      debugPrint('[Login] _init starting');
      await _pinDb.open();
      final creds = await _pinDb.getCredentials();
      debugPrint('[Login] _init creds: $creds');
      if (creds != null) {
        _storedPin = creds['pin'];
        _userName = creds['name'];
      }
    } catch (e, st) {
      debugPrint('ERROR in _init: $e\n$st');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _pinDb.close();
    super.dispose();
  }

  Future<void> _setCredentials() async {
    debugPrint('[Login] _setCredentials called');
    try {
      final creds = await _showCredentialsDialog();
      debugPrint('[Login] dialog result: $creds');
      if (creds == null) return;
      await _pinDb.setCredentials(creds['pin']!, creds['name']!);
      debugPrint('[Login] credentials saved');
      if (!mounted) return;
      setState(() {
        _storedPin = creds['pin'];
        _userName = creds['name'];
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PIN set successfully')));
      _navigateToApp(name: creds['name']!);
    } catch (e, st) {
      debugPrint('ERROR in _setCredentials: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _login() async {
    debugPrint('[Login] _login called');
    try {
      final pin = await _showPinDialog(title: 'Enter PIN');
      debugPrint('[Login] entered pin: $pin / stored: $_storedPin');
      if (pin == null) return;
      if (pin == _storedPin) {
        _navigateToApp(name: _userName ?? 'User');
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Incorrect PIN')));
        }
      }
    } catch (e, st) {
      debugPrint('ERROR in _login: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _navigateToApp({required String name}) async {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => MainScreen(userName: name)),
    );
  }

  Future<String?> _showPinDialog({required String title}) async {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: 'PIN'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Welcome')),
      body: Center(
        child: SingleChildScrollView(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo2.png', height: 150),
                SizedBox(height: 20),
                Text(
                  'Mobility Assesment',
                  style: TextStyle(fontSize: 20, color: Colors.lightBlue),
                ),
                SizedBox(height: 70),
                _buildPrimaryButton(),
                const SizedBox(height: 20),
                _buildDemoButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryButton() {
    final isFirstVisit = _storedPin == null;
    final String label = isFirstVisit ? 'Set PIN' : 'Login';

    return buildCustomButton(
      context,
      title: label.toUpperCase(),
      onTap: isFirstVisit ? _setCredentials : _login,
    );
  }

  Widget _buildDemoButton() {
    return buildCustomButton(
      context,
      title: 'DEMO USER',
      onTap: () => _navigateToApp(name: 'Demo User'),
    );
  }

  Future<Map<String, String>?> _showCredentialsDialog() async {
    final pinController = TextEditingController();
    final nameController = TextEditingController();
    return showDialog<Map<String, String>?>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Set PIN & Name'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(hintText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pinController,
                  decoration: const InputDecoration(hintText: 'PIN'),
                  keyboardType: TextInputType.number,
                  obscureText: true,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final pin = pinController.text.trim();
                  final name = nameController.text.trim();
                  if (pin.isEmpty || name.isEmpty) return;
                  Navigator.of(ctx).pop({'pin': pin, 'name': name});
                },
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }
}

Widget buildCustomButton(
  BuildContext context, {
  Color? color,
  required String title,
  required VoidCallback onTap,
}) {
  return ElevatedButton(
    onPressed: onTap,
    child: Text(
      title,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Colors.black,
      ),
    ),
    style: ElevatedButton.styleFrom(
      minimumSize: const Size(140, 60),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
      backgroundColor: color ?? Colors.lightBlue,
      foregroundColor: Colors.black,
      shadowColor: Colors.black26,
      elevation: 5,
    ),
  );
}
