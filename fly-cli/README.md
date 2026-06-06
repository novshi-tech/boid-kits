# fly-cli

fly.io の CLI (`fly` / `flyctl`) をサンドボックスに提供する kit。

`github-cli` と同じ **host_commands** モデルを採用している。`fly` コマンドは
サンドボックス内ではなく **ホスト側で broker 経由で実行** され、出力だけが
サンドボックスに返る。これにより以下を満たす:

- API トークンや `~/.fly/config.yml` の認証情報をサンドボックスに渡さない
- サンドボックスのネットワーク egress に依存せず fly.io API へ到達できる
- 112MB ある `flyctl` バイナリをサンドボックスへマウントしない

## セキュリティモデル

### boid が保証すること

- サンドボックスが呼べるのは `host_commands.fly.allow` に列挙したサブコマンドのみ
  (`auth` と `tokens` は意図的に除外 — ログインとトークン発行はホスト管理)
- トークンはホスト側プロセスの環境にのみ存在し、サンドボックスには渡らない

### boid が保証しないこと

- 許可したサブコマンドの先で起きる操作 (`deploy` / `secrets set` / `scale` 等)。
  これらは実際に fly.io 上のリソースを変更する。許可範囲は `allow` の編集で調整する

## 認証

`fly` はホスト側で実行されるため、認証は次のいずれかで解決される
(上から優先):

1. **boid の secret store** — `FLY_API_TOKEN` を登録しておくと注入される。
   個人ログインとは別のデプロイ用トークンを使いたい場合に有用
2. **ホストの `~/.fly/config.yml`** — secret が無ければ、ホストで
   `fly auth login` 済みのログイン情報にフォールバックする

どちらも無い場合、`fly` は未認証で失敗する (安全側に倒れる)。

## バイナリのパス

`host_commands.fly.path` は公式インストーラ
(`curl -L https://fly.io/install.sh | sh`) の既定配置である
`${HOME}/.fly/bin/flyctl` を指す。`${HOME}` は kit ロード時に
daemon の HOME に展開される。

別の場所 (例: `/usr/local/bin/flyctl`) にインストールしている場合は、
プロジェクト直下の `.boid/project.local.yaml` で上書きする:

```yaml
version: 1
host_commands:
  fly:
    path: /usr/local/bin/flyctl
```

## 検出

`detect.sh` はホストに `fly` または `flyctl` が見つかれば `optional` を返す。
デプロイは task ごとの関心事のため `required` にはせず、候補として提示する。

## 既知の制約

- **インタラクティブ session は不向き**: `fly ssh console` (引数なし) や
  `fly proxy` のような対話的/トンネル系は broker 越しでは扱いにくい。
  `fly ssh console -C "<command>"` のような一発実行を推奨
- **stdin 無効**: host command は既定で stdin を渡さない。stdin 入力に
  依存するサブコマンド (例: `fly secrets import`) は引数形式
  (`fly secrets set NAME=value`) を使う
- **path はホスト依存**: 既定で `${HOME}/.fly/bin/flyctl` を前提とする。
  異なる場合は上記のとおり `project.local.yaml` で上書きが必要
