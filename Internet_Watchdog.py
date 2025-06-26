import os
import time
import subprocess
import requests
import logging
from datetime import datetime, timedelta

# === Paths and Config ===
LOG_DIR = r"C:\temp\Outputs\watchdog"
LOG_FILE = os.path.join(LOG_DIR, "watchdog.log")
REBOOT_LOG_PATH = r"C:\ProgramData\LastInternetReboot.txt"
OFFLINE_FLAG_PATH = r"C:\ProgramData\InternetOfflineAcknowledged.txt"
DISCORD_WEBHOOK = "https://discord.com/api/webhooks/YOUR_WEBHOOK_HERE"
CHECK_INTERVAL = 60  # seconds
REBOOT_COOLDOWN = timedelta(hours=1)
POST_REBOOT_DELAY = timedelta(minutes=5)

# === Logging Setup ===
os.makedirs(LOG_DIR, exist_ok=True)
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

# === Helper Functions ===
def is_internet_up():
    result = subprocess.run(["ping", "-n", "2", "8.8.8.8"], stdout=subprocess.DEVNULL)
    return result.returncode == 0

def send_discord_notice():
    try:
        requests.post(DISCORD_WEBHOOK, json={"content": ":construction: Notice: Plex server temporarily unavailable :construction:"})
        logging.info("Sent Discord alert about offline status.")
    except Exception as e:
        logging.error(f"Failed to send Discord message: {e}")

def read_timestamp(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            return datetime.fromisoformat(f.read().strip())
    except:
        return None

def write_timestamp(path):
    with open(path, "w") as f:
        f.write(datetime.now().isoformat())

def clear_flag(path):
    if os.path.exists(path):
        os.remove(path)

# === Main Loop ===
def watchdog_loop():
    while True:
        if is_internet_up():
            clear_flag(OFFLINE_FLAG_PATH)
            logging.info("Internet is up.")
            time.sleep(CHECK_INTERVAL)
            continue

        now = datetime.now()
        last_reboot = read_timestamp(REBOOT_LOG_PATH)

        if last_reboot is None or (now - last_reboot) >= REBOOT_COOLDOWN:
            logging.info("No internet and reboot cooldown expired. Rebooting...")
            write_timestamp(REBOOT_LOG_PATH)
            clear_flag(OFFLINE_FLAG_PATH)
            subprocess.run(["shutdown", "/r", "/t", "0"])
            return  # Exit to allow reboot

        elif (now - last_reboot) >= POST_REBOOT_DELAY:
            if not os.path.exists(OFFLINE_FLAG_PATH):
                send_discord_notice()
                with open(OFFLINE_FLAG_PATH, "w") as f:
                    f.write("1")

        else:
            logging.info("Waiting for post-reboot delay or cooldown...")

        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    watchdog_loop()
