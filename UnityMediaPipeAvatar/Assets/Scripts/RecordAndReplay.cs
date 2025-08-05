// File: RecordAndReplay.cs
// Purpose: Records avatar transforms to memory while data is being received
// and plays them back for instant replay. Also exposes simple scene reload and
// UI messaging utilities.

using System.Collections.Generic;
using TMPro;
using UnityEngine;
using UnityEngine.UIElements;
using UnityEngine.SceneManagement; // for scene reload

public class RecordAndReplay : MonoBehaviour
{
    [SerializeField] private GameObject[] avatarParts;
    private List<PlayerTransform[]> snapshots;
    private PlayerTransform[] initialPose; // stores avatar standing pose at game start
    private bool isRecording = false;
    private bool isReplaying = false;
    private float interval = 0.016f;
    private float time = 0;
    private int index = 0;
    [SerializeField] private GameObject pipeServer;
    private PipeServer pipeServerScript;

    [SerializeField] private TMP_Text messageText;
    [SerializeField] private TMP_Text updateText;
    private bool recorded = false;

    [Tooltip("Reload current scene after replay ends instead of restoring pose")] 
    [SerializeField] private bool restartSceneAfterReplay = true;


    // Start is called once before the first execution of Update after the MonoBehaviour is created
    void Start()
    {
        snapshots = new List<PlayerTransform[]>();
        pipeServerScript = pipeServer.GetComponent<PipeServer>();

        // Capture initial standing pose so we can restore it after replay
        initialPose = new PlayerTransform[avatarParts.Length];
        initialPose[0] = new PlayerTransform
        {
            position = avatarParts[0].transform.position,
            rotation = avatarParts[0].transform.rotation
        };
        for (int i = 1; i < avatarParts.Length; i++)
        {
            initialPose[i] = new PlayerTransform
            {
                position = avatarParts[i].transform.position,
                rotation = avatarParts[i].transform.rotation
            };
        }
    }

    // Update is called once per frame
    void Update()
    {
        UpdateUI();
        time += Time.deltaTime;
        if(time >= interval && isRecording)
        {
            time = 0;
            Record();
        }

        if(isReplaying)
        {
            time = 0;
            Replay();
        }

        if(!isRecording && pipeServerScript.dataReceiving && !isReplaying)
        {
            isRecording = true;
            isReplaying = false;
            snapshots.Clear();
            index = 0;
            UpdateUI();
        }
        if(Input.GetKeyDown(KeyCode.P))
        {
            StartReplay();
            UpdateUI();
        }
        if(isRecording && !pipeServerScript.dataReceiving && !isReplaying)
        {
            isRecording = false;
            recorded = true;
            UpdateUI();
        }

    }

    void Record()
    {
        PlayerTransform[] playerTransforms = new PlayerTransform[avatarParts.Length];
        playerTransforms[0] = new PlayerTransform
        {
            position = avatarParts[0].transform.position,
            rotation = avatarParts[0].transform.rotation
        };
        for (int i = 1; i < avatarParts.Length; i++)
        {
            playerTransforms[i] = new PlayerTransform
            {
                position = avatarParts[i].transform.localPosition,
                rotation = avatarParts[i].transform.localRotation
            };
        }
        snapshots.Add(playerTransforms);
        Debug.Log("Recording");
    }

    void Replay()
    {
        if (GetComponent<Animator>().enabled)
            GetComponent<Animator>().enabled = false;

        if (snapshots.Count > index)
        {
            avatarParts[0].transform.position = snapshots[index][0].position;
            avatarParts[0].transform.rotation = snapshots[index][0].rotation;
            for (int i = 1; i < avatarParts.Length; i++)
            {
                avatarParts[i].transform.localPosition = snapshots[index][i].position;
                avatarParts[i].transform.localRotation = snapshots[index][i].rotation;
            }
            index++;
        }
        else
        {
            index = 0;
            isReplaying = false;
            GetComponent<Avatar>().useCalibrationData = true;
            Time.timeScale = 1.0f;

            if (restartSceneAfterReplay)
                {
                    SceneManager.LoadScene(SceneManager.GetActiveScene().buildIndex);
                    return;
                }

            RestoreInitialPose();
        }
        Debug.Log("Replaying");
    }

    public void StartReplay()
    {
        if (recorded)
        {
            isReplaying = true;
            isRecording = false;
            recorded = false;

            GetComponent<Avatar>().useCalibrationData = false;

            foreach (Animator anim in GetComponentsInChildren<Animator>())
            {
                anim.enabled = false;
            }

            foreach (Rigidbody rb in GetComponentsInChildren<Rigidbody>())
            {
                rb.isKinematic = true;
            }

            CharacterController cc = GetComponent<CharacterController>();
            if (cc != null) cc.enabled = false;
            Time.timeScale = 0.7f;
        }
        else
        {
            messageText.text = "Clip not recorded!";
            Invoke("ClearMessage", 2);
        }
    }

    private void RestoreInitialPose()
    {
        // Restore root (global) transform
        avatarParts[0].transform.position = initialPose[0].position;
        avatarParts[0].transform.rotation = initialPose[0].rotation;

        // Restore all parts in world space
        for (int i = 1; i < avatarParts.Length; i++)
        {
            avatarParts[i].transform.position = initialPose[i].position;
            avatarParts[i].transform.rotation = initialPose[i].rotation;
        }

        // Re-enable components turned off during replay
        foreach (Animator anim in GetComponentsInChildren<Animator>())
        {
            anim.enabled = true;
        }
        foreach (Rigidbody rb in GetComponentsInChildren<Rigidbody>())
        {
            rb.isKinematic = false;
        }
        CharacterController cc = GetComponent<CharacterController>();
        if (cc != null) cc.enabled = true;
    }

    public void ClearMessage()
    {
        messageText.text = "";
    }

    private void UpdateUI()
    {
        if(isReplaying)
        {
            updateText.text = "Replaying Clip!";
        }
        else if(isRecording)
        {
            updateText.text = "Recording Clip!";
        }
        else if(recorded)
        {
            updateText.text = "Clip Recorded!";
        }
    }

    struct PlayerTransform
    {
        public Vector3 position;
        public Quaternion rotation;
    }
}
