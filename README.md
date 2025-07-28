


### . Install Required Packages

Ensure you're using **Python 3.8+**, then install dependencies:

```bash
pip install opencv-python mediapipe pillow
```

If you're missing `tkinter` (which is built-in on most systems), you can install That as well

---


## 🎮 Controls

- **🎦 Start with Camera** – Start real-time tracking using webcam.  
- **📁 Select Video File** – Load and track from a video file.  
- **🛑 Stop Tracking** – Stop the current tracking session.  
- **❌ Exit** – Exit the application.  

---

## 📸 Screenshot


![UI Screenshot](https://github.com/BurningYolo/419i10712zahzi201/raw/main/UI.png)


---

## 🕹️ Unity Setup Instructions

To visualize the tracking data inside Unity:

1. **Download [Unity Hub](https://unity.com/download)**.
2. Add the `UnityMediaPipeAvatar` folder to Unity Hub.
3. Install the Unity Editor version **2021.3.24f1 (LTS)**.
4. Open the project and locate the **Calibration Scene**:
   - Navigate to: `Assets/Scenes/Calibration_Scene.unity`
5. **To run everything**:
   - First, launch the Python script (`main.py`) to start the tracking pipeline.
   - Then, open and run the Unity **Calibration Scene**.

