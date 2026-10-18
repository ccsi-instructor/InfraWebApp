#!/bin/bash
set -euo pipefail

SCRIPT=$(readlink -f -- "${BASH_SOURCE[0]}")
if (( EUID != 0 )); then
    exec sudo /bin/bash "$SCRIPT" "$@"
fi
SOURCE_DIR=$(dirname -- "$SCRIPT")
umask 022

# 展開場所から /app に配置し、配置後のスクリプトで続行する
if [[ "$SOURCE_DIR" != "$(readlink -m /app)" ]]; then
    if [[ -f /etc/systemd/system/file-uploader.service ]]; then
        systemctl stop file-uploader.service
    fi
    install -d -m 0755 /app /app/template
    install -m 0644 "$SOURCE_DIR/app.py" "$SOURCE_DIR/Readme.md" /app/
    install -m 0644 "$SOURCE_DIR/template/index.html" /app/template/
    install -m 0755 "$SOURCE_DIR/install.sh" "$SOURCE_DIR/update.sh" \
        "$SOURCE_DIR/uninstall.sh" /app/
    if [[ ! -d /app/config ]]; then
        install -d -m 0700 /app/config
    fi
    if [[ ! -f /app/config/config.ini ]]; then
        CONFIG="$SOURCE_DIR/config/config.ini"
        if [[ ! -f "$CONFIG" ]]; then
            CONFIG="$SOURCE_DIR/config/config.ini.example"
        fi
        install -m 0600 "$CONFIG" /app/config/config.ini
    fi
    install -m 0644 "$SOURCE_DIR/config/config.ini.example" /app/config/
    exec /bin/bash /app/install.sh "$@"
fi
cd /app
if [[ ! -f /app/config/config.ini ]]; then
    install -m 0600 /app/config/config.ini.example /app/config/config.ini
fi
if [[ -f /etc/systemd/system/file-uploader.service ]]; then
    systemctl stop file-uploader.service
fi

# OS標準Pythonは置き換えない
dnf install -y dnf-plugins-core
dnf config-manager --set-enabled crb
dnf install -y gcc make wget tar xz pkgconf-pkg-config \
    openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel \
    readline-devel sqlite-devel libuuid-devel libzstd-devel \
    cifs-utils samba-client firewalld policycoreutils-python-utils

# 専用Pythonがある場合は再ビルドしない
PYTHON_VERSION=3.14.8
mkdir -p /opt/src /opt/file-uploader
if [[ ! -x /opt/python3.14/bin/python3.14 ]]; then
    cd /opt/src
    wget -O "Python-${PYTHON_VERSION}.tar.xz" \
        "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
    tar -xf "Python-${PYTHON_VERSION}.tar.xz"
    cd "Python-${PYTHON_VERSION}"
    ./configure --prefix=/opt/python3.14 --with-ensurepip=install
    make -j"$(nproc)"
    make altinstall
fi
/opt/python3.14/bin/python3.14 -m pip install pipenv
cd /opt/file-uploader
export PIPENV_VENV_IN_PROJECT=1
export PIPENV_IGNORE_VIRTUALENVS=1
/opt/python3.14/bin/pipenv --python /opt/python3.14/bin/python3.14 \
    install Flask 'gunicorn==26.2.0'

# 再実行時は既存の専用ユーザー・グループを利用する
if ! getent group file-uploader > /dev/null; then
    groupadd --system file-uploader
fi
if ! id -u file-uploader > /dev/null 2>&1; then
    useradd --system --gid file-uploader --no-create-home \
        --home-dir /nonexistent --shell /sbin/nologin file-uploader
fi

# マウント済みのWindows側ディレクトリにはchmodしない
if ! grep -q ' /mnt/uploader ' /proc/self/mounts; then
    install -d -o root -g root -m 0555 /mnt/uploader
fi
if selinuxenabled; then
    LOCAL_CONTEXTS=$(semanage fcontext -l -C)
    for PATTERN in '/opt/python3\.14/bin(/.*)?' '/opt/file-uploader/\.venv/bin(/.*)?'; do
        if grep -F "$PATTERN" <<< "$LOCAL_CONTEXTS" > /dev/null; then
            semanage fcontext -m -t bin_t "$PATTERN"
        else
            semanage fcontext -a -t bin_t "$PATTERN"
        fi
    done
    restorecon -RF /opt/python3.14/bin /opt/file-uploader/.venv/bin
fi

# サービス定義はupdate.shで一元生成する
exec /bin/bash /app/update.sh
