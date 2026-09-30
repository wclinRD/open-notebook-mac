# Open Notebook.app

macOS 包裝版 [Open Notebook](https://github.com/lfnovo/open-notebook) —— 一個隱私優先的
NotebookLM 替代方案。點擊圖示會自動啟動 SurrealDB、FastAPI 與網頁介面，關閉時自動收掉全部程序。

```
open release/OpenNotebook.app
```

首次啟動約 5 秒。**不需要** Docker，不需要自己開終端機。

## 它是什麼

一個 SwiftUI 外殼加上內嵌的執行環境。內容仍是 Open Notebook 原有的 Next.js 介面（顯示在
WKWebView 中），這個 repo 只負責把服務啟動、監看、與清理。

不是原生重寫 —— 那需要重做 29,500 行前端、14 種語系，並且會永久落後上游。

## 安裝

從 [Releases](https://github.com/wclinRD/open-notebook-mac/releases) 下載 `OpenNotebook-1.0.0.zip`：

```bash
unzip OpenNotebook-1.0.0.zip
xattr -dr com.apple.quarantine OpenNotebook.app   # 繞過 Gatekeeper 隔離標記
mv OpenNotebook.app /Applications/
open /Applications/OpenNotebook.app
```

`xattr` 這步是必要的：app 只做 ad-hoc 簽章（沒有 Developer ID），macOS 會擋下未授權的程式。
不想用指令列的話，到「系統設定 → 隱私權與安全性」按「仍要打開」。

## 需求

| 項目 | 說明 |
|---|---|
| macOS | 14 以上 |
| 架構 | Apple Silicon（arm64） |
| 磁碟 | 約 1.1 GB |
| AI 供應商 | 需自備，見下方「接上 LLM」 |

首次啟動時 SurrealDB 會自動跑 25 個資料庫 migration，約 3 秒。

## 接上 LLM

app **不內附任何模型**，也連不出去 —— 它只是本機服務的啟動器。LLM 要自己裝、自己接。
以下以 LM Studio 為例（實測可用的路徑），任何 OpenAI 相容伺服器都一樣。

### 1. 裝 LM Studio 並下載模型

從 [lmstudio.ai](https://lmstudio.ai/) 下載安裝，開啟後在搜尋框找模型，選一個你要的下載。
至少需要兩種：

| 角色 | 用途 | 建議 |
|---|---|---|
| 聊天模型 | 問答、摘要 | 30B 以上 MoE（例如 `qwen3.6-27b-a3b-coder`）。**必須支援 context ≥ 8192**，長文件會超出 |
| 嵌入模型 | 檢索來源內容 | `text-embedding-nomic-embed-text-v1.5` 之類的小模型即可 |

沒下載聊天模型的話，問答功能會報錯。

### 2. 開啟本機伺服器

LM Studio 側邊欄最下方的 **Developer / 本機伺服器** 分頁 → 開啟 Start Server。
預設 port **1234**。

確認它活著（應該列出你下載的模型）：

```bash
curl http://localhost:1234/v1/models
```

沒反應就是沒開，或 port 被別人佔了。

### 3. 在 app 裡註冊

app → 側邊欄 **設定 → AI 模型**：

1. **Add Credential** → 選 **OpenAI Compatible**
2. Base URL 填 `http://localhost:1234/v1`
3. API key 填 `lm-studio` —— 這是佔位字串，LM Studio 不驗證，但欄位不能留空
4. **Save**，接著按 **Test Connection** 驗證

> 憑證不是明文存的，會用 `OPEN_NOTEBOOK_ENCRYPTION_KEY` 加密後放進資料庫。
> 所以換掉 `.env` 會讓已存的憑證讀不出來（見下方「資料放在哪」）。

### 4. 逐個加入模型

**Add Model**，每個模型一筆。Model name 要跟 `/v1/models` 回傳的 `id` **完全一致**：

| 欄位 | 填什麼 |
|---|---|
| Provider | 剛建立的 credential |
| Model name | `curl` 到的 `id` 原文，例如 `qwen3.6-27b-a3b-coder` |
| Type | 聊天模型填 `language`；嵌入模型填 `embedding` |

Model name 拼錯是最常見的失敗原因 —— 連不上時先回頭 `curl` 核對一次。

### 5. 指定預設模型

同一頁往下有「預設模型」區，**必填兩個**：

- **Chat model** — 沒有它整個問答都不能用
- **Embedding model** — 沒有它上傳的文件無法建立索引

另外三個可選，不填會自動沿用 Chat model：

- **Transformation model** — 用來把來源內容轉成筆記。heavy prompt 吃 token 很兇，
  用 35B 等大模型容易撞到 8192 上限。實測另外掛一個 coder 級的較小模型比較穩
- **Tools model** — 給 agent 用
- **Large context model** — 超過 105,000 tokens 時自動切換

TTS / STT 留空。播客生成與音訊轉錄在本地沒有對應模型，本來就用不了。

### 驗證

設定頁每個模型旁都有 Test 按鈕。更直接的驗法是建一個筆記本、丟一份 PDF 進去、
對它問一個只有文件裡才有的問題 —— 答得出來就代表 embedding 與 chat 都通了。

> **PDF 需要系統的 `libmagic`**：`brew install libmagic`，否則 PDF 會解析失敗。

### 其他供應商

Ollama、oMLX 在 provider 清單裡有自己的項目（base URL 分別預設 `localhost:11434`、`localhost:11435`），
選它們就不要選 OpenAI Compatible。雲端供應商（OpenAI、Anthropic、Google、Groq、OpenRouter…）
填自己的 API key 即可。完整清單與各廠的環境變數見
[上游文件](https://github.com/lfnovo/open-notebook/blob/main/docs/5-CONFIGURATION/ai-providers.md)。

## 資料放在哪

**不在 `.app` 裡面。** 全部在：

```
~/Library/Application Support/OpenNotebook/
├── .env              首次啟動自動產生
├── surreal_data/     資料庫
└── data/uploads/     上傳的來源檔案
```

換掉或刪除 `.app` 不會動到筆記本。備份就是複製整個資料夾。

`.env` 只在不存在時才寫入 —— 裡面的 `OPEN_NOTEBOOK_ENCRYPTION_KEY` 保護已儲存的 AI 供應商憑證，
重寫會讓既有憑證全部無法解密。

日誌在 `~/Library/Logs/OpenNotebook/`。

## 與開發模式共存

啟動時會先探測服務是否已在運行，已健康的會**直接複用而不重啟**，關閉時也只收掉自己啟動的程序。
所以可以同時開著 `open-notebook` 的原始碼開發實例，兩者不會搶 port。

| 服務 | Port | 開發模式 | app |
|---|---|---|---|
| SurrealDB | 8000 | ✅ | 複用或自啟 |
| FastAPI | 5055 | ✅ | 複用或自啟 |
| 網頁介面 | 3000 / 3001 / **8502** | ✅ | 8502 |

## 選單

- `Cmd+R` — 重新載入
- **Restart Services** — 重啟三個服務（服務崩潰或 port 卡住時）
- `Cmd+Q` — 結束，會等待程序確實收乾淨才退出

## 從終端機關閉

```bash
osascript -e 'quit app "OpenNotebook"'
```

不要用 `osascript -e 'tell application "System Events" to ... keystroke "q" using command down'`。
`keystroke` 送的是鍵盤層事件，macOS 會交給**當前最前台的應用程式**，
在其他 app 前面按這條會關掉那個 app。

## 自行編譯

```bash
./build_release.sh              # 完整建置（含 Next.js production build）
./build_release.sh --skip-web   # 沿用現有前端 build
```

需要 `swift`、`node`、`npm`、`uv`，以及一份 Open Notebook 原始碼
（預設在 `../open-notebook`，可用 `OPEN_NOTEBOOK_SRC` 覆寫）。
首次執行會把 SurrealDB、Node、Python venv 快取到 `.build-cache/`，之後重建很快。

App 圖示在 `Sources/logo.png`，build 時用 `iconutil` 轉成 `AppIcon.icns`。

## 對上游的修改

`open_notebook/database/async_migrate.py` 一處：migration 檔案改為相對於套件位置解析，
不再依賴 working directory。這是上游的既有缺陷，只是在 cwd 剛好是 repo root 時不會踩到。
`<details><summary>diff</summary>` 見 `安裝說明.md`。

## 已知限制

- **ad-hoc 簽章** —— 沒有 Developer ID，因此無法通過 Gatekeeper 自動驗證（見上方安裝步驟）。
  只適合自己使用；要散布得申請正式簽章。
- **1.0 GB** —— 主要來自 Python 依賴（678 MB）。要縮小得換 PyInstaller 或精簡依賴。
- **需要系統的 `libmagic`** —— 處理 PDF 來源，未安裝時 PDF 會失敗（`brew install libmagic`）。
- **TTS / STT 未設定** —— 播客生成與音訊轉錄不可用，與上游限制相同。
- **僅在 Apple Silicon 測過** —— build script 抓的是 `darwin-arm64` 版本。
- **沒有自動更新、選單列圖示或 Dock 常駐** —— 純粹是啟動器。

## 授權

本 repo 的 Swift 外殼程式碼隨上游專案授權發布。內嵌的 Open Notebook、SurrealDB、Node.js
各自保留其原始授權。**將本 app 散布給他人前，請先確認 SurrealDB（BSL 授權）的散布條款。**
