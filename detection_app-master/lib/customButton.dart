import 'package:flutter/material.dart';

Widget buildCustomButton(
  BuildContext context, {
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
      backgroundColor: Colors.lightBlue,
      foregroundColor: Colors.black,
      shadowColor: Colors.black26,
      elevation: 5,
    ),
  );
}
