// File: video_pose_sql.dart
// Purpose: Allows users to pick a video, extracts frames at `_poseFps`, runs
// pose detection (Google ML Kit), stores per-frame landmarks in SQLite for
// overlay, streams down-sampled poses to Firebase RTDB, and optionally uploads
// compressed frames to Firestore.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:detection_app/login.dart';
import 'package:detection_app/pose_firestore_writer.dart';

import 'package:detection_app/pose_frame_db.dart';
import 'package:detection_app/pose_overlay_painter.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';

class VideoPoseSqlScreen extends StatefulWidget {
  const VideoPoseSqlScreen({Key? key}) : super(key: key);

  @override
  State<VideoPoseSqlScreen> createState() => _VideoPoseSqlScreenState();
}

class _VideoPoseSqlScreenState extends State<VideoPoseSqlScreen> {
  late final PoseDetector _detector;
  bool _detectorReady = false;
  VideoPlayerController? _controller;
  XFile? _sourceVideo;

  final PoseFrameDb _db = PoseFrameDb();
  Timer? _streamTimer;
  List<Pose>? _overlayPoses;
  int _lastSentTs = -1;
  bool dontAsk = false;
  bool shoudlclose = true;

  bool _processing = false;
  double _progress = 0.0;

  late DatabaseReference _sessionRef;
  String _sessionId = 'live';
  Size? _imageSize;

  // Firestore helper for compressed historical frames
  final PoseFirestoreWriter _firestoreWriter = PoseFirestoreWriter();
  bool _firestoreReady = false;

  // Previous mid-hip Z (normalized) to compute hip displacement delta between frames
  double? _prevMidHipZ;

  // Cleanup helpers to limit RTDB read bandwidth
  int _lastCleanupTs = 0;
  static const int _cleanupIntervalMs =
      30000; // perform cleanup at most every 30 s

  /// FPS used for frame extraction and pose streaming
  static const int _poseFps = 5;

  static const List<PoseLandmarkType> _orderedTypes = [
    PoseLandmarkType.nose,
    PoseLandmarkType.leftEyeInner,
    PoseLandmarkType.leftEye,
    PoseLandmarkType.leftEyeOuter,
    PoseLandmarkType.rightEyeInner,
    PoseLandmarkType.rightEye,
    PoseLandmarkType.rightEyeOuter,
    PoseLandmarkType.leftEar,
    PoseLandmarkType.rightEar,
    PoseLandmarkType.leftMouth,
    PoseLandmarkType.rightMouth,
    PoseLandmarkType.leftShoulder,
    PoseLandmarkType.rightShoulder,
    PoseLandmarkType.leftElbow,
    PoseLandmarkType.rightElbow,
    PoseLandmarkType.leftWrist,
    PoseLandmarkType.rightWrist,
    PoseLandmarkType.leftPinky,
    PoseLandmarkType.rightPinky,
    PoseLandmarkType.leftIndex,
    PoseLandmarkType.rightIndex,
    PoseLandmarkType.leftThumb,
    PoseLandmarkType.rightThumb,
    PoseLandmarkType.leftHip,
    PoseLandmarkType.rightHip,
    PoseLandmarkType.leftKnee,
    PoseLandmarkType.rightKnee,
    PoseLandmarkType.leftAnkle,
    PoseLandmarkType.rightAnkle,
    PoseLandmarkType.leftHeel,
    PoseLandmarkType.rightHeel,
    PoseLandmarkType.leftFootIndex,
    PoseLandmarkType.rightFootIndex,
  ];

  bool _awaitingSaveChoice = false;

  @override
  void initState() {
    super.initState();
    _detector = PoseDetector(
      options: PoseDetectorOptions(
        mode: PoseDetectionMode.single,
        model: PoseDetectionModel.base,
      ),
    );
    _detectorReady = true;
    _db.open();
    _initFirebaseSession();
    _pickVideo();
  }

  @override
  void dispose() {
    _streamTimer?.cancel();
    _controller?.dispose();
    _detector.close();
    _db.clearAndClose(shoudlclose);
    // No explicit Firestore cleanup necessary
    // mark session ended in RTDB
    _sessionRef.child('metadata/status').set('ended');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_sourceVideo == null) {
      // Show pick button
      return Center(child: buildButton());
    }

    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: VideoPlayer(_controller!),
          ),
        ),
        if (_awaitingSaveChoice)
          Positioned.fill(child: Container(color: Colors.white)),
        if (_awaitingSaveChoice)
          Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/logo2.png', height: 100),
                  SizedBox(height: 20),
                  Text(
                    'Mobility Assesment',
                    style: TextStyle(fontSize: 20, color: Colors.lightBlue),
                  ),
                  SizedBox(height: 70),
                  buildCustomButton(
                    context,
                    title: 'Save to Cloud',
                    onTap: () => _handleSaveDecision(true),
                  ),
                  const SizedBox(height: 60),
                  buildCustomButton(
                    context,
                    title: "Don't Save to Cloud",
                    onTap: () => _handleSaveDecision(false),
                  ),
                ],
              ),
            ),
          ),
        if (!_awaitingSaveChoice && _overlayPoses != null)
          CustomPaint(
            painter: VideoPosePainter(
              poses: _overlayPoses!,
              videoSize: _controller!.value.size,
              screenSize: MediaQuery.of(context).size,
              cameraRotation: 0,
            ),
          ),
        if (!_awaitingSaveChoice &&
            !_processing &&
            !_controller!.value.isPlaying)
          Center(child: Icon(Icons.play_arrow, color: Colors.white, size: 64)),
        if (!_awaitingSaveChoice && _processing)
          Container(
            color: Colors.black54,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 80,
                    height: 80,
                    child: CircularProgressIndicator(
                      value: _progress,
                      strokeWidth: 8,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.lightBlueAccent,
                      ),
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Processing \\${(_progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (!_awaitingSaveChoice)
          Positioned(
            bottom: 200,
            left: 0,
            right: 0,
            child: Center(child: Column(children: [buildButton()])),
          ),
        if (!_awaitingSaveChoice) ...[
          Positioned(
            top: 30,
            left: 0,
            right: 0,
            child: Image.asset('assets/logo2.png', height: 50),
          ),
          Positioned(
            bottom: 120,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton(
                onPressed: () {
                  setState(() {
                    shoudlclose = false;
                  });
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => VideoPoseSqlScreen(),
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
      ],
    );
  }

  Widget buildButton() {
    if (_sourceVideo == null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset('assets/logo2.png', height: 150),
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
          SizedBox(height: 70),
          // ElevatedButton(
          //   onPressed: _pickVideo,
          //   child: Text(
          //     'Select Video',
          //     style: TextStyle(
          //       fontSize: 18,
          //       fontWeight: FontWeight.w600,
          //       color: Colors.black,
          //     ),
          //   ),
          //   style: ElevatedButton.styleFrom(
          //     padding: EdgeInsets.symmetric(horizontal: 40, vertical: 20),
          //     shape: RoundedRectangleBorder(
          //       borderRadius: BorderRadius.circular(25),
          //     ),
          //     backgroundColor: Colors.lightBlue,
          //     foregroundColor: Colors.black,
          //     shadowColor: Colors.black26,
          //     elevation: 5,
          //   ),
          // ),
        ],
      );
    }
    if (_processing) {
      return ElevatedButton(
        onPressed: null,
        child: CircularProgressIndicator(color: Colors.white),
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: 40, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(25),
          ),
          backgroundColor: Colors.lightBlue,
          foregroundColor: Colors.black,
          shadowColor: Colors.black26,
          elevation: 5,
        ),
      );
    }
    final bool playing = _controller!.value.isPlaying;
    return ElevatedButton(
      onPressed: () {
        setState(() {
          if (playing) {
            _controller!.pause();
          } else {
            _controller!.play();
          }
        });
      },
      child: Text(
        playing ? 'Pause' : 'Play',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
      ),
      style: ElevatedButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: 40, vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
        backgroundColor: Colors.lightBlue,
        foregroundColor: Colors.black,
        shadowColor: Colors.black26,
        elevation: 5,
      ),
    );
  }

  Future<void> _pickVideo() async {
    final XFile? picked = await ImagePicker().pickVideo(
      source: ImageSource.gallery,
    );
    if (picked == null) return Navigator.pop(context);

    _controller = VideoPlayerController.file(File(picked.path));
    await _controller!.initialize();
    _imageSize = _controller!.value.size;

    setState(() {
      _sourceVideo = picked;
      _awaitingSaveChoice = true;
    });
  }

  Future<void> _handleSaveDecision(bool save) async {
    String sessionName = 'Session ${DateTime.now().toIso8601String()}';
    dontAsk = !save;
    if (save) {
      final TextEditingController ctrl = TextEditingController();
      final String? entered = await showDialog<String>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Session name'),
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
      if (entered != null && entered.isNotEmpty) sessionName = entered;
    }

    setState(() => _awaitingSaveChoice = false);
    await _startProcessing(sessionName);
  }

  Future<void> _startProcessing(String sessionName) async {
    await _db.open();

    try {
      await _db.clear();

      if (saveToCloud(sessionName)) {
        await _firestoreWriter.initSession(sessionName, fps: _poseFps);
        _firestoreReady = true;
      }

      setState(() {
        _processing = true;
        _progress = 0;
      });

      await _processVideoWithFFmpeg(_sourceVideo!.path);

      await _controller!.seekTo(Duration.zero);
      _controller!.play();
      _controller!.addListener(_onVideoControllerUpdate);
      _startStreaming();

      setState(() => _processing = false);
    } catch (e, st) {
      debugPrint('ERROR in _startProcessing: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Processing error: $e')));
      }
      setState(() {
        _processing = false;
        _awaitingSaveChoice = false;
      });
    }
  }

  bool saveToCloud(String _) => !dontAsk;

  Future<void> _processVideoWithFFmpeg(String videoPath) async {
    final tempDir = await getTemporaryDirectory();
    final frameDir = Directory('${tempDir.path}/frames');
    if (frameDir.existsSync()) frameDir.deleteSync(recursive: true);
    await frameDir.create();

    final outputPattern = '${frameDir.path}/frame_%04d.png';
    await FFmpegKit.execute(
      '-i "$videoPath" -vf fps=$_poseFps "$outputPattern"',
    );

    final frameFiles =
        frameDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.png'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final totalFrames = frameFiles.length;
    final int frameIntervalMs = (1000 / _poseFps).round();
    for (int i = 0; i < totalFrames; i++) {
      final File frame = frameFiles[i];
      final poses = await _detector.processImage(InputImage.fromFile(frame));
      if (poses.isNotEmpty) {
        final kp = _poseToList(poses.first, _controller!.value.size);
        await _db.insertFrame(i * frameIntervalMs, kp, '');
      }
      setState(() => _progress = i / totalFrames);
      await frame.delete();
    }
  }

  void _streamTick(Timer t) async {
    if (!_controller!.value.isPlaying) return;
    final int ts = _controller!.value.position.inMilliseconds;
    final row = await _db.getClosest(ts);
    if (row == null) return;
    final int frameTs = row['ts'] as int;
    if (frameTs == _lastSentTs) return;
    final List<double> kp =
        (jsonDecode(row['kp'] as String) as List)
            .map((e) => (e as num).toDouble())
            .toList();
    final pose = _listToPose(kp, _controller!.value.size);
    _sendPosesToFirebase([pose]);
    _lastSentTs = frameTs;
    setState(() => _overlayPoses = [pose]);
  }

  void _onVideoControllerUpdate() {
    final playing = _controller!.value.isPlaying;
    if (playing && _streamTimer == null) {
      _startStreaming();
    } else if (!playing && _streamTimer != null) {
      _stopStreaming();
    }
  }

  void _startStreaming() {
    _streamTimer ??= Timer.periodic(
      const Duration(milliseconds: 33),
      _streamTick,
    );
  }

  void _stopStreaming() {
    _streamTimer?.cancel();
    _streamTimer = null;
  }

  List<double> _poseToList(Pose pose, Size size) {
    final List<double> list = [];
    for (final t in _orderedTypes) {
      final landmark = pose.landmarks[t]!;
      list.add(landmark.x / size.width);
      list.add(landmark.y / size.height);
      list.add(landmark.z / size.width);
    }
    return list;
  }

  Pose _listToPose(List<double> kp, Size size) {
    final Map<PoseLandmarkType, PoseLandmark> map = {};
    for (int i = 0; i < _orderedTypes.length; i++) {
      final double x = kp[i * 3] * size.width;
      final double y = kp[i * 3 + 1] * size.height;
      final double z = kp[i * 3 + 2] * size.width;
      map[_orderedTypes[i]] = PoseLandmark(
        type: _orderedTypes[i],
        x: x,
        y: y,
        z: z,
        likelihood: 0.0,
      );
    }
    return Pose(landmarks: map);
  }

  Future<void> _initFirebaseSession() async {
    _sessionRef = FirebaseDatabase.instance.ref('sessions/$_sessionId');
    await _sessionRef.child('metadata').set({
      'fps': _poseFps,
      'status': 'live',
      'createdAt': ServerValue.timestamp,
    });
  }

  void _sendPosesToFirebase(List<Pose> poses) {
    if (poses.isEmpty) return;
    final pose = poses.first;
    final List<double> kp = [];
    final double imgWidth = _imageSize?.width ?? 1.0;
    final double imgHeight = _imageSize?.height ?? 1.0;
    for (final type in _orderedTypes) {
      final lm = pose.landmarks[type];
      if (lm != null) {
        final xNorm = lm.x / imgWidth;
        final yNorm = lm.y / imgHeight;
        final zNorm = lm.z / imgWidth;
        kp.addAll([xNorm, yNorm, zNorm]);
      } else {
        kp.addAll([0.0, 0.0, 0.0]);
      }
    }
    // Calculate hip Z delta (forward/backwards motion)
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

    // Write compressed frame to Firestore
    if (_firestoreReady && !dontAsk) {
      _firestoreWriter.writeFrame(kp, hipDelta);
    }

    _sessionRef
        .child('frames')
        .push()
        .set({'ts': ServerValue.timestamp, 'kp': kp, 'hipDelta': hipDelta})
        .then((_) async {
          // Throttle cleanup to reduce download cost
          final int nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _lastCleanupTs < _cleanupIntervalMs) return;
          _lastCleanupTs = nowMs;

          // Remove frames older than 5 minutes
          final int cutoff = nowMs - 300000;
          final oldSnap =
              await _sessionRef
                  .child('frames')
                  .orderByChild('ts')
                  .endAt(cutoff)
                  .limitToFirst(256)
                  .get();
          if (oldSnap.exists) {
            for (final child in oldSnap.children) {
              await child.ref.remove();
            }
          }
        });
  }
}
