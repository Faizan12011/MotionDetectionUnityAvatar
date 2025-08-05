// File: pose_firestore_writer.dart
// Purpose: Utility for compressing pose frames (JSON → GZIP → Base64) and
// persisting them in a Firestore `pose_sessions/{session}/frames` collection.
// Maintains running byte counter in parent session doc.

import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Helper responsible for writing compressed pose frames to Firestore.
///
/// Usage:
///   final writer = PoseFirestoreWriter();
///   await writer.initSession('My session', fps: 30);
///   await writer.writeFrame(kpList, hipDelta);
class PoseFirestoreWriter {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Reference to the parent session document (pose_sessions/{docId}).
  late DocumentReference _sessionDoc;

  bool _initialised = false;

  /// Initialise a new session document and return its id.
  /// The document will contain basic metadata and a running byte counter.
  Future<String> initSession(String name, {required int fps}) async {
    // Let Firestore generate a unique document id.
    _sessionDoc = _firestore.collection('pose_sessions').doc();

    await _sessionDoc.set({
      'name': name,
      'fps': fps,
      'createdAt': FieldValue.serverTimestamp(),
      'bytes': 0, // running total increased on every frame write
    });
    _initialised = true;
    return _sessionDoc.id;
  }

  /// Compresses and writes a single frame to the sub-collection `frames`.
  /// [kp] is the flattened landmark list, [hipDelta] the z-translation value.
  Future<void> writeFrame(List<double> kp, double hipDelta) async {
    if (!_initialised) return;
    final String encoded = _encodeFrame(kp, hipDelta);

    await _sessionDoc.collection('frames').add({
      'ts': FieldValue.serverTimestamp(),
      'data': encoded,
    });

    // Update running byte counter atomically
    await _sessionDoc.update({'bytes': FieldValue.increment(encoded.length)});
  }

  /// Converts the numeric payload to JSON, GZIP, then Base64.
  String _encodeFrame(List<double> kp, double hipDelta) {
    final jsonStr = jsonEncode({'kp': kp, 'hip': hipDelta});
    final compressed = gzip.encode(utf8.encode(jsonStr));
    return base64Encode(compressed);
  }
}
