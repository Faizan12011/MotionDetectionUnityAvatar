// File: pose_detection.dart
// Purpose: Implements live pose detection using device camera & Google ML Kit.
// Streams landmarks at ~5 FPS, renders them with `PosePainter`, and optionally
// pushes compressed pose data to Firebase Realtime DB & Firestore for storage.
// Provides option to save or skip cloud storage at session start.

import 'package:detection_app/login.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'dart:math' as math;
import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:detection_app/pose_firestore_writer.dart';

class PoseDetectionScreen extends StatefulWidget {
  @override
  _PoseDetectionScreenState createState() => _PoseDetectionScreenState();
}

class _PoseDetectionScreenState extends State<PoseDetectionScreen> {
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  bool _isBusy = false;
  bool _processingEnabled = true;
  bool _isDetectorReady = false;
  Size? _imageSize;
  List<Pose>? _poses;
  List<Pose>? _previousPoses;
  List<Pose>? _predictedPoses;
  double _interpolationFactor = 0.0;
  double? _prevMidHipZ;
  int _cameraRotation = 0;
  int _lastProcessTime = 0; // last time a frame was processed for UI refresh
  int _lastSendTime = 0; // last time pose data was pushed to Firebase
  String _poseCategory = "Initializing...";
  String _debugInfo = "";
  Timer? _animationTimer;
  final List<double> _frameRates = [];
  DateTime _lastFrameTime = DateTime.now();
  DatabaseReference? _sessionRef;
  // Firestore helper
  final PoseFirestoreWriter _firestoreWriter = PoseFirestoreWriter();
  bool _firestoreReady = false;
  String? _firestoreSessionName;
  String? _sessionId;

  int _lastCleanupTs = 0; // last cleanup timestamp (ms)
  static const int _cleanupIntervalMs = 30000; // run cleanup at most every 30 s

  @override
  void initState() {
    super.initState();

    // Ask for session name after first frame so context is ready
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final bool? saveChoice = await _askSaveOption();
      if (saveChoice == true) {
        // User chose to save – ask for session name first
        String? sessionName = await _promptForSessionName();
        if (sessionName == null) {
          // User cancelled name dialog, treat as don't save
          await _startLiveSession(
            'Live ${DateTime.now().toIso8601String()}',
            saveToFirestore: false,
          );
        } else {
          await _startLiveSession(sessionName, saveToFirestore: true);
        }
      } else {
        // Don't save
        await _startLiveSession(
          'Live ${DateTime.now().toIso8601String()}',
          saveToFirestore: false,
        );
      }
    });
  }

  Future<void> _startLiveSession(
    String name, {
    required bool saveToFirestore,
  }) async {
    _firestoreSessionName = name;
    _initializeDetector();
    _initializeCamera();
    _initFirebaseSession();
    if (saveToFirestore) {
      await _firestoreWriter
          .initSession(name, fps: 30)
          .then((_) => _firestoreReady = true);
    } else {
      _firestoreReady = false;
    }
  }

  Future<bool?> _askSaveOption() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => Container(
            height: MediaQuery.of(context).size.height,
            width: MediaQuery.of(context).size.width,
            color: Colors.white,
            child: Stack(
              children: [
                Positioned(
                  top: 20,
                  left: 20,
                  child: IconButton(
                    icon: Icon(Icons.arrow_back, color: Colors.black),
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.pop(context);
                    },
                  ),
                ),
                Positioned(
                  top: 20,
                  right: 20,
                  child: TextButton(
                    onPressed: () {
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(builder: (context) => LoginPage()),
                        (route) => false,
                      );
                    },
                    child: const Text('Logout'),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset('assets/logo2.png', height: 100),
                      SizedBox(height: 20),
                      Text(
                        'Mobility Assesment',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.lightBlue,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.white,
                        ),
                      ),
                      SizedBox(height: 40),
                      buildCustomButton(
                        context,
                        title: 'Save to Cloud',
                        onTap: () => Navigator.pop(ctx, true),
                      ),
                      SizedBox(height: 60),
                      buildCustomButton(
                        context,
                        title: 'Don\'t Save to Cloud',
                        onTap: () => Navigator.pop(ctx, false),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Future<String?> _promptForSessionName() {
    final TextEditingController ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Live Session Name'),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(hintText: 'Enter a name'),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }

  void _initializeDetector() {
    try {
      _poseDetector = GoogleMlKit.vision.poseDetector();
      _isDetectorReady = true;
    } catch (e) {
      print("Pose detector init error: $e");
      _debugInfo = "Detector error: $e";
    }
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraRotation = camera.sensorOrientation;

    _cameraController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _cameraController!.initialize();
    await _cameraController!.lockCaptureOrientation(
      DeviceOrientation.portraitUp,
    );
    await _cameraController!.startImageStream(_onCameraImage);

    _animationTimer = Timer.periodic(Duration(milliseconds: 8), (_) {
      if (_previousPoses != null && _poses != null) {
        _interpolationFactor += 0.2;
        if (_interpolationFactor > 1.0) _interpolationFactor = 1.0;
        if (_interpolationFactor < 1.0) {
          setState(() {});
        }
      }
    });

    setState(() {});
  }

  void _onCameraImage(CameraImage image) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Only process a frame every 200 ms (≈5 FPS) to keep ML-Kit memory under control
    if (now - _lastProcessTime < 33 ||
        _isBusy ||
        !_isDetectorReady ||
        !_processingEnabled)
      return;
    _lastProcessTime = now;
    _isBusy = true;

    try {
      final rotation =
          InputImageRotationValue.fromRawValue(_cameraRotation) ??
          InputImageRotation.rotation0deg;

      // Convert the camera image to NV21 (YUV420 semi-planar) because
      // google_mlkit_commons currently supports only NV21 / BGRA formats.
      final nv21Bytes = _yuv420ToNv21(image);

      final inputImage = InputImage.fromBytes(
        bytes: nv21Bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
        ),
      );

      final poses = await _poseDetector!.processImage(inputImage);
      final processEnd = DateTime.now();
      final processingTime =
          processEnd.difference(_lastFrameTime).inMilliseconds;
      _lastFrameTime = processEnd;

      _frameRates.add(1000 / processingTime);
      if (_frameRates.length > 10) _frameRates.removeAt(0);

      if (poses.isNotEmpty && mounted) {
        setState(() {
          _previousPoses = _poses;
          _poses = poses;
          _imageSize = Size(image.width.toDouble(), image.height.toDouble());
          _poseCategory = "Pose";
          _debugInfo = "FPS: ${(1000 / processingTime).toStringAsFixed(1)}";
          _interpolationFactor = 0.0;
          _predictedPoses = null;
        });
        // Send pose data to Firebase at a lower rate (~5 fps)
        if (now - _lastSendTime >= 200) {
          _lastSendTime = now;
          _sendPosesToFirebase(poses);
        }
      }
    } catch (e) {
      print('Stream frame error: $e');
    } finally {
      _isBusy = false;
    }
  }

  /// Converts a CameraImage in YUV_420_888 (three-plane) layout into a
  /// single NV21 byte buffer (luminance plane followed by interleaved VU).
  /// This format is supported by ML-Kit on Android for `InputImage.fromBytes`.
  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;

    final int ySize = width * height;
    // Allocate enough space for Y plus interleaved chroma. Because some devices
    // return odd dimensions and padded row-strides, use the actual plane sizes
    // to guarantee we never overflow.
    // Allocate exact NV21 size (Y + UV) now that we have safe indexing.
    final int uvSize = width * height ~/ 2;
    final Uint8List nv21 = Uint8List(ySize + uvSize);

    // Copy Y plane
    final Uint8List yPlane = image.planes[0].bytes;
    final int yRowStride = image.planes[0].bytesPerRow;
    int dstOffset = 0;
    for (int row = 0; row < height; row++) {
      nv21.setRange(dstOffset, dstOffset + width, yPlane, row * yRowStride);
      dstOffset += width;
    }

    // Interleave V (Cr) and U (Cb) bytes — order must be V then U for NV21.
    final Uint8List uPlane = image.planes[1].bytes;
    final Uint8List vPlane = image.planes[2].bytes;
    final int uRowStride = image.planes[1].bytesPerRow;
    final int vRowStride = image.planes[2].bytesPerRow;
    final int uPixelStride = image.planes[1].bytesPerPixel ?? 1;
    final int vPixelStride = image.planes[2].bytesPerPixel ?? 1;

    for (int row = 0; row < height ~/ 2; row++) {
      for (int x = 0; x < width ~/ 2; x++) {
        final int vIndex = row * vRowStride + x * vPixelStride;
        final int uIndex = row * uRowStride + x * uPixelStride;
        nv21[dstOffset++] = vPlane[vIndex];
        nv21[dstOffset++] = uPlane[uIndex];
      }
    }

    return nv21;
  }

  void _initFirebaseSession() async {
    // Firestore session is separate; stay in live mode here

    _sessionId = 'live';
    _sessionRef = FirebaseDatabase.instance.ref('sessions/$_sessionId');
    await _sessionRef!.child('metadata').set({
      'fps': 30,
      'status': 'live',
      'createdAt': ServerValue.timestamp,
    });
  }

  void _sendPosesToFirebase(List<Pose> poses) {
    // On live stream also write compressed frame to Firestore if available

    if (_sessionRef == null || poses.isEmpty) return;
    final pose = poses.first;

    // Convert pose to flat list in MediaPipe index order [x0,y0,z0, x1,y1,z1, ...]
    final orderedTypes = [
      PoseLandmarkType.nose, // 0
      PoseLandmarkType.leftEyeInner, // 1
      PoseLandmarkType.leftEye, // 2
      PoseLandmarkType.leftEyeOuter, // 3
      PoseLandmarkType.rightEyeInner, // 4
      PoseLandmarkType.rightEye, // 5
      PoseLandmarkType.rightEyeOuter, // 6
      PoseLandmarkType.leftEar, // 7
      PoseLandmarkType.rightEar, // 8
      PoseLandmarkType.leftMouth, // 9
      PoseLandmarkType.rightMouth, // 10
      PoseLandmarkType.leftShoulder, // 11
      PoseLandmarkType.rightShoulder, // 12
      PoseLandmarkType.leftElbow, // 13
      PoseLandmarkType.rightElbow, // 14
      PoseLandmarkType.leftWrist, // 15
      PoseLandmarkType.rightWrist, // 16
      PoseLandmarkType.leftPinky, // 17
      PoseLandmarkType.rightPinky, // 18
      PoseLandmarkType.leftIndex, // 19
      PoseLandmarkType.rightIndex, // 20
      PoseLandmarkType.leftThumb, // 21
      PoseLandmarkType.rightThumb, // 22
      PoseLandmarkType.leftHip, // 23
      PoseLandmarkType.rightHip, // 24
      PoseLandmarkType.leftKnee, // 25
      PoseLandmarkType.rightKnee, // 26
      PoseLandmarkType.leftAnkle, // 27
      PoseLandmarkType.rightAnkle, // 28
      PoseLandmarkType.leftHeel, // 29
      PoseLandmarkType.rightHeel, // 30
      PoseLandmarkType.leftFootIndex, // 31
      PoseLandmarkType.rightFootIndex, // 32
    ];

    final List<double> kp = [];
    final imgWidth = _imageSize?.width ?? 1.0;
    final imgHeight = _imageSize?.height ?? 1.0;
    for (final type in orderedTypes) {
      final lm = pose.landmarks[type];
      if (lm != null) {
        final xNorm = lm.x / imgWidth;
        final yNorm = lm.y / imgHeight;
        final zNorm = (lm.z ?? 0) / imgWidth;
        kp.addAll([xNorm, yNorm, zNorm]);
      } else {
        kp.addAll([0.0, 0.0, 0.0]);
      }
    }

    // Debug print the pose data being sent
    debugPrint('\n=== Sending Pose Data to Firebase ===');
    debugPrint('Total poses: ${poses.length}');
    debugPrint('Processing pose with ${pose.landmarks.length} landmarks');

    debugPrint('First 3 landmarks (x,y,z):');
    pose.landmarks.entries.take(3).forEach((entry) {
      final type = entry.key.toString().split('.').last;
      final landmark = entry.value;
      debugPrint(
        '  $type: ('
        '${landmark.x.toStringAsFixed(4)}, '
        '${landmark.y.toStringAsFixed(4)}, '
        '${(landmark.z ?? 0).toStringAsFixed(4)})',
      );
    });

    debugPrint('Total data points: ${kp.length}');
    debugPrint(
      'First 10 values: ${kp.take(10).map((v) => v.toStringAsFixed(4)).toList()}',
    );
    debugPrint('==============================\n');

    double hipDelta = 0.0;
    final lh = pose.landmarks[PoseLandmarkType.leftHip];
    final rh = pose.landmarks[PoseLandmarkType.rightHip];
    if (lh != null && rh != null) {
      final midZNorm = ((lh.z / imgWidth) + (rh.z / imgWidth)) / 2.0;
      if (_prevMidHipZ != null) {
        hipDelta = (midZNorm - _prevMidHipZ!) * 40.0;
      }
      _prevMidHipZ = midZNorm;
    }

    if (_firestoreReady) {
      _firestoreWriter.writeFrame(kp, hipDelta);
    }

    _sessionRef!
        .child('frames')
        .push()
        .set({'ts': ServerValue.timestamp, 'kp': kp, 'hipDelta': hipDelta})
        .then((_) async {
          // Throttle expensive cleanup queries to reduce download usage
          final int nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _lastCleanupTs < _cleanupIntervalMs) return;
          _lastCleanupTs = nowMs;

          // Remove frames older than 5 minutes (300 000 ms)
          final int cutoff = nowMs - 300000;
          final oldSnap =
              await _sessionRef!
                  .child('frames')
                  .orderByChild('ts')
                  .endAt(cutoff)
                  .limitToFirst(
                    256,
                  ) // cap to avoid large downloads in a single read
                  .get();
          if (oldSnap.exists) {
            for (final child in oldSnap.children) {
              await child.ref.remove();
            }
          }
        });
  }

  List<Pose>? _getInterpolatedPoses() {
    if (_poses == null || _previousPoses == null) return _poses;
    if (_interpolationFactor >= 1.0) {
      if (_predictedPoses == null) {
        _predictedPoses = _predictNextPoses();
      }
      return _poses;
    }

    List<Pose> result = [];
    double easedFactor =
        _interpolationFactor < 0.5
            ? 2 * _interpolationFactor * _interpolationFactor
            : 1 - math.pow(-2 * _interpolationFactor + 2, 2) / 2;

    for (int i = 0; i < _poses!.length; i++) {
      if (i >= _previousPoses!.length) continue;
      Pose current = _poses![i];
      Pose previous = _previousPoses![i];
      Map<PoseLandmarkType, PoseLandmark> interpolated = {};

      current.landmarks.forEach((type, lm) {
        if (previous.landmarks.containsKey(type)) {
          var prev = previous.landmarks[type]!;
          interpolated[type] = PoseLandmark(
            type: type,
            x: prev.x + (lm.x - prev.x) * easedFactor,
            y: prev.y + (lm.y - prev.y) * easedFactor,
            z: 0,
            likelihood:
                prev.likelihood +
                (lm.likelihood - prev.likelihood) * easedFactor,
          );
        } else {
          interpolated[type] = lm;
        }
      });

      result.add(Pose(landmarks: interpolated));
    }
    return result;
  }

  List<Pose>? _predictNextPoses() {
    if (_poses == null || _previousPoses == null) return _poses;
    if (_poses!.isEmpty || _previousPoses!.isEmpty) return _poses;

    List<Pose> predicted = [];
    for (int i = 0; i < _poses!.length; i++) {
      if (i >= _previousPoses!.length) continue;
      Pose current = _poses![i];
      Pose previous = _previousPoses![i];
      Map<PoseLandmarkType, PoseLandmark> predLandmarks = {};

      current.landmarks.forEach((type, lm) {
        if (previous.landmarks.containsKey(type)) {
          var prev = previous.landmarks[type]!;
          double vx = lm.x - prev.x;
          double vy = lm.y - prev.y;
          predLandmarks[type] = PoseLandmark(
            type: type,
            x: lm.x + vx * 0.3,
            y: lm.y + vy * 0.3,
            z: 0,
            likelihood: lm.likelihood,
          );
        } else {
          predLandmarks[type] = lm;
        }
      });
      predicted.add(Pose(landmarks: predLandmarks));
    }
    return predicted;
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _poseDetector?.close();
    _animationTimer?.cancel();
    if (_sessionRef != null) {
      _sessionRef!.child('metadata/status').set('ended');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final screenSize = MediaQuery.of(context).size;
    return Scaffold(
      appBar: AppBar(
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (context) => LoginPage()),
                (route) => false,
              );
            },
            child: const Text('Logout'),
          ),
        ],
      ),
      body: Stack(
        children: [
          CameraPreview(_cameraController!),
          if (_previousPoses != null && _poses != null && _imageSize != null)
            CustomPaint(
              size: screenSize,
              painter: PosePainter(
                poses: _getInterpolatedPoses() ?? _poses!,
                imageSize: _imageSize!,
                screenSize: screenSize,
                cameraRotation: _cameraRotation,
              ),
            ),
          Positioned(
            top: 50,
            left: 0,
            right: 0,
            child: Image.asset('assets/logo2.png', height: 50),
          ),
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: EdgeInsets.all(12),
                color: Colors.black45,
                child: Text(
                  _poseCategory,
                  style: TextStyle(color: Colors.white, fontSize: 24),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 200,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(160, 70),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                  backgroundColor:
                      _processingEnabled ? Colors.red : Colors.green,
                  foregroundColor: Colors.black,
                  shadowColor: Colors.black26,
                  elevation: 5,
                ),
                onPressed: () {
                  setState(() {
                    _processingEnabled = !_processingEnabled;
                  });
                },
                child: Text(_processingEnabled ? 'Stop' : 'Start'),
              ),
            ),
          ),
          Positioned(
            bottom: 120,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => PoseDetectionScreen(),
                    ),
                  );
                },
                child: Text(
                  'Retake',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(160, 70),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                  backgroundColor: Colors.lightBlue,
                  foregroundColor: Colors.black,
                  shadowColor: Colors.black26,
                  elevation: 5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size imageSize;
  final Size screenSize;
  final int cameraRotation;

  PosePainter({
    required this.poses,
    required this.imageSize,
    required this.screenSize,
    required this.cameraRotation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Different colors for different body parts
    final Paint jointPaint =
        Paint()
          ..color = Colors.red
          ..strokeWidth = 8.0;

    for (final pose in poses) {
      // Draw connections between landmarks with different colors first
      _drawBodyConnections(canvas, pose);

      // Draw landmarks with different sizes based on likelihood
      pose.landmarks.forEach((type, landmark) {
        // Increase point visibility
        double radius = landmark.likelihood > 0.5 ? 7.0 : 4.0;
        final scaledPoint = _scalePoint(landmark.x, landmark.y);

        // Draw joint with outline for better visibility
        canvas.drawCircle(
          scaledPoint,
          radius + 2.0,
          Paint()..color = Colors.black.withOpacity(0.5),
        );
        canvas.drawCircle(scaledPoint, radius, jointPaint);
      });
    }
  }

  void _drawBodyConnections(Canvas canvas, Pose pose) {
    // Upper body connections
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      Colors.yellow,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.leftHip,
      Colors.yellow,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.rightHip,
      Colors.yellow,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      Colors.yellow,
    );

    // Arm connections
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.leftElbow,
      Colors.green,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.leftWrist,
      Colors.green,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.rightElbow,
      Colors.green,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.rightWrist,
      Colors.green,
    );

    // Leg connections
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.leftKnee,
      Colors.blue,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.leftAnkle,
      Colors.blue,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.rightKnee,
      Colors.blue,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.rightAnkle,
      Colors.blue,
    );
  }

  void _drawConnection(
    Canvas canvas,
    Pose pose,
    PoseLandmarkType type1,
    PoseLandmarkType type2,
    Color color,
  ) {
    final landmark1 = pose.landmarks[type1];
    final landmark2 = pose.landmarks[type2];

    if (landmark1 != null && landmark2 != null) {
      final startPoint = _scalePoint(landmark1.x, landmark1.y);
      final endPoint = _scalePoint(landmark2.x, landmark2.y);

      // Make lines more visible with increased width and outline
      final Paint linePaint =
          Paint()
            ..color = color
            ..strokeWidth = 6.0
            ..strokeCap = StrokeCap.round;

      // Add outline to make lines more visible against any background
      final Paint outlinePaint =
          Paint()
            ..color = Colors.black.withOpacity(0.5)
            ..strokeWidth = 8.0
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke;

      // Draw outline first
      canvas.drawLine(startPoint, endPoint, outlinePaint);
      // Then draw the colored line
      canvas.drawLine(startPoint, endPoint, linePaint);
    }
  }

  Offset _scalePoint(double x, double y) {
    // Get the actual camera preview with correct aspect ratio
    final cameraAspectRatio = imageSize.width / imageSize.height;
    final screenAspectRatio = screenSize.width / screenSize.height;

    // Calculate area used by the preview on screen
    double previewWidth = screenSize.width;
    double previewHeight = screenSize.height;

    // Adjust for aspect ratio differences
    if (screenAspectRatio > cameraAspectRatio) {
      // Screen is wider than camera - width is constraining factor
      previewWidth = previewHeight * cameraAspectRatio;
    } else {
      // Screen is taller than camera - height is constraining factor
      previewHeight = previewWidth / cameraAspectRatio;
    }

    // Calculate offsets to center the preview
    final double offsetX = (screenSize.width - previewWidth) / 2;
    final double offsetY = (screenSize.height - previewHeight) / 2;

    double scaledX, scaledY;

    // Based on the screenshot, we need to make significant adjustments
    // double alignmentCorrection = 1.0; // No distortion in scale
    // double horizontalShift = 0.0 * previewWidth; // Centered horizontally
    // double verticalShift = -0.08 * previewHeight; // Move slightly more up

    double alignmentCorrection = 1.75; // No distortion in scale
    double horizontalShift = 0.38 * previewWidth; // Centered horizontally
    double verticalShift = -1.1 * previewHeight; // Move slightly more up

    switch (cameraRotation) {
      case 90: // Most common Android orientation
        // For 90 degree rotation, we need to mirror and flip coordinates
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 270:
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 0:
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 180:
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      default:
        // Apply the same transformation for all cases since the specific orientation isn't crucial
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.2) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
    }

    // Return final coordinates
    return Offset(scaledX, scaledY);
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) => true;
}
