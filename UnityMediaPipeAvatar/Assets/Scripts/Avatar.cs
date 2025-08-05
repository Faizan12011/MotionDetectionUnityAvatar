// File: Avatar.cs
// Purpose: Applies MediaPipe pose data to a humanoid avatar: manages calibration, bone alignment,
// foot IK/grounding, and character movement based on tracked hip motion.

using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/*
 * Calibration: Stores reference poses for accurate tracking.

Bone Alignment: Matches avatar bones to tracked landmarks.

Ground Adjustment: Keeps feet planted on surfaces.

Movement: Applies hip-based motion to the character.
 */
public class Avatar : MonoBehaviour
{
    public Camera previewCamera; // OPTIONAL
    public Animator animator;
    public LayerMask ground;
    public bool footTracking = false;
    public float footGroundOffset = .02f;

    [Header("IK Foot Planting")]
    public bool enableFootIK = false; // disable IK when locking feet
    [Range(0f,1f)] public float footIKWeight = 1f;
    public float footRaycastDistance = 1f;

    [Header("Lock Foot Pose")]
    public bool lockFeet = true;
    [Header("Calibration")]
    public bool useCalibrationData = false;
    public PersistentCalibrationData calibrationData;

    public bool Calibrated { get; private set; }

    private PipeServer server;

    private Quaternion initialRotation;
    private Vector3 initialPosition;
    private Quaternion targetRot;

    private Dictionary<HumanBodyBones, CalibrationData> parentCalibrationData = new Dictionary<HumanBodyBones, CalibrationData>();
    private CalibrationData spineUpDown, hipsTwist,chest,head;

    private Vector3 previousTrackedHipPosition;

    private Rigidbody rb;

    // cached initial foot transforms
    private Quaternion leftFootInitialLocalRot, rightFootInitialLocalRot;
    private Vector3 leftFootInitialLocalPos, rightFootInitialLocalPos;

    private void Start()
    {
        rb = GetComponent<Rigidbody>();
        initialRotation = transform.rotation;
        initialPosition = transform.position;

        if (calibrationData && useCalibrationData)
        {
            CalibrateFromPersistent();
        }

        server = FindObjectOfType<PipeServer>();
        if (server == null)
        {
            Debug.LogError("You must have a PipeServer in the scene!");
        }
        previousTrackedHipPosition = server.GetVirtualHip().position;

        // cache initial foot local transforms
        var lf = animator.GetBoneTransform(HumanBodyBones.LeftFoot);
        var rf = animator.GetBoneTransform(HumanBodyBones.RightFoot);
        if (lf != null)
        {
            leftFootInitialLocalRot = lf.localRotation;
            leftFootInitialLocalPos = lf.localPosition;
        }
        if (rf != null)
        {
            rightFootInitialLocalRot = rf.localRotation;
            rightFootInitialLocalPos = rf.localPosition;
        }
    }

    public void CalibrateFromPersistent()
    {
        parentCalibrationData.Clear();

        if (calibrationData)
        {
            foreach (PersistentCalibrationData.CalibrationEntry d in calibrationData.parentCalibrationData)
            {
                parentCalibrationData.Add(d.bone, d.data.ReconstructReferences());
            }
            spineUpDown = calibrationData.spineUpDown.ReconstructReferences();
            hipsTwist = calibrationData.hipsTwist.ReconstructReferences();
            chest = calibrationData.chest.ReconstructReferences();
            head = calibrationData.head.ReconstructReferences();
        }

        animator.enabled = false; // disable animator to stop interference.
        Calibrated = true;
    }
    public void Calibrate()
    {
        // Here we store the values of variables required to do the correct rotations at runtime.
        print("Calibrating on " + gameObject.name);

        parentCalibrationData.Clear();

        // Manually setting calibration data for the spine chain as we want really specific control over that.
        spineUpDown = new CalibrationData(animator.transform, animator.GetBoneTransform(HumanBodyBones.Spine), animator.GetBoneTransform(HumanBodyBones.Neck),
            server.GetVirtualHip(), server.GetVirtualNeck());
        hipsTwist = new CalibrationData(animator.transform, animator.GetBoneTransform(HumanBodyBones.Hips), animator.GetBoneTransform(HumanBodyBones.Hips),
            server.GetLandmark(Landmark.RIGHT_HIP), server.GetLandmark(Landmark.LEFT_HIP));
        chest = new CalibrationData(animator.transform, animator.GetBoneTransform(HumanBodyBones.Chest), animator.GetBoneTransform(HumanBodyBones.Chest),
            server.GetLandmark(Landmark.RIGHT_HIP), server.GetLandmark(Landmark.LEFT_HIP));
        head = new CalibrationData(animator.transform, animator.GetBoneTransform(HumanBodyBones.Neck), animator.GetBoneTransform(HumanBodyBones.Head),
            server.GetVirtualNeck(), server.GetLandmark(Landmark.NOSE));

        // Adding calibration data automatically for the rest of the bones.
        AddCalibration(HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm,
            server.GetLandmark(Landmark.RIGHT_SHOULDER), server.GetLandmark(Landmark.RIGHT_ELBOW));
        AddCalibration(HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand,
            server.GetLandmark(Landmark.RIGHT_ELBOW), server.GetLandmark(Landmark.RIGHT_WRIST));

        AddCalibration(HumanBodyBones.RightUpperLeg, HumanBodyBones.RightLowerLeg,
            server.GetLandmark(Landmark.RIGHT_HIP), server.GetLandmark(Landmark.RIGHT_KNEE));
        AddCalibration(HumanBodyBones.RightLowerLeg, HumanBodyBones.RightFoot,
            server.GetLandmark(Landmark.RIGHT_KNEE), server.GetLandmark(Landmark.RIGHT_ANKLE));

        AddCalibration(HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm,
            server.GetLandmark(Landmark.LEFT_SHOULDER), server.GetLandmark(Landmark.LEFT_ELBOW));
        AddCalibration(HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand,
            server.GetLandmark(Landmark.LEFT_ELBOW), server.GetLandmark(Landmark.LEFT_WRIST));

        AddCalibration(HumanBodyBones.LeftUpperLeg, HumanBodyBones.LeftLowerLeg,
            server.GetLandmark(Landmark.LEFT_HIP), server.GetLandmark(Landmark.LEFT_KNEE));
        AddCalibration(HumanBodyBones.LeftLowerLeg, HumanBodyBones.LeftFoot,
            server.GetLandmark(Landmark.LEFT_KNEE), server.GetLandmark(Landmark.LEFT_ANKLE));

        if (footTracking)
        {
            AddCalibration(HumanBodyBones.LeftFoot, HumanBodyBones.LeftToes,
                server.GetLandmark(Landmark.LEFT_ANKLE), server.GetLandmark(Landmark.LEFT_FOOT_INDEX));
            AddCalibration(HumanBodyBones.RightFoot, HumanBodyBones.RightToes,
                server.GetLandmark(Landmark.RIGHT_ANKLE), server.GetLandmark(Landmark.RIGHT_FOOT_INDEX));
        }

        animator.enabled = false; // disable animator to stop interference.
        Calibrated = true;
        StartCoroutine(ReEnableAnimator());
    }

    private IEnumerator ReEnableAnimator()
    {
        yield return new WaitForSeconds(1); // Adjust delay if needed
        animator.enabled = true;
    }

    public void StoreCalibration()
    {
        if (!calibrationData)
        {
            Debug.LogError("Optional calibration data must be assigned to store into.");
            return;
        }

        List<PersistentCalibrationData.CalibrationEntry> calibrations = new List<PersistentCalibrationData.CalibrationEntry>();
        foreach (KeyValuePair<HumanBodyBones, CalibrationData> k in parentCalibrationData)
        {
            calibrations.Add(new PersistentCalibrationData.CalibrationEntry() { bone = k.Key, data = k.Value });
        }
        calibrationData.parentCalibrationData = calibrations.ToArray();

        calibrationData.spineUpDown = spineUpDown;
        calibrationData.hipsTwist = hipsTwist;
        calibrationData.chest = chest;
        calibrationData.head = head;

        calibrationData.Dirty();

        print("Completed storing calibration data "+calibrationData.name);
    }
    private void AddCalibration(HumanBodyBones parent, HumanBodyBones child, Transform trackParent,Transform trackChild)
    {
        parentCalibrationData.Add(parent,
            new CalibrationData(animator.transform, animator.GetBoneTransform(parent), animator.GetBoneTransform(child),
            trackParent, trackChild));
    }

    private void OnAnimatorIK(int layerIndex)
    {
        if (!enableFootIK || animator == null) return;

        if (!lockFeet)
        {
            ApplyFootIK(AvatarIKGoal.LeftFoot, HumanBodyBones.LeftFoot);
            ApplyFootIK(AvatarIKGoal.RightFoot, HumanBodyBones.RightFoot);
        }
    }

    private void ApplyFootIK(AvatarIKGoal goal, HumanBodyBones bone)
    {
        Transform footT = animator.GetBoneTransform(bone);
        Vector3 origin = footT.position + Vector3.up * 0.1f;
        if (Physics.Raycast(origin, Vector3.down, out RaycastHit hit, footRaycastDistance, ground, QueryTriggerInteraction.Ignore))
        {
            Vector3 targetPos = hit.point + Vector3.up * footGroundOffset;
            Quaternion targetRot = Quaternion.FromToRotation(Vector3.up, hit.normal) * footT.rotation;

            animator.SetIKPositionWeight(goal, footIKWeight);
            animator.SetIKRotationWeight(goal, footIKWeight);
            animator.SetIKPosition(goal, targetPos);
            animator.SetIKRotation(goal, targetRot);
        }
        else
        {
            animator.SetIKPositionWeight(goal, 0f);
            animator.SetIKRotationWeight(goal, 0f);
        }
    }

    private void Update()
    {
        // Adjust the vertical position of the avatar to keep it approximately grounded.
        if (parentCalibrationData.Count > 0 && !lockFeet)
        {
            float displacement = 0;
            RaycastHit h1;
            if (Physics.Raycast(animator.GetBoneTransform(HumanBodyBones.LeftFoot).position, Vector3.down, out h1, 0.5f, ground, QueryTriggerInteraction.Ignore))
            {
                displacement = (h1.point - animator.GetBoneTransform(HumanBodyBones.LeftFoot).position).y;
            }
            if (Physics.Raycast(animator.GetBoneTransform(HumanBodyBones.RightFoot).position, Vector3.down, out h1, 0.5f, ground, QueryTriggerInteraction.Ignore))
            {
                float displacement2 = (h1.point - animator.GetBoneTransform(HumanBodyBones.RightFoot).position).y;
                if (Mathf.Abs(displacement2) < Mathf.Abs(displacement))
                {
                    displacement = displacement2;
                }
            }

            // Fallback: if still below ground due to physics penetration, use feet bounds
            float lowestFootY = Mathf.Min(animator.GetBoneTransform(HumanBodyBones.LeftFoot).position.y,
                                           animator.GetBoneTransform(HumanBodyBones.RightFoot).position.y);
            if (Physics.Raycast(transform.position + Vector3.up * 0.5f, Vector3.down, out h1, 2f, ground, QueryTriggerInteraction.Ignore))
            {
                float groundY = h1.point.y;
                float penetration = (groundY + footGroundOffset) - lowestFootY;
                if (penetration > 0.0005f) // avatar sunk into floor
                {
                    displacement += penetration;
                }
            }

            // Apply vertical correction so that the lowest foot stays near the ground
            if (Mathf.Abs(displacement) > 0.0005f)
            {
                // keep a small offset so feet are not exactly intersecting ground
                float correction = displacement + footGroundOffset * Mathf.Sign(displacement);
                if (rb != null && !rb.isKinematic)
                {
                    rb.MovePosition(rb.position + new Vector3(0, correction, 0));
                }
                else
                {
                    transform.position += new Vector3(0, correction, 0);
                }
            }
        }

        // Compute the new rotations for each limbs of the avatar using the calibration datas we created before.
        foreach(var i in parentCalibrationData)
        {
            if(lockFeet && (i.Key == HumanBodyBones.LeftFoot || i.Key == HumanBodyBones.RightFoot || i.Key == HumanBodyBones.LeftToes || i.Key == HumanBodyBones.RightToes))
                continue;
        {
            Quaternion deltaRotTracked = Quaternion.FromToRotation(i.Value.initialDir, i.Value.CurrentDirection);
            i.Value.parent.rotation = deltaRotTracked * i.Value.initialRotation;
        }

        // Deal with spine chain as a special case.
        if(parentCalibrationData.Count > 0)
        {
            Vector3 hd = head.CurrentDirection;
            // Some are partial rotations which we can stack together to specify how much we should rotate.
            Quaternion headr = Quaternion.FromToRotation(head.initialDir, hd);
            Quaternion twist = Quaternion.FromToRotation(hipsTwist.initialDir, 
                Vector3.Slerp(hipsTwist.initialDir,hipsTwist.CurrentDirection,.25f));
            Quaternion updown = Quaternion.FromToRotation(spineUpDown.initialDir,
                Vector3.Slerp(spineUpDown.initialDir, spineUpDown.CurrentDirection, .25f));

            // Compute the final rotations.
            Quaternion h = updown * updown * updown * twist * twist;
            Quaternion s = h * twist * updown;
            Quaternion c = s * twist * twist;
            float speed = 10f;
            hipsTwist.Tick(h * hipsTwist.initialRotation, speed);
            spineUpDown.Tick(s * spineUpDown.initialRotation, speed);
            chest.Tick(c * chest.initialRotation, speed);
            head.Tick(updown * twist * headr * head.initialRotation, speed);

            // For additional responsiveness, we rotate the entire transform slightly based on the hips.
            Vector3 d = Vector3.Slerp(hipsTwist.initialDir, hipsTwist.CurrentDirection, .25f);
            d.y *= 0.5f;
            Quaternion deltaRotTracked = Quaternion.FromToRotation(hipsTwist.initialDir, d);
            targetRot= deltaRotTracked * initialRotation;
            transform.rotation = Quaternion.Lerp(transform.rotation, targetRot, Time.deltaTime * speed);

        }

        // Apply movement from BOTH sources
        Vector3 trackedHipPos = server.GetVirtualHip().position;
        Vector3 hipDelta = trackedHipPos - previousTrackedHipPosition;
        Vector3 moveVector = new Vector3(hipDelta.x, 0, hipDelta.z) * 1.0f;
        transform.position += moveVector;
        previousTrackedHipPosition = trackedHipPos;


    }

}}
