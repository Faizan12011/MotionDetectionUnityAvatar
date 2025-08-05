// File: PipeServer.cs
// Purpose: Core bridge between external MediaPipe/Firebase data streams and Unity.
// Receives landmark frames (named pipes, UDP or Firebase), creates/updates virtual
// transforms, smooths data, drives avatar movement, and provides session browser UI.

// REVIEWS
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Threading;
using Firebase.Database;
using Firebase.Extensions;
using Firebase.Firestore;
using UnityEngine.UI;
using UnityEngine.SceneManagement;
using UnityEngine;

/* Currently very messy because both the server code and hand-drawn code is all in the same file here.
 * But it is still fairly straightforward to use as a reference/base.
 * 
 *  Receives tracking data (UDP/Named Pipes) from an external source (Python/MediaPipe).

    Updates 3D landmarks (joint positions) in Unity.

    Computes virtual transforms (neck, hips) not provided by MediaPipe.

    Moves the character based on hip_z_delta (forward/backward motion).

    Visualizes landmarks & skeleton (using LineRenderer).
 */

[DefaultExecutionOrder(-1)]
public class PipeServer : MonoBehaviour
{
    public bool useFirebase = true; // Use Firebase instead of legacy pipes/UDP
    public bool useLegacyPipes = false; // True to use NamedPipes for interprocess communication (not supported on Linux)
    public string host = "192.168.18.2"; // This machines host.
    public int port = 52733; // Must match the Python side.
    public Transform bodyParent;
    public GameObject landmarkPrefab;
    public GameObject linePrefab;
    public GameObject headPrefab;
    public bool enableHead = false;
    public float multiplier = 10f;
    public float landmarkScale = 1f;
    public float maxSpeed = 50f;
    public float debug_samplespersecond;

    // --------------- Firestore Session Browser ---------------
    [Header("Session Browser UI")]
    public Dropdown sessionDropdown;
    public Text sessionInfoText;
    public Button playButton;
    public Button deleteButton;
    public Text totalGbText;

    private FirebaseFirestore fs;
    private List<SessionInfo> sessions = new List<SessionInfo>();

    private class SessionInfo
    {
        public string id;
        public string name;
        public DateTime created;
        public long sizeBytes;
        public int fps;
    }
    [Tooltip("How many frames to average per landmark before applying. Lower = more responsive, higher = smoother.")]
    public int samplesForPose = 1;
    public bool active;

    private NamedPipeServerStream serverNP;
    private BinaryReader reader;
    private ServerUDP server;

    private Body body;

    // these virtual transforms are not actually provided by mediapipe pose, but are required for avatars.
    // so I just manually compute them
    private Transform virtualNeck;
    private Transform virtualHip;

    public Transform characterTransform;

    private float smoothedDz = 0f;
    public float smoothFactor = 0.1f; // adjust to control smoothness

    float dz = 0f;
    bool dzUpdated = false;
    Quaternion prevRotation;
    [SerializeField] float characterSpeed = 300f;

    public float smoothingFactor = 5f;
    private int notAvailableCount = 1000;
    [HideInInspector] public bool dataReceiving = false;

    // How long (in seconds) without a new frame before we consider that data
    // is no longer being received. RecordAndReplay relies on this flag to
    // start / stop recording clips.
    [Tooltip("Seconds after last frame before dataReceiving becomes false.")] 
    public float receivingTimeout = 2f;

    private int framesProcessed = 0;

    public Transform GetLandmark(Landmark mark)
    {
        return body.instances[(int)mark].transform ;
    }
    public Transform GetVirtualNeck()
    {
        return virtualNeck;
    }
    public Transform GetVirtualHip()
    {
        return virtualHip;
    }

    private void Start()
    {
        // Initialise watchdog so that timeout check only starts after the first frame
        lastFrameTime = Time.time;
        System.Globalization.CultureInfo.DefaultThreadCurrentCulture = System.Globalization.CultureInfo.InvariantCulture;

        body = new Body(bodyParent,landmarkPrefab,linePrefab,landmarkScale,enableHead?headPrefab:null);
        virtualNeck = new GameObject("VirtualNeck").transform;
        virtualHip = new GameObject("VirtualHip").transform;

        prevRotation = characterTransform.rotation;

        // ---- Firestore session browser setup ----
        fs = FirebaseFirestore.DefaultInstance;
        // If UI elements not assigned in Inspector, build a minimal canvas automatically so the feature is always visible in play mode
        if (sessionDropdown == null)
        {
            CreateRuntimeSessionBrowserUI();
        }
        if (sessionDropdown != null)
        {
            playButton.onClick.AddListener(OnPlayClicked);
            deleteButton.onClick.AddListener(OnDeleteClicked);
            LoadSessions();
        }

        if (useFirebase)
        {
            SetupFirebaseListener();
        }
        else
        {
            Thread t = new Thread(new ThreadStart(Run));
            t.Start();
        }

    }
    private void Update()
    {
        Debug.Log($"PipeServer Update called at {Time.time}");
        // Update recording watchdog based on last frame arrival time
        if (Time.time - lastFrameTime > receivingTimeout)
            dataReceiving = false; // No recent frames – stop recording
        else
            dataReceiving = true; // Frames flowing – allow recording
        UpdateBody(body);
        Quaternion currentRotation = characterTransform.rotation;

        if (prevRotation != currentRotation)
        {
            prevRotation = currentRotation;
            //dz = Input.GetAxis("Vertical"); // W/S keys control dz directly

            smoothedDz = Mathf.Lerp(smoothedDz, dz, smoothFactor);

            // Inverted displacement direction (move opposite to forward)
            Vector3 movement = -characterTransform.forward * Mathf.Abs(smoothedDz) * characterSpeed * Time.deltaTime;

            characterTransform.position += movement;

            //aDebug.Log("Movement: " + movement);
            dzUpdated = false;
            notAvailableCount = 0;
        }
        else
        {
            notAvailableCount++;
        }

        // if(notAvailableCount > 100)
        // {
        //     Debug.Log("Video Not Available");
        //     dataReceiving = false;
        // }
        // else
        // {
        //     Debug.Log("Video Available");
        //     dataReceiving = true;
        // }
        framesProcessed++;
    }

    private void resetDZ()
    {
        if (!dzUpdated)
            dz = 0;
    }

    private void UpdateBody(Body b)
    {
        for (int i = 0; i < LANDMARK_COUNT; ++i)
        {
            if (b.positionsBuffer[i].accumulatedValuesCount < samplesForPose)
                continue;
            
            b.localPositionTargets[i] = b.positionsBuffer[i].value / (float)b.positionsBuffer[i].accumulatedValuesCount * multiplier;
            b.positionsBuffer[i] = new AccumulatedBuffer(Vector3.zero,0);
        }

        Vector3 offset = Vector3.zero;
        for (int i = 0; i < LANDMARK_COUNT; ++i)
        {
            Vector3 p = b.localPositionTargets[i]-offset;
            /*b.instances[i].transform.localPosition=Vector3.MoveTowards(b.instances[i].transform.localPosition, p, Time.deltaTime * maxSpeed);*/

            b.instances[i].transform.localPosition = Vector3.Lerp(b.instances[i].transform.localPosition, p, Time.deltaTime * smoothingFactor); // try 5�10

        }

        virtualNeck.transform.position = (b.instances[(int)Landmark.RIGHT_SHOULDER].transform.position + b.instances[(int)Landmark.LEFT_SHOULDER].transform.position) / 2f;
        virtualHip.transform.position = (b.instances[(int)Landmark.RIGHT_HIP].transform.position + b.instances[(int)Landmark.LEFT_HIP].transform.position) / 2f;

        b.UpdateLines();
    }
    public void SetVisible(bool visible)
    {
        bodyParent.gameObject.SetActive(visible);
    }

    #region Firebase
    private DatabaseReference framesRef;
    private Firebase.Database.Query framesQuery;
    private int framesReceived = 0;
    private float lastLogTime = 0f;
    private float prevMidHipZ = 0f;
    private bool firstFrame = true;
    private bool skipInitialFrame = true;
    private void SetupFirebaseListener()
    {
        framesRef = FirebaseDatabase.DefaultInstance.GetReference("sessions/live/frames");
        // Attach listener – start at the newest frame then stay live
        framesQuery = framesRef.OrderByChild("ts").LimitToLast(1);
        framesQuery.ChildAdded += HandleChildAdded;
        skipInitialFrame = true;
        Debug.Log("Firebase listener attached to sessions/live/frames");
    }

    private void HandleChildAdded(object sender, ChildChangedEventArgs args)
    {
        if (args.DatabaseError != null)
        {
            Debug.LogError("Firebase error: " + args.DatabaseError.Message);
            return;
        }

        if (!args.Snapshot.Exists) return;
        // Skip the very first frame we get after attaching the listener – this is usually the
        // last frame from the previous session and would otherwise cause the avatar to snap
        // out of the default T-pose when resetting the scene.
        if (skipInitialFrame)
        {
            skipInitialFrame = false;
            return;
        }
        var kpObj = args.Snapshot.Child("kp").Value as System.Collections.IEnumerable;

        

        framesReceived++;
        dataReceiving = true; // signal that we are actively receiving frames
        lastFrameTime = Time.time;
            List<float> kp = new List<float>();
        foreach (var v in kpObj)
        {
            float val;
            if (float.TryParse(v.ToString(), out val)) kp.Add(val);
        }
        if (kp.Count < 99)
        {
            Debug.LogWarning($"Frame with insufficient values received: {kp.Count}");
            return;
        }

        Body h = body;
        for (int i = 0; i < LANDMARK_COUNT; i++)
        {
            int baseIdx = i * 3;
            float x = kp[baseIdx];
            float y = kp[baseIdx + 1];
            float z = kp[baseIdx + 2];
            h.positionsBuffer[i].value += new Vector3(x, y, z);
            h.positionsBuffer[i].accumulatedValuesCount += 1;
            h.active = true;
        }

        // debug: log first 3 landmarks
        Debug.Log($"Frame sample - LM0: {kp[0]:F3},{kp[1]:F3},{kp[2]:F3}  LM1: {kp[3]:F3},{kp[4]:F3},{kp[5]:F3}");

        // compute hip z delta for forward/back motion, prefer explicit value from Firebase if provided
        // Try to get provided hipDelta (scaled) from Firebase
        float hipDeltaFB = 0f;
        var hipDeltaSnap = args.Snapshot.Child("hipDelta");
        bool hasHipDelta = hipDeltaSnap != null && hipDeltaSnap.Exists && float.TryParse(hipDeltaSnap.Value.ToString(), out hipDeltaFB);

        if (hasHipDelta)
        {
            dz = hipDeltaFB;
            dzUpdated = true;
        }
        else
        {
            // Fallback: compute from z-coordinates (legacy path)
            float leftHipZ = kp[23 * 3 + 2];
            float rightHipZ = kp[24 * 3 + 2];
            float midZ = (leftHipZ + rightHipZ) / 2f;
            if (!firstFrame)
            {
                dz = (midZ - prevMidHipZ) * 150f; // scale similar to Python sender
                float deadZone = 0.05f;
                if (Mathf.Abs(dz) < deadZone) dz = 0;
                else dzUpdated = true;
            }
            prevMidHipZ = midZ;
            firstFrame = false;
        }

        // FPS monitoring
        if (Time.time - lastLogTime >= 1f)
        {
            debug_samplespersecond = framesReceived / (Time.time - lastLogTime);
            framesReceived = 0;
            lastLogTime = Time.time;
            Debug.Log($"Firebase FPS: {debug_samplespersecond:F1}");
        }
    }
    #endregion

    private float lastFrameTime = 0f; // watchdog


    private void Run()
    {
        System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.InvariantCulture;

        if (useLegacyPipes)
        {
            // Open the named pipe.
            serverNP = new NamedPipeServerStream("UnityMediaPipeBody1", PipeDirection.InOut, 99, PipeTransmissionMode.Message);

            print("Waiting for connection...");
            serverNP.WaitForConnection();

            print("Connected.");
            reader = new BinaryReader(serverNP, Encoding.UTF8);
        }
        else
        {
            server = new ServerUDP(host, port);
            server.Connect();
            server.StartListeningAsync();
            print("Listening @"+host+":"+port);
        }

        while (true)
        {
            try
            {
                Body h = body;
                var len = 0;
                var str = "";

                if (useLegacyPipes)
                {
                    len = (int)reader.ReadUInt32();
                    str = new string(reader.ReadChars(len));
                    //Debug.Log("Received message1: " + str);  // Log the message to check what is received
                }
                else
                {
                    if (server.HasMessage())
                    {
                        str = server.GetMessage();
                        //Debug.Log("Received message2: " + str);  // Log the message to check what is received
                    }
                    len = str.Length;
                }

                string[] lines = str.Split('\n');
                foreach (string l in lines)
                {
                    if (string.IsNullOrWhiteSpace(l))
                        continue;

                    if (l.StartsWith("hip_z_delta"))
                    {
                        //Debug.Log("Received hip_z_delta: " + l);
                        string[] parts = l.Split('|');
                        if (float.TryParse(parts[1], out float deltaZ))
                        {
                            if (characterTransform != null)
                            {
                                //Debug.Log("DeltaZ: " + deltaZ);
                                dz = deltaZ;
                                float deadZone = 0.002f;
                                if (Mathf.Abs(dz) < deadZone)
                                    dz = 0;
                                else
                                    dzUpdated = true;
                                //dz = Mathf.Abs(dz);
                                //Debug.Log($"Received deltaZ: {deltaZ}"); // Existing
                                //Debug.Log($"Current dz: {dz}"); // Add this
                            }
                            else
                            {
                                //Debug.LogWarning("characterTransform is null");
                            }
                        }
                    }

                    string[] s = l.Split('|');
                    if (s.Length < 4) continue;
                    int i;
                    if (!int.TryParse(s[0], out i)) continue;
                    h.positionsBuffer[i].value += new Vector3(float.Parse(s[1]), float.Parse(s[2]), float.Parse(s[3]));
                    h.positionsBuffer[i].accumulatedValuesCount += 1;
                    h.active = true;
                }
            }
            catch (EndOfStreamException)
            {
                print("Client Disconnected");
                break;
            }
        }

    }

    private void OnDisable()
    {
        if (framesRef != null)
        {
            if (framesQuery != null)
            {
                framesQuery.ChildAdded -= HandleChildAdded;
            }
        }
        if (!useFirebase)
        {
            if (useLegacyPipes)
            {
                if (serverNP != null)
                {
                    serverNP.Close();
                    serverNP.Dispose();
                }
            }
            else
            {
                server?.Disconnect();
            }
        }
    }

    // ---------------- Firestore Session Browser Logic ----------------
    #region Runtime UI creation for Firestore session browser
    private void CreateRuntimeSessionBrowserUI()
    {
        // Ensure there is a Canvas & EventSystem in scene
        Canvas canvas = FindObjectOfType<Canvas>();
        if (canvas == null)
        {
            GameObject canvasGO = new GameObject("SessionBrowserCanvas");
            canvas = canvasGO.AddComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            canvasGO.AddComponent<CanvasScaler>();
            canvasGO.AddComponent<GraphicRaycaster>();
        }
        if (FindObjectOfType<UnityEngine.EventSystems.EventSystem>() == null)
        {
            new GameObject("EventSystem", typeof(UnityEngine.EventSystems.EventSystem), typeof(UnityEngine.EventSystems.StandaloneInputModule));
        }

        // Toggle button (ellipsis) anchored top-right
        Button toggleBtn = CreateButton(canvas.transform, "⋮", () => panelVisible = !panelVisible);
        RectTransform toggleRt = toggleBtn.GetComponent<RectTransform>();
        toggleRt.anchorMin = new Vector2(1, 1);  // Changed to right side
        toggleRt.anchorMax = new Vector2(1, 1);  // Changed to right side
        toggleRt.pivot = new Vector2(1, 1);      // Changed pivot to top-right
        toggleRt.anchoredPosition = new Vector2(-20f, -100f);  // Added 20px margin from left
        toggleRt.sizeDelta = new Vector2(80f, 80f);
        // Larger symbol for visibility on phone
        toggleBtn.GetComponentInChildren<Text>().fontSize = 28;

        // Vertical layout group container
        GameObject panelGO = new GameObject("SessionBrowserPanel");
        panelGO.transform.SetParent(canvas.transform, false);
        RectTransform panelRt = panelGO.AddComponent<RectTransform>();
    panelRt.anchorMin = new Vector2(1, 1);    // Anchored to top-right
    panelRt.anchorMax = new Vector2(1, 1);    // Anchored to top-right
    panelRt.pivot = new Vector2(1, 1);        // Pivot at top-right

    panelRt.anchoredPosition = new Vector2(-20f, -250f);  // 20px from left, 80px from top
    panelRt.sizeDelta = new Vector2(380f, 340f);
        var vlg = panelGO.AddComponent<UnityEngine.UI.VerticalLayoutGroup>();
        vlg.childControlHeight = true;
        vlg.childControlWidth = true;
        vlg.spacing = 8f;

        // Dropdown
        GameObject ddGO = CreateDropdown(panelGO.transform, out Dropdown dd);
        sessionDropdown = dd;

        // Info text
        sessionInfoText = CreateText(panelGO.transform, "InfoText", "Size / FPS");
        totalGbText = CreateText(panelGO.transform, "TotalText", "Total: 0 MB");

        // Horizontal buttons container
        GameObject buttonsGO = new GameObject("Buttons");
        buttonsGO.transform.SetParent(panelGO.transform, false);
        var hlg = buttonsGO.AddComponent<UnityEngine.UI.HorizontalLayoutGroup>();
        hlg.childControlWidth = true;
        hlg.spacing = 4f;

        playButton = CreateButton(buttonsGO.transform, "Play", OnPlayClicked);
        deleteButton = CreateButton(buttonsGO.transform, "Del", OnDeleteClicked);

        // Wire dropdown change listener
        sessionDropdown.onValueChanged.AddListener(_ => UpdateSessionInfoText());
    }

    private GameObject CreateDropdown(Transform parent, out Dropdown dropdown)
    {
        GameObject go = new GameObject("Dropdown", typeof(RectTransform), typeof(Dropdown));
        go.transform.SetParent(parent, false);
        
        // Configure dropdown background
        Image img = go.AddComponent<Image>();
        img.color = new Color(0.15f, 0.15f, 0.15f, 0.95f); // Dark semi-transparent background
        img.sprite = Resources.GetBuiltinResource<Sprite>("UI/Skin/UISprite.psd");
        img.type = Image.Type.Sliced;
        
        // Add rounded corners effect
        go.AddComponent<UnityEngine.UI.Mask>();
        
        dropdown = go.GetComponent<Dropdown>();
        dropdown.targetGraphic = img;

        // Label - with improved styling
        Text label = CreateText(go.transform, "Label", "Select session");
        label.fontSize = 20;
        label.color = new Color(0.9f, 0.9f, 0.9f, 1f); // Light text
        label.alignment = TextAnchor.MiddleCenter;
        dropdown.captionText = label;

        // Arrow indicator
        GameObject arrow = new GameObject("Arrow", typeof(RectTransform), typeof(Image));
        arrow.transform.SetParent(go.transform, false);
        Image arrowImg = arrow.GetComponent<Image>();
        arrowImg.sprite = Resources.GetBuiltinResource<Sprite>("UI/Skin/DropdownArrow.psd");
        arrowImg.color = new Color(0.8f, 0.8f, 0.8f);
        
        RectTransform arrowRt = arrow.GetComponent<RectTransform>();
        arrowRt.anchorMin = new Vector2(1, 0.5f);
        arrowRt.anchorMax = new Vector2(1, 0.5f);
        arrowRt.pivot = new Vector2(1, 0.5f);
        arrowRt.anchoredPosition = new Vector2(-15, 0);
        arrowRt.sizeDelta = new Vector2(20, 20);

        // Template - scrollable container
        GameObject templateGO = new GameObject("Template", typeof(RectTransform), typeof(Image), typeof(ScrollRect));
        dropdown.template = templateGO.GetComponent<RectTransform>();
        templateGO.SetActive(false);
        templateGO.transform.SetParent(go.transform, false);
        
        // Template background
        Image templateImg = templateGO.GetComponent<Image>();
        templateImg.color = new Color(0.15f, 0.15f, 0.15f, 0.95f); // Dark semi-transparent
        templateImg.sprite = Resources.GetBuiltinResource<Sprite>("UI/Skin/UISprite.psd");
        templateImg.type = Image.Type.Sliced;
        
        // Add shadow effect
        Shadow shadow = templateGO.AddComponent<Shadow>();
        shadow.effectColor = new Color(0, 0, 0, 0.5f);
        shadow.effectDistance = new Vector2(4, -4);

        // ScrollRect configuration
        ScrollRect sr = templateGO.GetComponent<ScrollRect>();
        sr.horizontal = false;
        sr.vertical = true;
        sr.movementType = ScrollRect.MovementType.Clamped;
        sr.scrollSensitivity = 25f;
        sr.decelerationRate = 0.135f;

        // Viewport - clipping mask
        GameObject viewportGO = new GameObject("Viewport", typeof(RectTransform), typeof(Mask), typeof(Image));
        viewportGO.transform.SetParent(templateGO.transform, false);
        sr.viewport = viewportGO.GetComponent<RectTransform>();
        
        // Viewport styling
        Image viewportImg = viewportGO.GetComponent<Image>();
        viewportImg.color = new Color(0.15f, 0.15f, 0.15f, 0.95f); // Match background
        viewportImg.type = Image.Type.Sliced;
        viewportGO.GetComponent<Mask>().showMaskGraphic = true;

        // Content container - holds all items
        GameObject contentGO = new GameObject("Content", typeof(RectTransform), typeof(VerticalLayoutGroup), typeof(ContentSizeFitter));
        contentGO.transform.SetParent(viewportGO.transform, false);
        sr.content = contentGO.GetComponent<RectTransform>();
        
        // Content layout configuration
        VerticalLayoutGroup vlg = contentGO.GetComponent<VerticalLayoutGroup>();
        vlg.childControlHeight = true;
        vlg.childControlWidth = true;
        vlg.childForceExpandHeight = false;
        vlg.childForceExpandWidth = true;
        vlg.spacing = 2f;
        vlg.padding = new RectOffset(4, 4, 4, 4);
        
        ContentSizeFitter csf = contentGO.GetComponent<ContentSizeFitter>();
        csf.verticalFit = ContentSizeFitter.FitMode.PreferredSize;
        csf.horizontalFit = ContentSizeFitter.FitMode.Unconstrained;

        // Item template - with visual enhancements
        GameObject itemGO = new GameObject("Item", typeof(RectTransform), typeof(Toggle));
        itemGO.transform.SetParent(contentGO.transform, false);
        
        Toggle itemToggle = itemGO.GetComponent<Toggle>();
        Image toggleBg = itemGO.AddComponent<Image>();
        itemToggle.targetGraphic = toggleBg;
        toggleBg.color = new Color(0.2f, 0.2f, 0.2f, 1f); // Default item color
        
        // Visual states
        ColorBlock cb = itemToggle.colors;
        cb.normalColor = new Color(0.2f, 0.2f, 0.2f, 1f);
        cb.highlightedColor = new Color(0.35f, 0.35f, 0.4f, 1f);
        cb.pressedColor = new Color(0.25f, 0.25f, 0.3f, 1f);
        cb.selectedColor = new Color(0.3f, 0.3f, 0.35f, 1f);
        cb.disabledColor = new Color(0.15f, 0.15f, 0.15f, 0.5f);
        itemToggle.colors = cb;
        
        // Ensure row height
        LayoutElement le = itemGO.AddComponent<LayoutElement>();
        le.preferredHeight = 40f;
        le.minHeight = 36f;

        // Item label
        Text itemLabel = CreateText(itemGO.transform, "ItemLabel", "Option");
        itemLabel.fontSize = 18;
        itemLabel.color = new Color(0.9f, 0.9f, 0.9f, 1f);
        itemLabel.alignment = TextAnchor.MiddleLeft;
        
        RectTransform itemLabelRt = itemLabel.rectTransform;
        itemLabelRt.anchorMin = Vector2.zero;
        itemLabelRt.anchorMax = Vector2.one;
        itemLabelRt.offsetMin = new Vector2(15, 2);
        itemLabelRt.offsetMax = new Vector2(-15, -2);

        // Assign to dropdown
        dropdown.itemText = itemLabel;

        // Set template sizes
        RectTransform templateRt = templateGO.GetComponent<RectTransform>();
        templateRt.anchorMin = new Vector2(0, 0);
        templateRt.anchorMax = new Vector2(1, 0);
        templateRt.pivot = new Vector2(0.5f, 1f);
        templateRt.sizeDelta = new Vector2(0, 300); // Increased height for phones
        
        RectTransform viewportRt = viewportGO.GetComponent<RectTransform>();
        viewportRt.anchorMin = Vector2.zero;
        viewportRt.anchorMax = Vector2.one;
        viewportRt.offsetMin = Vector2.zero;
        viewportRt.offsetMax = Vector2.zero;
        
        RectTransform contentRt = contentGO.GetComponent<RectTransform>();
        contentRt.anchorMin = new Vector2(0, 1);
        contentRt.anchorMax = new Vector2(1, 1);
        contentRt.pivot = new Vector2(0.5f, 1f);
        contentRt.sizeDelta = new Vector2(0, 0);

        return go;
    }

    private Text CreateText(Transform parent, string name, string initial)
    {
        GameObject go = new GameObject(name, typeof(RectTransform), typeof(Text));
        go.transform.SetParent(parent, false);
        Text tx = go.GetComponent<Text>();
        tx.text = initial;
        tx.font = Resources.GetBuiltinResource<Font>("Arial.ttf");
        tx.color = new Color(0.9f, 0.9f, 0.9f); // Light text color
        tx.fontSize = 14;
        return tx;
    }

    private Button CreateButton(Transform parent, string label, UnityEngine.Events.UnityAction onClick)
    {
        GameObject go = new GameObject(label + "Button", typeof(RectTransform), typeof(Image), typeof(Button));
        go.transform.SetParent(parent, false);
        Image img = go.GetComponent<Image>();
        img.color = new Color(0.25f, 0.25f, 0.3f); // Dark blue-gray
        img.sprite = Resources.GetBuiltinResource<Sprite>("UI/Skin/UISprite.psd");
        img.type = Image.Type.Sliced;
        
        // Add shadow for depth
        Shadow shadow = go.AddComponent<Shadow>();
        shadow.effectColor = new Color(0, 0, 0, 0.3f);
        shadow.effectDistance = new Vector2(2, -2);
        
        Button btn = go.GetComponent<Button>();
        btn.targetGraphic = img;
        
        // Button colors
        ColorBlock cb = btn.colors;
        cb.normalColor = new Color(0.25f, 0.25f, 0.3f);
        cb.highlightedColor = new Color(0.35f, 0.35f, 0.4f);
        cb.pressedColor = new Color(0.2f, 0.2f, 0.25f);
        cb.selectedColor = new Color(0.3f, 0.3f, 0.35f);
        cb.disabledColor = new Color(0.15f, 0.15f, 0.15f, 0.5f);
        btn.colors = cb;
        
        btn.onClick.AddListener(onClick);
        
        // Button text
        Text txt = CreateText(go.transform, "Text", label);
        txt.fontSize = 18;
        txt.fontStyle = FontStyle.Bold;
        txt.color = new Color(0.95f, 0.95f, 0.95f); // Nearly white
        txt.alignment = TextAnchor.MiddleCenter;
        RectTransform rt = txt.rectTransform;
        rt.anchorMin = Vector2.zero;
        rt.anchorMax = Vector2.one;
        rt.offsetMin = rt.offsetMax = Vector2.zero;
        
        return btn;
    }
#endregion

    private async void LoadSessions()
    {
        sessions.Clear();
        if (fs == null) return;
        QuerySnapshot snap = await fs.Collection("pose_sessions").OrderByDescending("createdAt").GetSnapshotAsync();
        long totalBytes = 0;
        foreach (DocumentSnapshot doc in snap.Documents)
        {
            var dict = doc.ToDictionary();
            string name = dict.ContainsKey("name") ? dict["name"].ToString() : doc.Id;
            DateTime created = dict.ContainsKey("createdAt") && dict["createdAt"] is Timestamp ts ? ts.ToDateTime() : DateTime.Now;
            long bytes = dict.ContainsKey("bytes") ? Convert.ToInt64(dict["bytes"]) : 0;
            int fps = dict.ContainsKey("fps") ? Convert.ToInt32(dict["fps"]) : 30;
            sessions.Add(new SessionInfo { id = doc.Id, name = name, created = created, sizeBytes = bytes, fps = fps });
            totalBytes += bytes;
        }
        PopulateDropdown();
        if (totalGbText)
        {
            float mb = totalBytes / (1024f * 1024f);
            totalGbText.text = $"Total: {mb:F1} MB";
        }
    }

    private void PopulateDropdown()
    {
        if (sessionDropdown == null) return;
        sessionDropdown.ClearOptions();
        List<string> options = new List<string>();
        foreach (var s in sessions)
        {
            options.Add($"{s.name} ({s.created:yyyy-MM-dd HH:mm})");
        }
        if (options.Count == 0)
        {
            options.Add("(list is empty)");
            playButton.interactable = deleteButton.interactable = false;
        }
        else
        {
            playButton.interactable = deleteButton.interactable = true;
        }
        sessionDropdown.AddOptions(options);
        sessionDropdown.value = 0;
        UpdateSessionInfoText();
    }

    private bool panelVisible = true;
    private void LateUpdate()
    {
        if (sessionDropdown != null && sessionDropdown.transform.parent != null)
        {
            sessionDropdown.transform.parent.gameObject.SetActive(panelVisible);
        }
    }

    private void UpdateSessionInfoText()
    {
        if (sessionInfoText == null || sessions.Count == 0) return;
        int idx = sessionDropdown.value;
        if (idx < 0 || idx >= sessions.Count) return;
        var s = sessions[idx];
        float mb = s.sizeBytes / (1024f * 1024f);
        sessionInfoText.text = $"Size: {mb:F1} MB  FPS: {s.fps}";
    }

    private void OnPlayClicked()
    {
        int idx = sessionDropdown.value;
        if (idx < 0 || idx >= sessions.Count) return;
        StopAllCoroutines();
        StartCoroutine(PlaySessionCoroutine(sessions[idx]));
    }

    private void OnDeleteClicked()
    {
        int idx = sessionDropdown.value;
        if (idx < 0 || idx >= sessions.Count) return;
        var s = sessions[idx];
        fs.Collection("pose_sessions").Document(s.id).DeleteAsync();
        // Deleting subcollection frames in Firestore requires each doc deletion – trigger with cloud function ideally.
        // Here we just refresh list.
        LoadSessions();
    }

    private IEnumerator PlaySessionCoroutine(SessionInfo session)
    {
        Debug.Log($"Starting playback of {session.name}");
        CollectionReference framesCol = fs.Collection("pose_sessions").Document(session.id).Collection("frames");
        var task = framesCol.OrderBy("ts").GetSnapshotAsync();
        while (!task.IsCompleted)
            yield return null;
        if (task.IsFaulted)
        {
            Debug.LogError("Failed to fetch frames: " + task.Exception);
            yield break;
        }
        QuerySnapshot framesSnap = task.Result;
        foreach (DocumentSnapshot frameDoc in framesSnap.Documents)
        {
            if (!frameDoc.TryGetValue("data", out string encoded)) continue;
            if (string.IsNullOrEmpty(encoded)) continue;
            if (!DecodeFrame(encoded, out List<float> kp, out float hip)) continue;
                        ApplyFrame(kp, hip);
            float delay = 1f / session.fps;
            if (session.fps == 30) delay *= 5.0f; // slow 30-fps clips slightly
            yield return new WaitForSeconds(delay);
        }
        Debug.Log("Playback finished");
    }

    private bool DecodeFrame(string encoded, out List<float> kp, out float hip)
    {
        kp = new List<float>();
        hip = 0f;
        try
        {
            byte[] compressed = Convert.FromBase64String(encoded);
            using (var ms = new MemoryStream(compressed))
            using (var gz = new GZipStream(ms, CompressionMode.Decompress))
            using (var sr = new StreamReader(gz))
            {
                string json = sr.ReadToEnd();
                FramePayload payload = JsonUtility.FromJson<FramePayload>(json);
                kp = payload.kp;
                hip = payload.hip;
            }
            return kp != null && kp.Count >= 99;
        }
        catch (Exception e)
        {
            Debug.LogError("Failed to decode frame: " + e);
            return false;
        }
    }

    [Serializable]
    private class FramePayload
    {
        public List<float> kp;
        public float hip;
    }

    private void ApplyFrame(List<float> kp, float hipDelta)
    {
        if (kp == null || kp.Count < 99) return;
        framesReceived++;
        dataReceiving = true;
        lastFrameTime = Time.time;
        Body h = body;
        for (int i = 0; i < LANDMARK_COUNT; i++)
        {
            int baseIdx = i * 3;
            float x = kp[baseIdx];
            float y = kp[baseIdx + 1];
            float z = kp[baseIdx + 2];
            h.positionsBuffer[i].value += new Vector3(x, y, z);
            h.positionsBuffer[i].accumulatedValuesCount += 1;
            h.active = true;
        }
        dz = hipDelta;
        dzUpdated = true;
    }

// ---------------- Scene Reset ----------------
    /// <summary>
    /// Reload the currently active Unity scene. Attach this method to a UI Button's OnClick.
    /// A fallback IMGUI button is also rendered via OnGUI for quick testing.
    /// </summary>
    public void ResetScene()
    {
        SceneManager.LoadScene(SceneManager.GetActiveScene().buildIndex);
    }

    // Simple IMGUI button drawn in the game view (top-left) as a convenience.
    private void OnGUI()
    {
        const int w = 160;
        const int h = 80;
        if (GUI.Button(new Rect(20, 100, w, h), "Reset Scene"))
        {
            ResetScene();
        }
    }

    // If using Firebase, UDP/pipe code below may be skipped but kept for reference.
    const int LANDMARK_COUNT = 33;
    const int LINES_COUNT = 11;

    public struct AccumulatedBuffer
    {
        public Vector3 value;
        public int accumulatedValuesCount;
        public AccumulatedBuffer(Vector3 v, int ac)
        {
            value = v;
            accumulatedValuesCount = ac;
        }
    }

    public class Body
    {
        public Transform parent;
        public AccumulatedBuffer[] positionsBuffer = new AccumulatedBuffer[LANDMARK_COUNT];
        public Vector3[] localPositionTargets = new Vector3[LANDMARK_COUNT];
        public GameObject[] instances = new GameObject[LANDMARK_COUNT];
        public LineRenderer[] lines = new LineRenderer[LINES_COUNT];

        public bool active;

        public Body(Transform parent, GameObject landmarkPrefab, GameObject linePrefab, float s, GameObject headPrefab)
        {
            this.parent = parent;
            for (int i = 0; i < instances.Length; ++i)
            {
                instances[i] = Instantiate(landmarkPrefab);// GameObject.CreatePrimitive(PrimitiveType.Sphere);
                instances[i].transform.localScale = Vector3.one * s;
                instances[i].transform.parent = parent;
                instances[i].name = ((Landmark)i).ToString();
            }
            for (int i = 0; i < lines.Length; ++i)
            {
                lines[i] = Instantiate(linePrefab).GetComponent<LineRenderer>();
                lines[i].transform.parent = parent;
            }

            if (headPrefab)
            {
                GameObject head = Instantiate(headPrefab);
                head.transform.parent = instances[(int)Landmark.NOSE].transform;
                head.transform.localPosition = headPrefab.transform.position;
                head.transform.localRotation = headPrefab.transform.localRotation;
                head.transform.localScale = headPrefab.transform.localScale;
            }
        }
        public void UpdateLines()
        {
            lines[0].positionCount = 4;
            lines[0].SetPosition(0, Position((Landmark)32));
            lines[0].SetPosition(1, Position((Landmark)30));
            lines[0].SetPosition(2, Position((Landmark)28));
            lines[0].SetPosition(3, Position((Landmark)32));
            lines[1].positionCount = 4;
            lines[1].SetPosition(0, Position((Landmark)31));
            lines[1].SetPosition(1, Position((Landmark)29));
            lines[1].SetPosition(2, Position((Landmark)27));
            lines[1].SetPosition(3, Position((Landmark)31));

            lines[2].positionCount = 3;
            lines[2].SetPosition(0, Position((Landmark)28));
            lines[2].SetPosition(1, Position((Landmark)26));
            lines[2].SetPosition(2, Position((Landmark)24));
            lines[3].positionCount = 3;
            lines[3].SetPosition(0, Position((Landmark)27));
            lines[3].SetPosition(1, Position((Landmark)25));
            lines[3].SetPosition(2, Position((Landmark)23));

            lines[4].positionCount = 5;
            lines[4].SetPosition(0, Position((Landmark)24));
            lines[4].SetPosition(1, Position((Landmark)23));
            lines[4].SetPosition(2, Position((Landmark)11));
            lines[4].SetPosition(3, Position((Landmark)12));
            lines[4].SetPosition(4, Position((Landmark)24));

            lines[5].positionCount = 4;
            lines[5].SetPosition(0, Position((Landmark)12));
            lines[5].SetPosition(1, Position((Landmark)14));
            lines[5].SetPosition(2, Position((Landmark)16));
            lines[5].SetPosition(3, Position((Landmark)22));
            lines[6].positionCount = 4;
            lines[6].SetPosition(0, Position((Landmark)11));
            lines[6].SetPosition(1, Position((Landmark)13));
            lines[6].SetPosition(2, Position((Landmark)15));
            lines[6].SetPosition(3, Position((Landmark)21));

            lines[7].positionCount = 4;
            lines[7].SetPosition(0, Position((Landmark)16));
            lines[7].SetPosition(1, Position((Landmark)18));
            lines[7].SetPosition(2, Position((Landmark)20));
            lines[7].SetPosition(3, Position((Landmark)16));
            lines[8].positionCount = 4;
            lines[8].SetPosition(0, Position((Landmark)15));
            lines[8].SetPosition(1, Position((Landmark)17));
            lines[8].SetPosition(2, Position((Landmark)19));
            lines[8].SetPosition(3, Position((Landmark)15));

            lines[9].positionCount = 2;
            lines[9].SetPosition(0, Position((Landmark)10));
            lines[9].SetPosition(1, Position((Landmark)9));


            lines[10].positionCount = 5;
            lines[10].SetPosition(0, Position((Landmark)8));
            lines[10].SetPosition(1, Position((Landmark)5));
            lines[10].SetPosition(2, Position((Landmark)0));
            lines[10].SetPosition(3, Position((Landmark)2));
            lines[10].SetPosition(4, Position((Landmark)7));
        }

        public Vector3 Direction(Landmark from,Landmark to)
        {
            return (instances[(int)to].transform.position - instances[(int)from].transform.position).normalized;
        }
        public float Distance(Landmark from, Landmark to)
        {
            return (instances[(int)from].transform.position - instances[(int)to].transform.position).magnitude;
        }
        public Vector3 LocalPosition(Landmark Mark)
        {
            return instances[(int)Mark].transform.localPosition;
        }
        public Vector3 Position(Landmark Mark)
        {
            return instances[(int)Mark].transform.position;
        }

    }
}