// File: RealtimePoseReceiver.cs
// Purpose: Listens to Firebase Realtime Database `sessions/{id}/frames` feed
// (child-added) and forwards each decoded landmark Vector3[] to any avatar
// controller implementing `ApplyPose` for near-real-time remote playback.

using System;
using System.Collections;
using System.Collections.Generic;
using Firebase;
using Firebase.Database;
using UnityEngine;

public class RealtimePoseReceiver : MonoBehaviour
{
    [Tooltip("Session ID (must match Flutter). Default 'live'.")]
    public string sessionId = "live";

    [Tooltip("Script that consumes Vector3[] landmarks and drives the avatar")]
    public MonoBehaviour avatarController; // must implement ApplyPose(Vector3[])

    private Query framesRef;
    private bool firebaseReady;
    private bool _skipInitial = true;    // skip the very first ChildAdded event

    [SerializeField] private bool enableReceiver = false;
    private async void Start()
    {
        if (!enableReceiver)
        {
            // Receiver disabled to avoid duplicating Firebase listeners (PipeServer handles data).
            return;
        }
        DontDestroyOnLoad(gameObject);

        if (string.IsNullOrEmpty(sessionId))
        {
            Debug.LogWarning("RealtimePoseReceiver: sessionId not set – pose stream will not start.");
            return;
        }

        var depStatus = await FirebaseApp.CheckAndFixDependenciesAsync();
        if (depStatus != DependencyStatus.Available)
        {
            Debug.LogError("Firebase deps NOT ready, aborting");
            return;
        }
        firebaseReady = true;

        // Auto‑link if you forgot to assign the controller
        if (avatarController == null ||
            avatarController.GetType().GetMethod("ApplyPose", new[] { typeof(Vector3[]) }) == null)
        {
            avatarController = FindObjectOfType<AvatarPoseApplier>(true);
            if (avatarController == null)
                Debug.LogWarning("RealtimePoseReceiver: no AvatarPoseApplier found in scene.");
        }

        // Quick GetValueAsync so we don't start listening until perms are OK
        try
        {
            await FirebaseDatabase.DefaultInstance
                .GetReference($"sessions/{sessionId}/frames")
                .LimitToLast(1)
                .GetValueAsync();
        }
        catch (Exception ex)
        {
            Debug.LogError($"[FB] initial GetValue failed: {ex.Message}");
        }

        // Now start listening; the very first ChildAdded we’ll drop
        framesRef = FirebaseDatabase.DefaultInstance
            .GetReference($"sessions/{sessionId}/frames")
            .LimitToLast(1);
        framesRef.ChildAdded += OnFrame;

        Debug.Log("RealtimePoseReceiver: Listening for new frames …");
    }

    private void OnDestroy()
    {
        if (firebaseReady && framesRef != null)
            framesRef.ChildAdded -= OnFrame;
    }

    private int _frameCounter = 0;
    private void OnFrame(object sender, ChildChangedEventArgs e)
    {
        if (_skipInitial)
        {
            _skipInitial = false;
            return;
        }

        if (!e.Snapshot.Exists || !e.Snapshot.HasChild("kp"))
        {
            Debug.LogError("No 'kp' child in snapshot");
            return;
        }

        var raw = e.Snapshot.Child("kp").Value as IList<object>;
        if (raw == null)
        {
            Debug.LogError("Failed to parse kp data as IList<object>");
            return;
        }

        if (raw.Count % 3 != 0)
        {
            Debug.LogError($"Unexpected data length: {raw.Count} (should be multiple of 3)");
            return;
        }

        // Log first few points for debugging
        var debugInfo = new System.Text.StringBuilder("Received pose data points:\n");
        int numPoints = Mathf.Min(10, raw.Count / 3); // Show first 10 points or all if less
        for (int i = 0; i < numPoints; i++)
        {
            int idx = i * 3;
            debugInfo.AppendLine($"Point {i}: X={raw[idx]}, Y={raw[idx+1]}, Z={raw[idx+2]}");
        }
        Debug.Log(debugInfo.ToString());

        int count = raw.Count / 3;
        var lm = new Vector3[count];
        for (int i = 0; i < count; i++)
        {
            float x = Convert.ToSingle(raw[i*3 + 0]);
            float y = Convert.ToSingle(raw[i*3 + 1]);
            float z = Convert.ToSingle(raw[i*3 + 2]);
            lm[i] = new Vector3(x,y,z);
        }

        _frameCounter++;
        if (_frameCounter % 30 == 0)
            Debug.Log($"RealtimePoseReceiver: received frame {_frameCounter}");

        if (avatarController != null)
        {
            var method = avatarController.GetType().GetMethod("ApplyPose");
            method?.Invoke(avatarController, new object[]{ lm });
        }
    }
}
