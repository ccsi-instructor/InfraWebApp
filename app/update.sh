#!/bin/bash
set -euo pipefail

SCRIPT=$(readlink -f -- "${BASH_SOURCE[0]}")
if (( EUID != 0 )); then
    exec sudo /bin/bash "$SCRIPT" "$@"
fi
SOURCE_DIR=$(dirname -- "$SCRIPT")
umask 022

# 同梱のプログラムを更新。明示的なconfig.iniがあれば、その設定を反映
if [[ "$SOURCE_DIR" != "$(readlink -m /app)" ]]; then
    if [[ -f /etc/systemd/system/file-uploader.service ]]; then
        systemctl stop file-uploader.service
    fi
    if [[ -f "$SOURCE_DIR/app.py" ]]; then
        install -d -m 0755 /app /app/template
        install -m 0644 "$SOURCE_DIR/app.py" "$SOURCE_DIR/Readme.md" /app/
        install -m 0644 "$SOURCE_DIR/template/index.html" /app/template/
        install -m 0755 "$SOURCE_DIR/install.sh" "$SOURCE_DIR/update.sh" \
            "$SOURCE_DIR/uninstall.sh" /app/
    else
        # update.shだけを別の場所に置いた場合は、設定反映用として配置
        install -m 0755 "$SCRIPT" /app/update.sh
    fi
    # 展開先に実設定がある場合だけ取り込む。設定例では上書きしない
    CONFIG="$SOURCE_DIR/config/config.ini"
    if [[ -f "$CONFIG" ]]; then
        if ! cmp -s -- "$CONFIG" /app/config/config.ini; then
            install -d -o root -g file-uploader -m 0750 /app/config
            if [[ -f /app/config/config.ini ]]; then
                install -o root -g root -m 0600 /app/config/config.ini \
                    /app/config/config.ini.bak
                printf '%s\n' '変更前の設定: /app/config/config.ini.bak'
            fi
            install -o root -g file-uploader -m 0640 "$CONFIG" /app/config/config.ini
        fi
        printf '設定取り込み元: %s\n' "$CONFIG"
    else
        printf '%s\n' '展開先にconfig.iniがないため、/app/config/config.iniを使用します。'
    fi
    exec /bin/bash /app/update.sh "$@"
fi
cd /app
if [[ -f /etc/systemd/system/file-uploader.service ]]; then
    systemctl stop file-uploader.service
fi
umask 077
install -d -o root -g file-uploader -m 0750 /app/config /etc/file-uploader
chown root:file-uploader /app/config/config.ini
chmod 0640 /app/config/config.ini

systemctl enable --now firewalld
/opt/python3.14/bin/python3.14 - <<'PY'
import re
from configparser import ConfigParser
from pathlib import Path
from subprocess import run

config = ConfigParser(interpolation=None)
with open("/app/config/config.ini", encoding="utf-8") as file:
    config.read_file(file)
storage = config["storage"]
port = config["server"]["port"]
service = Path("/etc/systemd/system/file-uploader.service")
state = Path("/etc/file-uploader/firewall.state")

# 新版は記録したゾーンを再利用。旧版はサービス定義から旧ポートを取得
old_port = None
if state.exists():
    zone, old_port = state.read_text(encoding="utf-8").split()
else:
    zone = run(["firewall-cmd", "--get-default-zone"], check=True,
               capture_output=True, text=True).stdout.strip()
    if service.exists():
        match = re.search(r"--bind 0\.0\.0\.0:([0-9]+)(?=\s|$)",
                          service.read_text(encoding="utf-8"))
        if match:
            old_port = match[1]

for options in ([], ["--permanent"]):
    if old_port and old_port != port:
        run(["firewall-cmd", *options, f"--zone={zone}",
             f"--remove-port={old_port}/tcp"], check=True)
    run(["firewall-cmd", *options, f"--zone={zone}",
         f"--add-port={port}/tcp"], check=True)
state.write_text(f"{zone} {port}\n", encoding="utf-8")
state.chmod(0o600)

credentials = Path("/etc/file-uploader/credentials")
credentials.write_text(
    f"username={storage['username']}\n"
    f"password={storage['password']}\n"
    f"domain={storage['domain']}\n", encoding="utf-8",
)
credentials.chmod(0o600)
share = storage["share"].replace("%", "%%")
mount = Path("/etc/systemd/system/mnt-uploader.mount")
mount.write_text(
    f"""[Unit]
Description=Windows upload share
Wants=network-online.target
After=network-online.target

[Mount]
What={share}
Where=/mnt/uploader
Type=cifs
Options=credentials=/etc/file-uploader/credentials,vers=3.1.1,sec=ntlmsspi,seal,iocharset=utf8,uid=file-uploader,gid=file-uploader,file_mode=0600,dir_mode=0700,nosuid,nodev,noexec
TimeoutSec=15s
""", encoding="utf-8",
)
mount.chmod(0o644)
service.write_text(
    f"""[Unit]
Description=File uploader
Wants=mnt-uploader.mount

[Service]
Type=notify
NotifyAccess=main
User=file-uploader
Group=file-uploader
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=/app
ExecStart=/opt/file-uploader/.venv/bin/python -m gunicorn --no-control-socket --preload --bind 0.0.0.0:{port} --workers 2 --threads 4 --timeout 0 --access-logfile - app:app
UMask=0077

[Install]
WantedBy=multi-user.target
""", encoding="utf-8",
)
service.chmod(0o644)
PY

chown root:file-uploader /etc/file-uploader/credentials
chmod 0640 /etc/file-uploader/credentials
if selinuxenabled; then
    restorecon -RF /app /etc/file-uploader
fi
systemctl daemon-reload
systemctl --no-block restart mnt-uploader.mount
systemctl enable --now file-uploader.service
read -r ZONE PORT < /etc/file-uploader/firewall.state
printf 'Webサービスを起動しました。設定ファイル: /app/config/config.ini / ポート: %s\n' "$PORT"
