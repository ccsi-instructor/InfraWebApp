#!/bin/bash
set -euo pipefail

SCRIPT=$(readlink -f -- "${BASH_SOURCE[0]}")
if (( EUID != 0 )); then
    exec sudo /bin/bash "$SCRIPT" "$@"
fi
SOURCE_DIR=$(dirname -- "$SCRIPT")
umask 022

# 展開元には依存せず、固定の導入先だけを処理する
# /app とWindows共有のファイルは保持する。専用Pythonは削除する。
cd /
SERVICE=/etc/systemd/system/file-uploader.service
MOUNT=/etc/systemd/system/mnt-uploader.mount
STATE=/etc/file-uploader/firewall.state
PORT=
ZONE=
if [[ -f "$STATE" ]]; then
    read -r ZONE PORT < "$STATE"
elif [[ -f "$SERVICE" ]]; then
    PORT=$(sed -nE \
        's/^ExecStart=.*--bind 0\.0\.0\.0:([0-9]+)([[:space:]].*)?$/\1/p' "$SERVICE")
fi

# 停止・アンマウントが失敗したら、削除処理へ進まない
if [[ -f "$SERVICE" ]]; then
    systemctl disable --now file-uploader.service
fi
if [[ -f "$MOUNT" ]]; then
    systemctl stop mnt-uploader.mount
elif grep -q ' /mnt/uploader ' /proc/self/mounts; then
    umount /mnt/uploader
fi
if [[ -d /mnt/uploader ]]; then
    rmdir /mnt/uploader
fi

# firewalld停止中はオフラインの永続設定だけを操作する
if [[ -n "$PORT" ]]; then
    if systemctl is-active --quiet firewalld; then
        if [[ -z "$ZONE" ]]; then
            ZONE=$(firewall-cmd --get-default-zone)
        fi
        firewall-cmd --zone="$ZONE" --remove-port="${PORT}/tcp"
        firewall-cmd --permanent --zone="$ZONE" --remove-port="${PORT}/tcp"
    else
        OPTIONS=()
        if [[ -n "$ZONE" ]]; then
            OPTIONS+=("--zone=$ZONE")
        fi
        firewall-offline-cmd "${OPTIONS[@]}" --remove-port="${PORT}/tcp"
    fi
fi
rm -f -- "$STATE"

# 登録済みの、このアプリ用SELinux定義だけを削除する
if command -v semanage > /dev/null && selinuxenabled; then
    LOCAL_CONTEXTS=$(semanage fcontext -l -C)
    for PATTERN in '/opt/python3\.14/bin(/.*)?' '/opt/file-uploader/\.venv/bin(/.*)?'; do
        if grep -F "$PATTERN" <<< "$LOCAL_CONTEXTS" > /dev/null; then
            semanage fcontext -d "$PATTERN"
        fi
    done
fi

rm -rf --one-file-system -- /opt/file-uploader /opt/python3.14 /opt/src/Python-3.14.8
rm -f -- /opt/src/Python-3.14.8.tar.xz
rm -f -- /etc/file-uploader/credentials
if [[ -d /etc/file-uploader ]]; then
    rmdir /etc/file-uploader
fi

# 設定原本は残し、ユーザー削除後はrootだけに読める状態にする
if [[ -d /app/config ]]; then
    chown root:root /app/config
    chmod 0700 /app/config
fi
if [[ -f /app/config/config.ini ]]; then
    chown root:root /app/config/config.ini
    chmod 0600 /app/config/config.ini
fi
if id -u file-uploader > /dev/null 2>&1; then
    userdel file-uploader
fi
if getent group file-uploader > /dev/null; then
    groupdel file-uploader
fi
rm -f -- "$SERVICE" "$MOUNT"
rm -f -- /etc/systemd/system/file-uploader.service.d/10-bind-port.conf
systemctl daemon-reload
printf '%s\n' 'アンインストールが完了しました。/app とWindows共有内のファイルは残しています。'
