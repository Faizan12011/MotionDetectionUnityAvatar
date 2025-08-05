// File: main.dart
// Purpose: Application entry-point. Initializes Firebase, sets up MaterialApp, 
// and provides `MainScreen` which serves as the home menu offering video recording,
// selection, record deletion, PIN reset, and logout.

import 'package:detection_app/firebase_options.dart';
import 'package:detection_app/records_delete.dart';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'pose_detection.dart';
import 'video_pose_sql.dart';
import 'pose_frame_db.dart';
import 'login.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(DetectionApp());
}

class DetectionApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Detection App',
      theme: ThemeData(primarySwatch: Colors.blue, fontFamily: 'Montserrat'),
      home: LoginPage(),
    );
  }
}

class MainScreen extends StatefulWidget {
  final String userName;

  const MainScreen({Key? key, required this.userName}) : super(key: key);

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late String _userName;
  final PinDb _pinDb = PinDb();

  @override
  void initState() {
    super.initState();
    _userName = widget.userName;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        elevation: 0,
        actions:
            _userName == 'Demo User'
                ? null
                : [
                  TextButton(
                    onPressed: _resetPin,
                    child: const Text(
                      'Reset PIN',
                      style: TextStyle(color: Colors.black),
                    ),
                  ),
                ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Image.asset('assets/logo2.png', height: 100),
              SizedBox(height: 20),
              Text(
                'Mobility Assesment',
                style: TextStyle(fontSize: 20, color: Colors.lightBlue),
              ),
              SizedBox(height: 40),
              Text(
                'Welcome $_userName',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 25),
              ),
              SizedBox(height: 40),

              /// Main Content
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    buildCustomButton(
                      context,
                      title: 'Record Video',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => PoseDetectionScreen(),
                          ),
                        );
                      },
                    ),
                    SizedBox(height: 20),
                    buildCustomButton(
                      context,
                      title: 'Choose Video',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => VideoPoseSqlScreen(),
                          ),
                        );
                      },
                    ),
                    SizedBox(height: 20),
                    buildCustomButton(
                      context,
                      title: 'Delete Records',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (context) => RecordsDelete(userName: _userName),
                          ),
                        );
                      },
                    ),
                    SizedBox(height: 20),
                    buildCustomButton(
                      color: Color(0xFF9B85F3),
                      context,
                      title: 'Logout',
                      onTap: () {
                        Navigator.pushAndRemoveUntil(
                          context,
                          MaterialPageRoute(builder: (context) => LoginPage()),
                          (route) => false,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------ Reset PIN logic ------------
  Future<void> _resetPin() async {
    final creds = await _showCredentialsDialog();
    if (creds == null) return;
    await _pinDb.open();
    await _pinDb.setCredentials(creds['pin']!, creds['name']!);
    if (!mounted) return;
    setState(() => _userName = creds['name']!);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('PIN reset')));
  }

  Future<Map<String, String>?> _showCredentialsDialog() async {
    final pinController = TextEditingController();
    final nameController = TextEditingController(text: _userName);
    return showDialog<Map<String, String>?>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Reset PIN & Name'),
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
                  decoration: const InputDecoration(hintText: 'New PIN'),
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

  /// Custom Elevated Button with Style
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
        padding: EdgeInsets.symmetric(horizontal: 40, vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
        backgroundColor: color ?? Colors.lightBlue,
        foregroundColor: Colors.black,
        shadowColor: Colors.black26,
        elevation: 5,
      ),
    );
  }
}
