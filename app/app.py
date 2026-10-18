import os
import re
from configparser import ConfigParser
from pathlib import Path, PureWindowsPath
from subprocess import DEVNULL, TimeoutExpired, run

from flask import Flask, abort, redirect, render_template, request, url_for

app = Flask(__name__, template_folder="template")
UPLOAD_DIR = Path("/mnt/uploader")
SMB_CREDENTIALS = Path("/etc/file-uploader/credentials")
config = ConfigParser(interpolation=None)
with open("/app/config/config.ini", encoding="utf-8") as file:
    config.read_file(file)
SHARE = config["storage"]["share"]
WARNING = "ファイルサーバーに接続できないため、アップロードされたファイルを保存できません"


def smb_available():
    # 設定した共有がCIFSとしてマウントされていることを、ローカルの一覧で確認
    mounts = (
        line.split()
        for line in Path("/proc/self/mounts").read_text().splitlines()
    )
    if not any(
        fields[1:3] == [str(UPLOAD_DIR), "cifs"]
        and re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), fields[0]) == SHARE
        for fields in mounts
    ):
        return False

    # マウント情報が残っているだけの切断も、実際のSMB接続で判定
    try:
        return run(
            [
                "/usr/bin/smbclient", SHARE,
                "-A", str(SMB_CREDENTIALS),
                "-p", "445", "-t", "3",
                "--use-kerberos=off",
                "--client-protection=encrypt",
                "--option=client min protocol=SMB3_11",
                "-c", "quit",
            ],
            stdin=DEVNULL, stdout=DEVNULL, stderr=DEVNULL, timeout=5,
        ).returncode == 0
    except (OSError, TimeoutExpired):
        return False


@app.route("/", methods=["GET", "POST"])
def index():
    connected = smb_available()
    if request.method == "POST":
        if not connected:
            abort(500, description=WARNING)
        file = request.files["file"]
        with (UPLOAD_DIR / PureWindowsPath(file.filename).name).open("wb") as target:
            file.save(target)
            target.flush()
            os.fsync(target.fileno())
        return redirect(url_for("index"), code=303)
    return render_template("index.html", connected=connected, warning=WARNING)
