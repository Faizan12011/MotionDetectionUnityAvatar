// File: AvatarPoseApplier.cs
// Purpose: Maps raw MediaPipe landmark positions to Unity humanoid bones each frame,
// converting coordinate systems and smoothing hip/arm offsets for live motion.

// AvatarPoseApplier.cs
using System;
using UnityEngine;

[RequireComponent(typeof(Animator))]
public class AvatarPoseApplier : MonoBehaviour
{
    private Animator anim;
    private Transform hipsParent;       // the parent of the Hips bone

    // BlazePose has 33 landmarks
    private enum MP {
        nose, lEye, rEye, lEar, rEar, lShoulder, rShoulder,
        lElbow, rElbow, lWrist, rWrist, lHip, rHip, lKnee, rKnee,
        lAnkle, rAnkle, lHeel, rHeel, lFoot, rFoot, lPinky, rPinky,
        lIndex, rIndex, lThumb, rThumb, lPinky2, rPinky2, lIndex2, rIndex2
    }

    private Vector3[] _latest;
    private bool _hasPose = false;

    // for vertical (Y) grounding
    private Vector3 _bindHipsLocalPos;
    private float   _bindHipLandmarkY;
    private bool    _gotFirstHip = false;

    // for horizontal XZ drift
    private Vector2 _prevHipXZ;
    private bool    _gotPrevHip = false;

    // smoothing & offsets
    private Vector3 _smoothVel = Vector3.zero;
    private const float SMOOTH_TIME = 0.1f;
    private const float SCALE       = 0.005f;

    // optional arm‑offsets from bind
    private Quaternion offArmL, offArmR;

    private void Awake()
    {
        anim = GetComponent<Animator>();
        var hips = anim.GetBoneTransform(HumanBodyBones.Hips);
        hipsParent = hips.parent;
        _bindHipsLocalPos = hipsParent.localPosition;

        // cache arm bind‑offsets so shoulders align
        offArmL = Quaternion.Inverse(
            Quaternion.FromToRotation(Vector3.right,
                anim.GetBoneTransform(HumanBodyBones.LeftUpperArm)
                    .InverseTransformDirection(Vector3.right)));
        offArmR = Quaternion.Inverse(
            Quaternion.FromToRotation(Vector3.left,
                anim.GetBoneTransform(HumanBodyBones.RightUpperArm)
                    .InverseTransformDirection(Vector3.left)));
    }

    public void ApplyPose(Vector3[] lm)
    {
        if (lm == null || lm.Length < 33) return;
        
        // Create a new array to store the converted landmarks
        Vector3[] convertedLm = new Vector3[lm.Length];
        
        // Calculate the center point (between shoulders) for better positioning
        Vector3 centerOffset = lm[(int)MP.nose]; // Use nose as center point
        
        // Convert from MediaPipe space to Unity space:
        // 1. Flip Y and Z axes (MediaPipe Z is up, Unity Y is up)
        // 2. Mirror X axis (left/right flip)
        // 3. Scale to reasonable size
        for (int i = 0; i < lm.Length; i++)
        {
            // Center the pose relative to nose and convert coordinates
            Vector3 adjusted = lm[i] - centerOffset;
            
            // Convert to Unity's coordinate system:
            // - X: Flip (mirror)
            // - Y: Convert from Z (MediaPipe) to Y (Unity)
            // - Z: Convert from Y (MediaPipe) to Z (Unity) and invert for depth
            convertedLm[i] = new Vector3(
                -adjusted.x * 0.01f,  // Mirror X and scale
                adjusted.z * 0.01f,    // Convert Z to Y and scale
                -adjusted.y * 0.01f    // Convert Y to Z, invert for depth, and scale
            );
            
            // Add some forward offset to position the avatar in the scene
            convertedLm[i].z += 2.0f;
            
            // Lift the avatar up a bit
            convertedLm[i].y += 1.0f;
        }
        
        _latest = convertedLm;
        _hasPose = true;
        
        // Debug log the first few points
        if (Time.frameCount % 30 == 0) // Log every 30 frames to avoid spamming
        {
            Debug.Log($"Applied pose - Sample points:\n" +
                     $"Nose: {_latest[(int)MP.nose]}\n" +
                     $"Left Shoulder: {_latest[(int)MP.lShoulder]}\n" +
                     $"Right Shoulder: {_latest[(int)MP.rShoulder]}");
        }
    }

    private void LateUpdate()
    {
        if (!_hasPose) return;
        var lm = _latest;

        // midpoint of the two hips in landmark space
        Vector3 hipMid = (lm[(int)MP.lHip] + lm[(int)MP.rHip]) * 0.5f;

        // --- vertical Y: delta from first‑seen hip Y ---
        if (!_gotFirstHip)
        {
            _bindHipLandmarkY = hipMid.y;
            _gotFirstHip = true;
        }
        float dy = (hipMid.y - _bindHipLandmarkY) * SCALE;
        Vector3 targetLocal = new Vector3(
            _bindHipsLocalPos.x,
            _bindHipsLocalPos.y + dy,
            _bindHipsLocalPos.z
        );
        hipsParent.localPosition = Vector3.SmoothDamp(
            hipsParent.localPosition,
            targetLocal,
            ref _smoothVel,
            SMOOTH_TIME
        );

        // --- horizontal XZ: apply as world‑space move on this GameObject ---
        Vector2 curXZ = new Vector2(hipMid.x, hipMid.z);
        if (!_gotPrevHip)
        {
            _prevHipXZ = curXZ;
            _gotPrevHip = true;
        }
        Vector2 deltaXZ = curXZ - _prevHipXZ;
        // move root in world (only XZ)
        transform.position += new Vector3(deltaXZ.x * SCALE, 0, deltaXZ.y * SCALE);
        _prevHipXZ = curXZ;

        // now rotate/apply limbs
        ApplyLimb(MP.lShoulder, MP.lElbow, MP.lWrist,
                  HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm,
                  lm, offArmL);
        ApplyLimb(MP.rShoulder, MP.rElbow, MP.rWrist,
                  HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm,
                  lm, offArmR);
        ApplyLimb(MP.lHip, MP.lKnee, MP.lAnkle,
                  HumanBodyBones.LeftUpperLeg, HumanBodyBones.LeftLowerLeg,
                  lm, Quaternion.identity);
        ApplyLimb(MP.rHip, MP.rKnee, MP.rAnkle,
                  HumanBodyBones.RightUpperLeg, HumanBodyBones.RightLowerLeg,
                  lm, Quaternion.identity);
    }

    private void ApplyLimb(MP j1, MP j2, MP j3,
                           HumanBodyBones upperBone, HumanBodyBones lowerBone,
                           Vector3[] lm, Quaternion offset)
    {
        var up = anim.GetBoneTransform(upperBone);
        var lo = anim.GetBoneTransform(lowerBone);
        if (up == null || lo == null) return;

        Vector3 A = lm[(int)j1], B = lm[(int)j2], C = lm[(int)j3];

        // upper
        Vector3 dirU = (B - A);
        if (dirU.sqrMagnitude > 0.01f)
        {
            dirU.Normalize();
            var rU = Quaternion.FromToRotation(Vector3.down, dirU) * offset;
            up.localRotation = Quaternion.Slerp(up.localRotation, rU, 0.2f);
        }

        // lower
        Vector3 dirL = (C - B);
        if (dirL.sqrMagnitude > 0.01f)
        {
            dirL.Normalize();
            var rL = Quaternion.FromToRotation(Vector3.down, dirL);
            lo.localRotation = Quaternion.Slerp(lo.localRotation, rL, 0.2f);
        }
    }
}
