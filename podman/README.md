# podman

サンドボックス内から cetusguard proxy 経由でホストの podman/docker API にアクセスする kit。
TestContainers 等のコンテナベースのテストフレームワークで使用する。

## セキュリティモデル

### boid が保証すること

- sandbox から外部に出る経路はこの kit で宣言した socket
  (`${XDG_RUNTIME_DIR}/cetusguard/podman.sock`) のみ
- socket パスを cetusguard proxy に固定しているため、素の podman socket を
  誤って sandbox に通す事故を防ぐ

### boid が保証しないこと

- socket の先にある podman/docker API 呼び出しの制限。API レベルの
  アクセス制御は cetusguard のルール設定に委ねる

### 素の podman socket を直結してはいけない理由

`$XDG_RUNTIME_DIR/podman/podman.sock` や `/var/run/docker.sock` を sandbox に
直結すると、sandbox 内のプロセスが制限なく Docker/Podman API を呼び出せる。
これにより以下の攻撃が可能になる:

- **任意 bind mount**: ホストの `/` をコンテナ内にマウントし、root 権限を奪取
- **privileged コンテナ**: `--privileged` でホストデバイスへのフルアクセスを取得
- **host network 参加**: `--network=host` でホストのネットワークスタックに直接アクセス
- **任意 image pull**: 悪意ある image の pull・実行
- **CapAdd**: 任意の Linux capability の付与

したがって、cetusguard proxy の導入は**必須**とみなす。

## セットアップ

### 1. cetusguard のインストール

Go がインストール済みの場合:

```sh
go install github.com/hectorm/cetusguard/cmd/cetusguard@latest
```

または GitHub Releases からバイナリを取得:

```sh
# アーキテクチャに合わせて URL を調整
curl -L -o ~/.local/bin/cetusguard \
  https://github.com/hectorm/cetusguard/releases/latest/download/cetusguard-linux-amd64
chmod +x ~/.local/bin/cetusguard
```

### 2. ルールファイルの作成

`~/.config/cetusguard/rules.txt` を作成する (推奨ポリシーは後述):

```sh
mkdir -p ~/.config/cetusguard
cat > ~/.config/cetusguard/rules.txt << 'RULES'
! --- TestContainers 用最小権限ルールセット ---

! Ping
GET,HEAD %API_PREFIX_PING%

! Version
GET %API_PREFIX_VERSION%

! System info
GET %API_PREFIX_INFO%

! Events (TestContainers がコンテナ状態の監視に使用)
GET %API_PREFIX_EVENTS%

! Container: list / inspect / logs / wait / top
GET %API_PREFIX_CONTAINERS%/json
GET %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/json
GET %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/logs(\?.*)?
POST %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/wait(\?.*)?
GET %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/top(\?.*)?

! Container: create / start / stop / kill / remove
POST %API_PREFIX_CONTAINERS%/create(\?.*)?
POST %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/start(\?.*)?
POST %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/stop(\?.*)?
POST %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/kill(\?.*)?
DELETE %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%(\?.*)?

! Exec (TestContainers の health check 等で使用)
POST %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/exec
POST %API_PREFIX_EXEC%/%EXEC_ID_OR_NAME%/start
GET %API_PREFIX_EXEC%/%EXEC_ID_OR_NAME%/json

! Image: pull / inspect / list
POST %API_PREFIX_IMAGES%/create(\?.*)?
GET %API_PREFIX_IMAGES%/json
GET %API_PREFIX_IMAGES%/%IMAGE_ID_OR_REFERENCE%/json

! Network: create / inspect / list / connect / disconnect / remove
GET %API_PREFIX_NETWORKS%(\?.*)?
GET %API_PREFIX_NETWORKS%/%NETWORK_ID_OR_NAME%
POST %API_PREFIX_NETWORKS%/create(\?.*)?
POST %API_PREFIX_NETWORKS%/%NETWORK_ID_OR_NAME%/connect(\?.*)?
POST %API_PREFIX_NETWORKS%/%NETWORK_ID_OR_NAME%/disconnect(\?.*)?
DELETE %API_PREFIX_NETWORKS%/%NETWORK_ID_OR_NAME%(\?.*)?

! Volume: create / inspect / list / remove (名前付き volume のみ)
GET %API_PREFIX_VOLUMES%(\?.*)?
POST %API_PREFIX_VOLUMES%/create(\?.*)?
GET %API_PREFIX_VOLUMES%/%VOLUME_NAME%
DELETE %API_PREFIX_VOLUMES%/%VOLUME_NAME%(\?.*)?
RULES
```

ルールの書式:

- 各行は `<HTTP_METHOD>[,<METHOD>] <URL_PATTERN>` の形式
- `!` で始まる行はコメント
- `%VAR%` は cetusguard が定義する変数 (正規表現に展開される)
- URL パターンは正規表現を使用可能 (例: `(\?.*)?` でクエリストリングを許可)

### 3. ソケットディレクトリの作成

```sh
mkdir -p ${XDG_RUNTIME_DIR}/cetusguard
```

### 4. systemd user unit の作成

`~/.config/systemd/user/cetusguard.service`:

```ini
[Unit]
Description=CetusGuard - Docker/Podman API proxy
Documentation=https://github.com/hectorm/cetusguard

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p %t/cetusguard
ExecStart=%h/.local/bin/cetusguard \
  -backend-addr unix://%t/podman/podman.sock \
  -frontend-addr unix://%t/cetusguard/podman.sock \
  -rules-file %h/.config/cetusguard/rules.txt
ExecStartPost=/bin/chmod 0660 %t/cetusguard/podman.sock
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

> `%t` は systemd の `$XDG_RUNTIME_DIR` 展開、`%h` は `$HOME` 展開。

### 5. 有効化

```sh
systemctl --user daemon-reload
systemctl --user enable --now cetusguard.service
```

## 推奨ポリシーについて

上記のルールセットは TestContainers の基本的な動作に必要な API エンドポイントを
許可する。

### cetusguard の制限事項

cetusguard は **HTTP メソッド + URL パス** に基づくフィルタリングを行う。
**リクエストボディの検査はサポートしていない**。そのため、以下のような
ボディレベルの制約は cetusguard 単体では強制できない:

| 制約 | cetusguard で強制可能か |
|------|------------------------|
| `HostConfig.Privileged=true` のブロック | 不可 |
| `HostConfig.Binds` の host path 制限 | 不可 |
| `NetworkMode=host` のブロック | 不可 |
| `CapAdd` のブロック | 不可 |
| image pull のレジストリ制限 | 不可 (URL にレジストリ名が含まれないため) |

これらの制約を強制するには、以下の補完的な対策を検討すること:

- **rootless podman の使用**: rootless モードではそもそも privileged コンテナや
  host path bind mount の影響範囲がユーザ名前空間に限定される
- **containers.conf でのデフォルト制限**: podman の設定で `no_new_privileges=true`
  等を設定する
- **OCI hook や seccomp プロファイル**: コンテナ実行時の syscall を制限する

rootless podman + cetusguard の URL フィルタリングを組み合わせることで、
実用的なセキュリティレベルを確保できる。

## 動作確認

### 1. cetusguard proxy の稼働確認

```sh
curl --unix-socket ${XDG_RUNTIME_DIR}/cetusguard/podman.sock http://d/_ping
```

`OK` が返れば proxy は稼働中。

### 2. boid sandbox 内からの確認

```sh
# sandbox 内で実行
podman ps
# または
docker ps
```

コンテナ一覧が取得できれば正常に動作している。

### 3. TestContainers の動作確認

TestContainers を使うプロジェクトでテストを実行し、コンテナの作成・起動・停止が
正常に行われることを確認する。

## 限界・既知の制約

- **cetusguard ポリシーの甘さはユーザ責任**: ルールが広すぎると保護が意味を
  なさない。上記の推奨ルールセットは TestContainers 用途の最小権限を意図している
  が、ボディレベルの制約は強制できない
- **proxy 稼働チェックなし**: kit 側で cetusguard が起動しているかどうかは
  検出しない。未起動時は sandbox 内で podman/docker が使えないだけで安全に失敗する
- **task ごとのポリシー差別化は行わない**: 全 task で同一の cetusguard ルールが
  適用される。task ごとにポリシーを変えると穴空きリスクが増えるため意図的な設計
- **OR 条件の commands 未対応**: `requires.commands` は AND 条件のため `podman` を
  primary として指定。docker のみの環境では `podman` コマンドのインストールが必要
