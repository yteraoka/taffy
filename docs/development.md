# 開発者向け情報

[README](../README.ja.md) | [リリースの流れ](release.md)

## ソースからのビルド

macOS 13 以降と Swift 5.9 以降（Xcode 15+ もしくは Command Line Tools）が必要です。

```sh
make app       # build/Taffy.app を作成
make run       # ビルドして起動
make install   # /Applications にコピー
```

`UNIVERSAL=1 make app` で arm64 + x86_64 のユニバーサルバイナリになります（Xcode が必要）。

テストは `swift test`（または `make test`）で実行できます。

### 署名

アドホック署名のため、再ビルドのたびに macOS が別アプリとみなし、オートメーションの許可を求められ直すことがあります。気になる場合は手元の署名 ID を指定してビルドしてください。

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" make app
```

## しくみ

- 各ブラウザへの問い合わせは `osascript`（JavaScript for Automation）を子プロセスで実行し、ブラウザごとに並列で取得します（`Sources/Taffy/Scripts.swift`）
- 起動していないブラウザには問い合わせません（問い合わせるとブラウザが起動してしまうため）
- タブの切り替えと削除は AppleScript で行います。Chromium 系と Arc はタブ ID でタブを特定するので、一覧取得後にタブが移動していても正しいタブを開きます。Safari にはタブ ID がないため、位置（インデックス）で特定します
- 音声 / カメラなどの状態は、AppleScript では取得できないため、タブバーの各タブをアクセシビリティ API で読んでいます（Chrome 系はタブの読み上げ名に「- Audio playing」「- Camera recording」などを付け、Safari は音声を出しているタブにミュートボタンを出します）
- Chromium 系はタブに状態を 1 つしか出さないため、Web 会議中のタブは「Audio playing」になります。そこで `CaptureInference` が、Mac のどこかでカメラが使われているか（CoreMediaIO の "is running somewhere"）と、ブラウザ自身が音声を出力 / 録音しているか（`AppAudio`）を見て、音声を出している Web 会議サイトのタブにその状態を足します
- `AppAudio` は CoreAudio のプロセスオブジェクト（`kAudioHardwarePropertyProcessObjectList`、macOS 14.2 以降）の `IsRunningInput` / `IsRunningOutput` を読み、ブラウザ本体か、その「責任プロセス」がブラウザであるプロセス（Chromium の audio service ヘルパーや Safari の WebKit GPU プロセス）、またはアプリのバンドル内の実行ファイルのものを集計します。タブ単位ではなくアプリ単位の情報です（Chromium はすべてのタブの音声を 1 つのヘルパーで扱うため）。macOS 14.1 以前では使えないので、マイクは CoreAudio のデバイス単位の "is running somewhere" にフォールバックします
- 実機の CoreAudio を読むテストは `TAFFY_LIVE_AUDIO=1 swift test --filter AppAudioLiveTests` で実行できます（CI では skip されます）
- Claude Code の判定は、各タブの tty を AppleScript で取り、`ps` で同じ tty に `claude` のプロセスがいるかを調べます。tty を取れない Ghostty ではタブのタイトルで判定し、作業ディレクトリは `lsof` で Claude Code のプロセスから読みます

## ブラウザの追加

`Sources/Taffy/Browser.swift` の `Browser.all` に bundle ID を追加してください。Chrome 互換の AppleScript 辞書を持つブラウザなら `kind: .chromium` で動くはずです。

## CI

`.github/workflows/ci.yaml` が PR の作成・更新時と main への push で動き、次の 2 つのジョブを実行します。

| ジョブ | 内容 |
| --- | --- |
| `test` | `swift test`（検索のスコア、`@` フィルタ、音声 / カメラ状態の判定と Web 会議タブの推定、Claude Code の判定、ホットキーの解析、AppleScript の生成とコンパイル） |
| `build` | リリースと同じ手順でユニバーサルな `.app` の zip を作り、cask の構文を確認して、zip を Artifacts に上げる |

Actions タブから手動で実行することもできます。
