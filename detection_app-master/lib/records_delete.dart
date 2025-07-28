import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:detection_app/login.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';

class RecordsDelete extends StatefulWidget {
  final String userName;

  const RecordsDelete({Key? key, required this.userName}) : super(key: key);

  @override
  State<RecordsDelete> createState() => _RecordsDeleteState();
}

class _RecordsDeleteState extends State<RecordsDelete> {
  final _sessionsStream =
      FirebaseFirestore.instance
          .collection('pose_sessions')
          .orderBy('createdAt', descending: true)
          .snapshots();

  Future<void> _deleteSession(DocumentReference doc) async {
    try {
      // Delete sub-collection frames first (if needed)
      final frames = await doc.collection('frames').get();
      for (final f in frames.docs) {
        await f.reference.delete();
      }
      await doc.delete();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Session deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
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
            child: const Text('Logout', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
      backgroundColor: Colors.white,
      body: Center(
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
            SizedBox(height: 30),
            Text(
              widget.userName,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 25),
            ),
            SizedBox(
              height: 300,
              width: 300,
              child: StreamBuilder<QuerySnapshot>(
                stream: _sessionsStream,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                    return const Center(child: Text('No records'));
                  }

                  final docs = snapshot.data!.docs;
                  return ListView.separated(
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final doc = docs[index];
                      final name = doc['name'] as String? ?? 'Unnamed';
                      final ts = (doc['createdAt'] as Timestamp?)?.toDate();
                      final formatted =
                          ts != null
                              ? DateFormat('MMMM d yyyy HH:mm').format(ts)
                              : 'Unknown date';
                      return buildCustomButton(
                        context,
                        title: '$name $formatted',
                        onTap: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder:
                                (ctx) => AlertDialog(
                                  title: const Text('Delete Session'),
                                  content: Text(
                                    'Are you sure you want to delete "$name"?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed:
                                          () => Navigator.pop(ctx, false),
                                      child: const Text('No'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Yes'),
                                    ),
                                  ],
                                ),
                          );
                          if (confirm == true) {
                            await _deleteSession(doc.reference);
                          }
                        },
                      );
                    },
                  );
                },
              ),
            ),
            SizedBox(height: 30),
            buildCustomButton(
              color: Color(0xFF9B85F3),

              context,
              title: 'Back',
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}
