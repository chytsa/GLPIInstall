import requests
import pandas as pd

# ====== 請依你的環境修改 ======

HOST = "140.113.7.106"
API_VERSION = "v3.0.0"                       # 來自 /api.php/v2/doc 裡列出的版本
OAUTH_BASE = f"https://{HOST}/api.php"               # OAuth2 授權伺服器 (僅 token 等)
API_BASE = f"https://{HOST}/api.php/{API_VERSION}"   # GLPI 新版 High-Level REST API
CLIENT_ID = "cd4549a5be48bfd5dee89b1f9a1766897f5f1bb11a93ca182ab7f7b2d9aad5a7"
CLIENT_SECRET = "765f75db91957bc010cef76fb45ba1b62ff6b99bd8615713d2e0e7d43b088551"
USERNAME = "glpi"
PASSWORD = "Noe3zAzt9PizEqsLVm871v7p"
VERIFY_SSL = False  # 自簽憑證先設 False
STEP = 200
OUTPUT_FILE = "glpi_export.xlsx"
ITEM_NAMES = ["Computer", "Software"]  # 要匯出的資產類型

# ================================

requests.packages.urllib3.disable_warnings()


def get_token():
    r = requests.post(
        f"{OAUTH_BASE}/token",
        data={
            "grant_type": "password",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "username": USERNAME,
            "password": PASSWORD,
            "scope": "api",
        },
        verify=VERIFY_SSL,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def discover_collection_path(item_name, headers):
    """從 Swagger 規格自動找出該資產類型的清單端點路徑"""
    r = requests.get(
        f"{API_BASE}/doc.json",
        headers=headers,
        verify=VERIFY_SSL,
    )
    if not r.ok:
        raise RuntimeError(f"{r.status_code} {r.text}")
    spec = r.json()
    for path, methods in spec.get("paths", {}).items():
        # 找 GET 清單端點(路徑結尾是 /Computer 或 /Software,不含 {id})
        # 新版 API 回傳的是相對路徑,例如 /Assets/Computer
        if path.rstrip("/").endswith(f"/{item_name}") and "get" in methods:
            return path
    raise RuntimeError(f"找不到 {item_name} 的清單端點,請到 {API_BASE}/doc 手動確認路徑")


def export_itemtype(item_name, headers):
    try:
        path = discover_collection_path(item_name, headers)
    except Exception as e:
        print(f"[{item_name}] 無法取得端點路徑: {e}")
        return pd.DataFrame()

    url = f"{API_BASE}{path}"
    print(f"[{item_name}] 使用端點: {url}")

    rows = []
    start = 0
    total = None

    while total is None or start < total:
        # 新版 High-Level API 用 query string 的 start/limit 分頁,
        # 不是舊版 apirest.php 的 Range header
        r = requests.get(
            url,
            headers=headers,
            params={"start": start, "limit": STEP},
            verify=VERIFY_SSL,
        )

        if r.status_code not in (200, 206):
            print(f"[{item_name}] 查詢失敗: {r.status_code} {r.text}")
            break

        batch = r.json()
        if isinstance(batch, dict) and "data" in batch:
            batch = batch["data"]
        if not batch:
            break
        rows.extend(batch)

        content_range = r.headers.get("Content-Range")
        if content_range and "/" in content_range:
            total = int(content_range.split("/")[-1])
        else:
            total = len(rows)  # 沒有 Content-Range 就當作已經取完

        start += STEP
        print(f"[{item_name}] 已取得 {len(rows)}/{total} 筆")

    if not rows:
        print(f"[{item_name}] 沒有資料")
        return pd.DataFrame()

    # 展開巢狀欄位(例如 {"id":1,"name":"x"} 這種關聯物件)
    return pd.json_normalize(rows, sep=".")


def main():
    token = get_token()
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}

    exported = {}
    for item_name in ITEM_NAMES:
        exported[item_name] = export_itemtype(item_name, headers)

    # 若全部都沒資料,openpyxl 無法儲存沒有任何可見工作表的活頁簿,
    # 因此至少保留空白的工作表,避免 "At least one sheet must be visible" 錯誤
    with pd.ExcelWriter(OUTPUT_FILE, engine="openpyxl") as writer:
        for item_name, df in exported.items():
            sheet_name = item_name[:31]
            if df.empty:
                df = pd.DataFrame({"訊息": [f"{item_name} 無資料或查詢失敗,請檢查上方 log"]})
            df.to_excel(writer, sheet_name=sheet_name, index=False)

    print(f"完成,已輸出到 {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
