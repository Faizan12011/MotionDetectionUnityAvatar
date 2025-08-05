"""TEST.py
Quick sanity check script that opens the default webcam using OpenCV and
shows a live feed until the user presses 'q'. Useful for verifying camera
connectivity independently of the main app.
"""

import cv2

cap = cv2.VideoCapture(0)
if not cap.isOpened():
    print("❌ Failed to open webcam")
    exit()

while True:
    ret, frame = cap.read()
    if not ret:
        print("❌ Failed to grab frame")
        break
    cv2.imshow("Webcam", frame)
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()