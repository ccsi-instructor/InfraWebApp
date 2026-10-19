# ファイルアップローダー

ブラウザーから受け取ったファイルを、Windows Server 2025のSMB共有へ保存するWebアプリケーションです。

**配布フォルダーはどこに展開しても構いません。`install.sh`がソースを`/app`へ自動配置し、Python環境の構築・サービス登録・設定ポート（既定はHTTP 80番）での起動まで行います。**

```bash
bash /任意の展開先/app/install.sh
```

一般ユーザーから実行すると、スクリプト内で`sudo`を使って管理者権限で再実行します。sudo権限は必要です。パスワードを求められる場合があります。rootから実行する場合は、そのまま処理を続けます。

> **重要:** `install.sh`単体ではなく、同梱の`app.py`、`template`、設定例、各スクリプトを含む配布フォルダー一式を配置してください。作業ディレクトリへの移動、`/app`の手動作成・手動コピー、`chmod +x`は不要です。`bash スクリプトのパス`で実行します。

---

## 1. 基本構成

| 項目 | 内容 |
|---|---|
| OS | AlmaLinux 9 |
| Python | 初回構築はPython 3.14.8。`/opt/python3.14`に既存の実行ファイルがあれば再利用 |
| アプリケーション | Flask。処理は`app.py`、HTMLは`template/index.html` |
| 実行サーバー | Gunicorn 26.2.0（この版ではバージョンを固定） |
| 環境管理 | Pipenv。仮想環境は`/opt/file-uploader/.venv` |
| サービス管理 | systemd。サービス名は`file-uploader.service` |
| Web待受 | `config.ini`の`[server] port`。既定は`80`。`8080`などにも変更可能 |
| 保存先 | `config.ini`の`[storage] share`で指定するWindows共有 |
| Linux側マウント先 | `/mnt/uploader` |

```text
ブラウザー ── HTTP :80 ──> Gunicorn / Flask
                              │
                              └── /mnt/uploader ── SMB ──> Windows共有
```

Webは非rootの専用ユーザー`file-uploader`で実行します。80番で待ち受けるための権限はsystemdの`CAP_NET_BIND_SERVICE`で付与します。[1]

WebサービスはSMBマウントを`Wants`で要求しますが、そのマウントを必須の依存先にはしません。マウントへの`After`も指定しないため、SMB接続完了を待たずに起動します。[2]

## 2. 配布フォルダーと配置先

### 配布フォルダー

```text
任意の展開先/
└── app/
    ├── app.py
    ├── config/
    │   └── config.ini.example
    ├── template/
    │   └── index.html
    ├── install.sh
    ├── update.sh
    ├── uninstall.sh
    └── Readme.md
```

実運用の設定を持ち込む場合は、展開先の`config/config.ini`を追加して編集できます。ZIPには実運用のパスワードを含めていません。

### インストール後

```text
/app/                             ソースコードと設定原本
├── app.py
├── config/
│   ├── config.ini                実際に使用する設定
│   ├── config.ini.bak            外部設定で置換する直前の設定（生成時のみ）
│   └── config.ini.example        設定例
├── template/index.html
├── install.sh
├── update.sh
├── uninstall.sh
└── Readme.md

/opt/python3.14/                   アプリ専用Python・Pipenv
/opt/file-uploader/                Pipfile・Pipfile.lock
└── .venv/                        アプリの仮想環境
/opt/src/Python-3.14.8/             初回構築時のPythonソース
/etc/file-uploader/
├── credentials                   生成したSMB認証情報
└── firewall.state                許可したfirewalldゾーン・ポート
/etc/systemd/system/
├── file-uploader.service
└── mnt-uploader.mount
/mnt/uploader/                    Windows共有のマウント先
```

スクリプトは`readlink`で自身の実体の絶対パスを解決します。空白を含む展開先、別の作業ディレクトリからの呼び出し、スクリプトへのシンボリックリンクに対応します。[3]

## 3. インストール

### 前提条件

AlmaLinux 9上で、rootまたはsudoを使用できるユーザーとして実行します。OSのパッケージリポジトリ、Python配布サイト、PyPIへの接続が必要です。80番は他のプロセスが使用していない状態を前提とします。OS標準Pythonは置き換えません。

**`/app`、`/opt/file-uploader`、`/opt/python3.14`、実行ユーザー・グループ`file-uploader`は、このアプリ専用としてください。** 他のアプリと共用する環境は想定していません。

Windows側の共有作成・書き込み権限設定、クラウド側の受信ルールはインストーラーの対象外です。SMBが未接続でもWebの起動自体は可能です。

### 初回実行

たとえば配布フォルダーを`/home/student/uploader/app`に展開した場合は、次だけを実行します。

```bash
bash /home/student/uploader/app/install.sh
```

カレントディレクトリが`/tmp`など別の場所でも実行できます。sudoを明示する書き方も利用できます。

```bash
sudo bash /home/student/uploader/app/install.sh
```

インストーラーが自動的に行う処理は、ソースの`/app`への配置、設定原本の準備、必要パッケージの導入、専用Python・Pipenv環境の構築、実行ユーザーと権限の設定、サービス定義生成、ポート開放、自動起動登録、Webの起動です。サービス定義生成は`update.sh`にまとめ、インストーラーから内部実行します。

### install.shが使用するconfig.iniの優先順位

| 優先順位 | 使用する設定 |
|---|---|
| 1 | 既存の`/app/config/config.ini`。内容は上書きしません。 |
| 2 | 展開先の`config/config.ini`。`/app`に設定がない場合だけコピーします。 |
| 3 | 展開先の`config/config.ini.example`。設定が双方にない場合は設定原本としてコピーします。 |

**設定せずに実行しても、サンプルを使ってWebを80番で起動する構成です。ただし、実際のWindows共有へ保存するには実環境の共有先・認証情報が必要です。** サンプルの`CHANGE_ME`は実際のパスワードではありません。

インストール後に実際の値を設定する場合は次のようにします。

```bash
sudo vi /app/config/config.ini
bash /app/update.sh
```

既存設定のない初回導入を実環境の設定で起動する場合は、インストール前に展開先の`config/config.ini.example`を`config/config.ini`へコピーして編集し、その後`install.sh`を実行します。

### 再実行

既存の`/app/config/config.ini`、専用ユーザー・グループは再利用します。`/opt/python3.14/bin/python3.14`が存在し実行可能なら、Pythonの展開・ビルドを省略します。DNFとPipenvの依存関係導入は再実行します。実行前のWebサービスは停止するため、無停止更新ではありません。

これは「壊れたPython環境を自動修復する」処理でも「Pythonを最新の修正版へ上げる」処理でもありません。既存環境のバージョン検査や整合性診断は実装していません。

## 4. config.ini

```ini
[server]
port = 80

[storage]
share = //192.168.10.20/Upload
username = upload_user
password = CHANGE_ME
domain = FILESERVER
```

| 項目 | 意味 |
|---|---|
| `[server] port` | Webアプリの待受ポート。既定は`80`。`8080`などの指定も可能です。 |
| `[storage] share` | 保存先のWindows共有。`//サーバー/共有名`形式で指定します。 |
| `username` | 共有にアクセスするユーザー名。 |
| `password` | そのユーザーのパスワード。 |
| `domain` | Windowsローカルアカウントならサーバー名、ドメインアカウントならドメイン名。 |

たとえばWindows側が`\\192.168.10.20\Upload`なら、`share = //192.168.10.20/Upload`です。Windows内部の`D:\Upload`などの物理パスではなく、SMBの共有名を指定してください。

保存先のLinux側パスは固定の`/mnt/uploader`です。`config.ini`の共有をここへマウントすることで、アップロードされたファイルがWindows側へ保存されます。

設定はUTF-8、スクリプトはLF改行で保存してください。`[server]`などのセクションを重複させないでください。パスワードの`%`はそのまま記述できます。設定読み込みでは`ConfigParser(interpolation=None)`を使用しています。[4]

運用中の設定ディレクトリは`root:file-uploader`・`0750`、設定原本と生成した認証情報は`root:file-uploader`・`0640`にします。Webの実行ユーザーには読み取りのみを許可します。認証情報は平文です。

## 5. 設定変更・プログラム更新

**この版の`update.sh`は、スクリプト自身と同じ配布フォルダーの`config/config.ini`を、既存の`/app/config/config.ini`へ反映します。** カレントディレクトリではなく、実行したスクリプトの実体の場所を基準にします。`config.ini.example`では既存設定を上書きしません。

### 読み込む設定の決まり

| 操作 | 使用する設定 |
|---|---|
| `/app/update.sh`を実行 | `/app/config/config.ini` |
| 展開先の`update.sh`を実行し、同じフォルダー配下に`config/config.ini`がある | 展開先の設定を`/app/config/config.ini`へコピーして反映 |
| 展開先には`config.ini.example`しかない、または設定ファイルがない | 既存の`/app/config/config.ini`を維持して反映 |
| `install.sh`を再実行 | 既存設定を維持。設定を変更する場合は`update.sh`を使用 |

> **重要:** 展開先の`config.ini`はファイル全体を取り込みます。ポートだけではなく、共有先・ユーザー名・パスワード・ドメインも置き換わります。サンプルから作った`config.ini`を使用する場合は、`[storage]`も実環境の値にしてください。実設定を含む展開先を他者に共有しないでください。

### 展開先の設定を編集して反映する

すでに導入済みの環境で、配布フォルダー内から操作する例です。既存設定から作るため、共有先と認証情報を維持してポートだけを変更できます。

```bash
cd /home/student/uploader/app
sudo install -m 0600 /app/config/config.ini ./config/config.ini
sudo vi ./config/config.ini
sudo bash ./update.sh
```

`config.ini`が既に編集済みなら、コピーの行は実行せず、そのファイルを使用してください。8080番へ変更する場合は、次のようにします。

```ini
[server]
port = 8080
```

実行場所を移動する必要はありません。次のように絶対パスで呼び出しても、スクリプトの横の`config/config.ini`を使用します。

```bash
bash /home/student/uploader/app/update.sh
```

### /appの設定を直接編集して反映する

ポートだけの変更など、プログラムを差し替える必要がないときは次でも反映できます。

```bash
sudo vi /app/config/config.ini
bash /app/update.sh
```

別の場所のカレントディレクトリに`config.ini`があっても、`/app/update.sh`はそれを取り込みません。

### バックアップと表示

外部の設定で既存設定を置き換える直前に、`/app/config/config.ini.bak`へ直前の設定を1世代保存します。内容が同一の場合はコピーせず、バックアップも更新しません。バックアップはroot所有・`0600`です。`/app/config/config.ini`を直接編集した場合は、編集前のバックアップを自動作成しません。

取り込み元パスと適用ポートを表示するので、どの設定を使用したか確認できます。たとえば8080番へ変更した場合、完了メッセージは次の形式です。

```text
Webサービスを起動しました。設定ファイル: /app/config/config.ini / ポート: 8080
```

バックアップから戻す場合は、次を実行します。外部の`update.sh`ではなく、配置済みの`/app/update.sh`を使用してください。

```bash
sudo install -o root -g file-uploader -m 0640 /app/config/config.ini.bak /app/config/config.ini
bash /app/update.sh
```

### 新しい配布版へ更新する

新しい配布フォルダーを任意の場所へ展開し、その中の`update.sh`を実行します。

```bash
bash /home/student/new-uploader/app/update.sh
```

同じフォルダーに`app.py`があれば、アプリ、HTML、3つのスクリプト、Readmeを`/app`へコピーし、配置後の`/app/update.sh`で処理を続けます。**プログラムだけを更新して設定を保持するときは、展開先に実設定の`config/config.ini`を置かず、`config.ini.example`だけにします。** 古い展開先に実設定が残っている場合、その内容で上書きされる点に注意してください。

`update.sh`だけを別の場所に置いた場合は、スクリプトのみを`/app/update.sh`へ配置します。アプリ・HTMLは更新せず、同じ場所の`config/config.ini`があれば設定を取り込み、なければ既存設定を使います。

`update.sh`はWebを停止し、設定と認証情報の権限、SMBマウント定義、Webサービス定義、firewalldを更新して、Webを起動します。アップロード中には実行しないでください。Pythonの再ビルドや依存パッケージの導入は行いません。設定値の入力検査・通信の事前診断・自動ロールバックは行いません。

未導入のマシン、アンインストール後の再導入、Python依存パッケージの変更を含む更新には`install.sh`を使用します。

### ポートとfirewalld

既定の設定例は80番です。ポート設定を変更した場合は、前のポートの明示的な許可を削除し、新しいポートを許可します。実行時設定と永続設定の両方を変更し、firewalldのリロードは行いません。[5]

この版を最初に適用する際の既定ゾーンを`/etc/file-uploader/firewall.state`へ記録します。以後の更新・アンインストールでは、そのゾーンを使用します。通常このファイルを手編集する必要はありません。

旧版からの移行で状態ファイルがない場合は、既定ゾーンと旧サービス定義のポートを使用します。旧サービス定義がない、または過去の失敗でポート欄が空でも、新しい定義は`config.ini`から生成します。空ポートを手動補正する操作は不要です。

導入後に管理者がゾーンやルールを独自変更した場合は、その整合性を別途管理してください。既定ゾーン以外に接続インターフェースを割り当てている環境のルールや、クラウド側の受信制限は自動変更しません。ポート許可を別アプリと共用しない前提です。

## 6. SMBが利用できない場合

| 状態・操作 | アプリケーションの動作 |
|---|---|
| Windows共有に接続できない状態でサービスを起動 | Webを起動します。 |
| 未接続時にフォームを表示 | HTTP 200でフォームと警告を表示します。 |
| 未接続時にアップロードを実行 | 保存処理の前にHTTP 500を返します。 |
| SMB接続確認が成功し、保存にも成功 | 保存後、HTTP 303でフォームへ戻ります。 |

警告は、次の文言をフォームの横に表示します。

> ファイルサーバーに接続できないため、アップロードされたファイルを保存できません

狭い画面では警告が折り返されます。画面の読み込みと送信時に接続状態を確認します。表示を自動で定期更新する処理はありません。

接続確認には、マウント情報に加えて`smbclient`での認証付き接続を使います。マウントされているというだけでは接続可能と扱いません。保存時の未処理のI/O例外もFlask標準のHTTP 500になります。[6]

SMB接続確認コマンドのタイムアウトは5秒、マウントユニットのタイムアウトは15秒です。ファイル保存全体の時間制限ではなく、保存途中の通信断ではI/O待ちが続く場合があります。

### Windows側が復旧した後

初回マウントが失敗した場合の定期的な再マウントは行いません。共有復旧後は、アップロード中でないことを確認して次を実行し、ブラウザーを再読み込みします。

```bash
sudo systemctl restart mnt-uploader.mount
```

共有先や認証情報も変更した場合は、設定編集後に`update.sh`を実行します。

## 7. 起動確認とログ

```bash
sudo systemctl status file-uploader.service --no-pager -l
sudo ss -ltnp 'sport = :80'
curl -i --max-time 10 http://127.0.0.1/
```

上記は80番の例です。8080番へ変更した場合は、次で確認します。

```bash
sudo ss -ltnp 'sport = :8080'
curl -i --max-time 10 http://127.0.0.1:8080/
```

Webが`active (running)`、設定したポートが`LISTEN`、フォームへのアクセスがHTTP 200であることを確認します。SMB未接続の場合、マウントが`failed`でもWebが`active (running)`になることを許容します。

Web自身のログとマウントのログは分けて確認します。

```bash
sudo journalctl -b -u file-uploader.service -n 100 --no-pager
sudo journalctl -b -u mnt-uploader.mount -n 100 --no-pager
```

この版では`Type=notify`を使用し、Gunicornの準備完了通知を待ってから起動処理を終えます。また`--preload`でアプリ読み込みを先に行います。これはプロセスを生成しただけで成功に見える状態を減らすための設定であり、HTTP応答やWindowsへの保存成功を保証するものではありません。[7]

| 問題 | 確認する内容 |
|---|---|
| `/app`がない、`/app/update.sh`がない | 新版の`install.sh`と同梱ファイル一式を使用しているか。今回の版は自動配置します。 |
| `Permission denied`で80番を開けない | 最新の`update.sh`が生成したサービスに`CAP_NET_BIND_SERVICE`があるか。 |
| `Control server error`で`/nonexistent`を参照 | 実際の起動コマンドに`--no-control-socket`があるか。 |
| `243/CREDENTIALS` | 古い`LoadCredential`のサービス定義・独自の追加設定が残っていないか。今回の版は使用しません。 |
| SMB接続のエラー | Windows共有、TCP 445、認証情報、共有とNTFSの書き込み権限を確認する。 |
| 設定編集が反映されない | 新版の`update.sh`を使用したか。取り込み元と適用ポートの表示、`/app/config/config.ini`、実際の`ExecStart`を確認する。 |

過去の失敗ログが残っていても、現在同じ問題が起きているとは限りません。日時と現在の状態を区別してください。パスワードを含む`config.ini`や`credentials`の全文を、問い合わせ用ログとして公開しないでください。

## 8. アンインストール

インストール先でも、任意の場所に置いた`uninstall.sh`でも実行できます。アプリ本体の同梱は不要です。

```bash
bash /app/uninstall.sh
```

```bash
bash /home/student/uploader/app/uninstall.sh
```

**実行するとWebを停止し、専用Pythonも削除します。`/opt/python3.14`を他用途と共用している環境には使用しないでください。**

| 対象 | 処理 |
|---|---|
| Webサービス | 停止・自動起動解除・定義削除 |
| Windows共有マウント | 停止。マウント先は空ディレクトリのみ削除 |
| `/opt/file-uploader` | Pipenv環境ごと削除 |
| `/opt/python3.14` | 専用Pythonと配下のPipenvなどを削除 |
| `/opt/src/Python-3.14.8`と同版のアーカイブ | 削除 |
| `/etc/file-uploader`の生成認証情報・状態 | 削除 |
| Webポートの明示的な許可 | 記録されたゾーンから削除 |
| このアプリ用のSELinux定義2件 | 登録済みかつSELinuxが有効な場合に削除 |
| `file-uploader`ユーザー・グループ | 存在する場合に削除 |
| 以前の`10-bind-port.conf` | 該当ファイルだけ削除 |
| **`/app`全体・設定原本・設定バックアップ** | **保持。設定原本はrootのみが読める状態へ変更。バックアップも平文認証情報を含む** |
| **Windows共有内のファイル** | **保持** |

削除済みのユーザー、サービス定義、ディレクトリなどは存在に応じて処理します。アンマウントや通常の削除コマンドが失敗した場合は、そこで停止します。Windows共有がマウントされ得る`/mnt/uploader`に`rm -rf`は使用しません。`rmdir`は空ディレクトリだけを削除します。[3]

firewalldが停止している場合は、`firewall-offline-cmd`で永続設定の許可を削除します。[8] OS標準Python、DNFで導入したパッケージ、CRB有効化、firewalld自体、ログ・キャッシュは残します。SELinuxを導入後に無効化した場合は、登録済みラベル定義も残す場合があります。独自のsystemd追加設定は、明示した旧版の1ファイル以外は削除しません。

アンインストール後の再導入は、残した設定を使って`bash /app/install.sh`を実行できます。

## 9. 制約・運用上の注意

認証、HTTPS、アプリ独自の容量制限、ウイルス検査は実装していません。**外部へ無制限に公開せず、利用者のIPアドレスやVPNなどでアクセス元を制限してください。** HTTP 80番を使うことと、誰からでも接続可能にすることは別です。

同名ファイルは上書きします。保存失敗時の部分ファイル削除、ロールバック、排他制御はありません。ブラウザーからの受信ではLinux側の一時領域を使用する場合があります。共有未接続時にLinuxへ代替保存する処理はありません。

スクリプトには、入力内容の検査や環境全体の事前診断は追加していません。自動配置・再実行・設定の取り込みと保持・安全な削除に必要な状態判定だけを行います。`set -euo pipefail`とPython側の`check=True`により通常のコマンド失敗で後続処理を止めます。自動復旧やトランザクションはなく、途中まで変更された状態は残る場合があります。SMBマウントは非同期要求なので、その後の接続失敗はWeb起動を止めません。

同じ環境へ`install.sh`、`update.sh`、`uninstall.sh`を同時に実行しないでください。更新時はWebを停止するため、アップロード処理が中断される場合があります。

