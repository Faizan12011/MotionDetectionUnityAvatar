import socket
import time
import threading

class ClientUDP(threading.Thread):
    def __init__(self, ip, port, autoReconnect=True):
        threading.Thread.__init__(self)
        self.ip = ip
        self.port = port
        self.autoReconnect = autoReconnect
        self.connected = False
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    def run(self):
        self.connect()

    def isConnected(self):
        return self.connected

    def sendMessage(self, message):
        try:
            message = str('%s<EOM>' % message).encode('utf-8')
            self.socket.sendto(message, (self.ip, self.port))
        except Exception as ex:
            print(f"Error sending message: {ex}")
            self.disconnect()

    def disconnect(self):
        self.connected = False
        self.socket.close()
        if self.autoReconnect:
            time.sleep(1)
            self.connect()

    def connect(self):
        try:
            print(f"Attempting to send to {self.ip}:{self.port}")
            self.connected = True
        except Exception as ex:
            print(f"Connection error: {ex}")
            self.disconnect()