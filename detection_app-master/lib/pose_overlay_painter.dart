import 'package:flutter/material.dart';
import 'package:google_ml_kit/google_ml_kit.dart';

class VideoPosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size videoSize; // original resolution of video frame
  final Size screenSize; // size of widget displaying video
  final int cameraRotation; // degrees: 0,90,180,270

  VideoPosePainter({
    required this.poses,
    required this.videoSize,
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
      // Draw connections between landmarks
      _drawBodyConnections(canvas, pose);

      // Draw landmarks with different sizes based on likelihood
      pose.landmarks.forEach((type, landmark) {
        // Increase point visibility based on likelihood (reduced sizes)
        double radius =
            landmark.likelihood > 0.7
                ? 5.0 // Reduced from 7.0
                : landmark.likelihood > 0.5
                ? 3.5 // Reduced from 5.0
                : 2.0; // Reduced from 3.0

        // Scale the coordinates to match the display size
        final scaledPoint = _scalePoint(landmark.x, landmark.y);

        // Draw joint with outline for better visibility
        canvas.drawCircle(
          scaledPoint,
          radius + 1.5, // Reduced from 2.0
          Paint()..color = Colors.black.withOpacity(0.7),
        );

        // Use different colors for different body parts
        Paint pointPaint = Paint()..color = Colors.red;

        // Adjust color based on the point type
        if (type == PoseLandmarkType.nose ||
            type == PoseLandmarkType.leftEye ||
            type == PoseLandmarkType.rightEye ||
            type == PoseLandmarkType.leftEar ||
            type == PoseLandmarkType.rightEar) {
          pointPaint.color = Colors.yellow;
        } else if (type == PoseLandmarkType.leftShoulder ||
            type == PoseLandmarkType.rightShoulder ||
            type == PoseLandmarkType.leftHip ||
            type == PoseLandmarkType.rightHip) {
          pointPaint.color = Colors.orange;
        } else if (type.name.contains("Wrist") || type.name.contains("Hand")) {
          pointPaint.color = Colors.green;
        } else if (type.name.contains("Ankle") || type.name.contains("Foot")) {
          pointPaint.color = Colors.blue;
        }

        canvas.drawCircle(scaledPoint, radius, pointPaint);
      });
    }
  }

  Offset _scalePoint(double x, double y) {
    // Get the actual camera preview with correct aspect ratio
    final cameraAspectRatio = videoSize.width / videoSize.height;
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

    // Alignment tweaks
    // const double alignmentCorrection = 1.8; // no scale distortion
    // const double horizontalShift = 170; // centered horizontally
    // const double verticalShift = 250; // slight upward shift (ratio)
    double alignmentCorrection = 1.0; // No distortion in scale
    double horizontalShift = 0.0 * previewWidth; // Centered horizontally
    double verticalShift = -0.08 * previewHeight; // Move slightly more up
    switch (cameraRotation) {
      case 90: // Most common Android orientation
        // For 90 degree rotation, we need to mirror and flip coordinates
        scaledX =
            (previewWidth * 0.5) +
            ((x / videoSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / videoSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 270:
        scaledX =
            (previewWidth * 0.5) +
            ((x / videoSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / videoSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 0:
        scaledX =
            (previewWidth * 0.5) +
            ((x / videoSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / videoSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 180:
        scaledX =
            (previewWidth * 0.5) +
            ((x / videoSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / videoSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      default:
        // Apply the same transformation for all cases since the specific orientation isn't crucial
        scaledX =
            (previewWidth * 0.5) +
            ((x / videoSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.2) +
            ((y / videoSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
    }
    // switch (cameraRotation) {
    //   case 90:
    //   case 270:
    //   case 180:
    //   case 0:
    //   default:
    //     scaledX =
    //         (previewWidth * 0.5) +
    //         ((x / videoSize.width - 0.5) * previewWidth * alignmentCorrection) +
    //         offsetX +
    //         horizontalShift;

    //     scaledY =
    //         (previewHeight * 0.5) +
    //         ((y / videoSize.height - 0.5) *
    //             previewHeight *
    //             alignmentCorrection) +
    //         offsetY +
    //         verticalShift;
    //     break;
    // }

    return Offset(scaledX, scaledY);
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

      // Make lines more visible with increased width and outline (reduced thickness)
      final Paint linePaint =
          Paint()
            ..color = color
            ..strokeWidth =
                4.0 // Reduced from 6.0
            ..strokeCap = StrokeCap.round;

      // Add outline to make lines more visible against any background
      final Paint outlinePaint =
          Paint()
            ..color = Colors.black.withOpacity(0.5)
            ..strokeWidth =
                6.0 // Reduced from 8.0
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke;

      // Draw outline first
      canvas.drawLine(startPoint, endPoint, outlinePaint);
      // Then draw the colored line
      canvas.drawLine(startPoint, endPoint, linePaint);
    }
  }

  @override
  bool shouldRepaint(VideoPosePainter oldDelegate) => true;
}
