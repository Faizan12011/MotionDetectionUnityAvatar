import tkinter as tk
from tkinter import filedialog, scrolledtext
import threading
import sys
import cv2
import time
import mediapipe as mp
from clientUDP import ClientUDP
import global_vars
import struct

class ConsoleRedirect:
    def __init__(self, widget):
        self.widget = widget

    def write(self, message):
        self.widget.insert(tk.END, message)
        self.widget.see(tk.END)

    def flush(self):
        pass

class CaptureThread(threading.Thread):
    def __init__(self):
        super().__init__()
        self.cap = None
        self.ret = None
        self.frame = None
        self.isRunning = False
        self.counter = 0
        self.timer = 0.0
        self.video_fps = 0.0

    def run(self):
        if global_vars.USE_VIDEO_FILE:
            print("[CaptureThread] Attempting to open video file...")
            self.cap = cv2.VideoCapture(global_vars.VIDEO_PATH)
            self.video_fps = self.cap.get(cv2.CAP_PROP_FPS)
            print(f"[CaptureThread] Video FPS detected: {self.video_fps}")
        else:
            print("[CaptureThread] Attempting to open camera...")
            self.cap = cv2.VideoCapture(global_vars.CAM_INDEX)
            if global_vars.USE_CUSTOM_CAM_SETTINGS:
                self.cap.set(cv2.CAP_PROP_FPS, global_vars.FPS)
                self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, global_vars.WIDTH)
                self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, global_vars.HEIGHT)

        if not self.cap.isOpened():
            print("[CaptureThread] ❌ Failed to open capture source.")
            global_vars.KILL_THREADS = True
            return

        print("✅ [CaptureThread] Capture opened successfully")
        self.timer = time.time()

        while not global_vars.KILL_THREADS:
            self.ret, self.frame = self.cap.read()
            if not self.ret:
                print("[CaptureThread] 🔁 End of video or error reading frame.")
                global_vars.KILL_THREADS = True
                break

            if global_vars.USE_VIDEO_FILE and self.video_fps > 0:
                time.sleep(1.0 / self.video_fps)

            self.isRunning = True

            if global_vars.DEBUG:
                self.counter += 1
                if time.time() - self.timer >= 3:
                    print("📸 Capture FPS: ", self.counter / (time.time() - self.timer))
                    self.counter = 0
                    self.timer = time.time()

class BodyThread(threading.Thread):
    def __init__(self):
        super().__init__()
        self.data = ""
        self.pipe = None
        self.timeSinceCheckedConnection = 0
        self.timeSincePostStatistics = 0

        #added part
        self.prev_mid_hip_z = None
        self.walking_speed = 2.0  # You can tweak this for sensitivity


    def run(self):
        mp_drawing = mp.solutions.drawing_utils
        mp_pose = mp.solutions.pose

        self.setup_comms()
        capture = CaptureThread()
        capture.start()

        with mp_pose.Pose(min_detection_confidence=0.80, min_tracking_confidence=0.5,
                          model_complexity=global_vars.MODEL_COMPLEXITY,
                          static_image_mode=False, enable_segmentation=True) as pose:
            while not global_vars.KILL_THREADS and not capture.isRunning:
                print("Waiting for camera and capture thread...")
                time.sleep(0.5)

            print("Beginning capture")

            while not global_vars.KILL_THREADS and capture.cap.isOpened():
                ti = time.time()
                image = capture.frame

                if image is None:
                    break

                image = cv2.flip(image, 1)
                image.flags.writeable = global_vars.DEBUG

                results = pose.process(image)
                tf = time.time()

                if global_vars.DEBUG:
                    if time.time() - self.timeSincePostStatistics >= 1:
                        print("Theoretical Maximum FPS: %f" % (1 / (tf - ti)))
                        self.timeSincePostStatistics = time.time()

                    if results.pose_landmarks:
                        mp_drawing.draw_landmarks(image, results.pose_landmarks, mp_pose.POSE_CONNECTIONS,
                                                  mp_drawing.DrawingSpec(color=(255, 100, 0), thickness=2, circle_radius=4),
                                                  mp_drawing.DrawingSpec(color=(255, 255, 255), thickness=2, circle_radius=2),
                                                  )
                    cv2.imshow('Body Tracking', image)
                    if cv2.waitKey(3) & 0xFF == ord('q'):
                        global_vars.KILL_THREADS = True
                        break

                self.data = ""
                if results.pose_world_landmarks:
                    print("[LOG] Sending the following landmarks:")
                    for i, landmark in enumerate(results.pose_world_landmarks.landmark):
                        print(f"  Landmark {i}: x={landmark.x}, y={landmark.y}, z={landmark.z}")
                        self.data += f"{i}|{landmark.x}|{landmark.y}|{landmark.z}\n"
                    
                    # Replace the hip distance calculation with z-coordinate tracking
                    left_hip = results.pose_world_landmarks.landmark[mp_pose.PoseLandmark.LEFT_HIP]
                    right_hip = results.pose_world_landmarks.landmark[mp_pose.PoseLandmark.RIGHT_HIP]

                    # Calculate the midpoint's z-coordinate
                    mid_hip_z = (left_hip.z + right_hip.z) / 2

                    if self.prev_mid_hip_z is not None:
                        # Use the change in z-coordinate for forward movement
                        # Change this line in BodyThread.run():
                        delta_z = (mid_hip_z - self.prev_mid_hip_z) * 1000  # Flipped sign  # Negative because MediaPipe's z increases as you move away
                        self.data += f"hip_z_delta|{delta_z}\n"

                    self.prev_mid_hip_z = mid_hip_z
                    


                print("[LOG] Data string being sent to server:")
            print(self.data)
            self.send_data(self.data)

        capture.cap.release()
        cv2.destroyAllWindows()

    def setup_comms(self):
        if not global_vars.USE_LEGACY_PIPES:
            self.client = ClientUDP(global_vars.HOST, global_vars.PORT)
            self.client.start()
        else:
            print("Using Pipes for interprocess communication (not supported on OSX or Linux).")

    def send_data(self, message):
        if not global_vars.USE_LEGACY_PIPES:
            self.client.sendMessage(message)
        else:
            if self.pipe is None and time.time() - self.timeSinceCheckedConnection >= 1:
                try:
                    self.pipe = open(r'\\.\pipe\UnityMediaPipeBody1', 'r+b', 0)
                except FileNotFoundError:
                    print("Waiting for Unity project to run...")
                    self.pipe = None
                self.timeSinceCheckedConnection = time.time()

            if self.pipe is not None:
                try:
                    s = message.encode('utf-8')
                    self.pipe.write(struct.pack('I', len(s)) + s)
                    self.pipe.seek(0)
                except Exception:
                    print("Failed to write to pipe. Is the Unity project open?")
                    self.pipe = None

# ==== UI ====
root = tk.Tk()
root.title("🎥 MediaPipe Body Tracking")
root.geometry("900x700")
root.configure(bg="#1e1e1e")

thread_ref = None

def start_tracking():
    global thread_ref
    if thread_ref and thread_ref.is_alive():
        print("Tracking already running...")
        return

    try:
        global_vars.FPS = int(fps_entry.get())
        global_vars.WIDTH = int(width_entry.get())
        global_vars.HEIGHT = int(height_entry.get())
        global_vars.USE_CUSTOM_CAM_SETTINGS = True
    except ValueError:
        print("⚠️ Invalid FPS or resolution input. Using defaults.")
        global_vars.USE_CUSTOM_CAM_SETTINGS = False

    global_vars.KILL_THREADS = False
    thread_ref = BodyThread()
    thread_ref.start()

def stop_tracking():
    global_vars.KILL_THREADS = True
    print("🛑 Stopping tracking...")

def browse_file():
    path = filedialog.askopenfilename(filetypes=[("Video Files", "*.mp4 *.avi *.mov")])
    if path:
        global_vars.VIDEO_PATH = path
        global_vars.USE_VIDEO_FILE = True
        start_tracking()

def use_camera():
    global_vars.USE_VIDEO_FILE = False
    start_tracking()

def exit_program():
    stop_tracking()
    root.quit()
    root.destroy()

# ==== UI Layout ====
control_frame = tk.Frame(root, bg="#1e1e1e")
control_frame.pack(pady=10)

style = {
    "font": ("Consolas", 12),
    "bg": "#2e2e2e",
    "fg": "#00ff00",
    "activebackground": "#444",
    "activeforeground": "#00ff00",
    "relief": tk.RAISED,
    "width": 25,
    "bd": 2,
    "highlightthickness": 0,
    "cursor": "hand2",
    "padx": 5,
    "pady": 5
}

tk.Button(control_frame, text="🎦 Start with Camera", command=use_camera, **style).grid(row=0, column=0, padx=10)
tk.Button(control_frame, text="📁 Select Video File", command=browse_file, **style).grid(row=0, column=1, padx=10)
tk.Button(control_frame, text="🛑 Stop Tracking", command=stop_tracking, **style).grid(row=0, column=2, padx=10)
tk.Button(control_frame, text="❌ Exit", command=exit_program, **style).grid(row=0, column=3, padx=10)

settings_frame = tk.Frame(root, bg="#1e1e1e")
settings_frame.pack(pady=5)

tk.Label(settings_frame, text="FPS:", fg="#00ff00", bg="#1e1e1e", font=("Consolas", 11)).grid(row=0, column=0, sticky="e")
fps_entry = tk.Entry(settings_frame, width=5)
fps_entry.insert(0, "30")
fps_entry.grid(row=0, column=1)

tk.Label(settings_frame, text="Width:", fg="#00ff00", bg="#1e1e1e", font=("Consolas", 11)).grid(row=0, column=2, sticky="e")
width_entry = tk.Entry(settings_frame, width=5)
width_entry.insert(0, "640")
width_entry.grid(row=0, column=3)

tk.Label(settings_frame, text="Height:", fg="#00ff00", bg="#1e1e1e", font=("Consolas", 11)).grid(row=0, column=4, sticky="e")
height_entry = tk.Entry(settings_frame, width=5)
height_entry.insert(0, "480")
height_entry.grid(row=0, column=5)

tk.Label(root, text="📜 Log Console", font=("Consolas", 12), fg="#00ff00", bg="#1e1e1e").pack(pady=(10, 0))

log_text = scrolledtext.ScrolledText(root, wrap=tk.WORD, height=25, bg="#000000", fg="#00ff00",
                                     font=("Consolas", 10), insertbackground="#00ff00", borderwidth=2)
log_text.pack(fill=tk.BOTH, expand=True, padx=20, pady=10)

# Redirect console output
sys.stdout = ConsoleRedirect(log_text)
sys.stderr = ConsoleRedirect(log_text)

root.mainloop()
