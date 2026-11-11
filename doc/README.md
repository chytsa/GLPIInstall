# GLPI 資料庫結構圖

由 `GLPI_DB_Schema.txt`（`information_schema.COLUMNS` 的查詢輸出）產生的 schema 結構圖。

## 資料概況

| 項目 | 數量 |
|---|---|
| 資料表 | 447 |
| 欄位 | 4,748 |
| 推斷出的關聯 | 792 |

全部資料表畫在同一張圖上會密到無法閱讀，因此拆成「核心總覽圖」與「互動式完整瀏覽器」兩份輸出。

## 輸出檔案

| 檔案 | 說明 |
|---|---|
| `glpi_core_schema.png` | 核心結構總覽圖 |
| `glpi_schema_explorer.html` | 互動式完整結構瀏覽器 |
| `README.md` | 本說明文件 |

### 1. `glpi_core_schema.png`：核心結構總覽

涵蓋 24 張主要資料表與它們之間的 57 條關聯，包含 `entities`、`users`、`groups`、`profiles`、`computers`、`monitors`、`printers`、`networkequipments`、`softwares`、`networkports`、`tickets`、`changes`、`problems`、`agents` 等。

每張資料表顯示表名、欄位總數、主鍵 `id (PK)`，以及指向其他核心表的外鍵欄位 `(FK)`。

顏色對照：

| 顏色 | 類別 |
|---|---|
| 黃色 | 實體（`glpi_entities`） |
| 藍色 | 使用者與權限（`users`、`groups`、`profiles`） |
| 綠色 | 資產與軟體（`computers`、`monitors`、`softwares`、`networkports` 等） |
| 紅色 | 工單（`tickets`、`changes`、`problems`） |
| 粉紅色 | GLPI Agent（`agents`） |
| 灰色 | 其他輔助表（類型、型號、位置、狀態、製造商等） |

### 2. `glpi_schema_explorer.html`：互動式完整瀏覽器

自包含的單一 HTML 檔，直接用瀏覽器開啟即可，**不需要網路連線**，支援淺色與深色模式。

功能：

- **搜尋**：左側搜尋框可比對資料表名稱與欄位名稱。
- **首頁總覽**：列出被引用次數最多的核心表，例如 `glpi_entities`（170 處）、`glpi_users`（80 處）。
- **資料表詳情**：點選任一資料表後，中間顯示完整欄位清單（型別、是否可為 NULL、PK／FK 標示）。
- **關聯導覽**：
  - 左欄：哪些資料表指向目前這張表（被引用）
  - 右欄：目前這張表指向哪些資料表（引用）
  - 所有項目皆可點擊跳轉，網址 hash 會記錄目前位置，可直接分享或加入書籤。

## 關聯的推斷方式

GLPI 資料庫**沒有建立外鍵約束**，因此本專案依欄位命名規則推斷關聯：

| 欄位名稱 | 推斷的目標資料表 |
|---|---|
| `entities_id` | `glpi_entities` |
| `users_id_tech` | `glpi_users` |
| `groups_id_tech` | `glpi_groups` |
| `xxx_id_yyy` | `glpi_xxxs`（若該表存在） |

## 已知限制

1. **關聯為推斷結果。** 命名不符合上述規則的欄位可能漏掉，也可能有少數誤判，請搭配 GLPI 官方文件或原始碼確認。
2. **多型關聯未呈現。** 以 `itemtype` + `items_id` 成對出現的欄位（例如 `glpi_agents`、`glpi_alerts`），指向哪張表取決於 `itemtype` 的值，無法由結構判斷，因此不會出現在圖上。
3. **核心圖僅涵蓋部分資料表。** 完整的 447 張表請使用互動式瀏覽器查看。
4. **資料為某一時間點的快照。** GLPI 升級後結構可能改變，需重新匯出並重新產生。

## 重新產生

1. 在 MariaDB 中執行下列查詢，並將輸出存成文字檔：

   ```sql
   SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY
   FROM information_schema.COLUMNS
   WHERE TABLE_SCHEMA = 'glpi'
   ORDER BY TABLE_NAME, ORDINAL_POSITION;
   ```

2. 解析每一列以 `| glpi` 開頭的資料，依欄位命名規則推斷關聯。
3. 以 Graphviz（`dot`）產生核心總覽 PNG，並將資料內嵌進 HTML 範本產生瀏覽器版。

## 注意事項

GLPI 的資料庫結構由程式管理，這些圖僅供**檢視與理解**，請勿依此手動修改資料表，以免升級時造成結構不一致。
