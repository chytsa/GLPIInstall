import re
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
EXPORT_SUB_RESOURCES = True  # 是否連同該資產類型底下的所有子資源(元件/關聯)一併匯出

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


def get_spec(headers):
    """抓取整份 Swagger(OpenAPI) 規格,只需呼叫一次"""
    r = requests.get(f"{API_BASE}/doc.json", headers=headers, verify=VERIFY_SSL)
    if not r.ok:
        raise RuntimeError(f"{r.status_code} {r.text}")
    return r.json()


def discover_collection_path(item_name, spec):
    """找出該資產類型「清單」的端點路徑,例如 Computer -> /Assets/Computer"""
    for path, methods in spec.get("paths", {}).items():
        # 路徑結尾是 /Computer 或 /Software(不含 {id})才是清單端點
        if path.rstrip("/").endswith(f"/{item_name}") and "get" in methods:
            return path
    raise RuntimeError(f"找不到 {item_name} 的清單端點,請到 {API_BASE}/doc 手動確認路徑")


def discover_sub_resource_paths(main_path, spec):
    """
    找出 main_path(例如 /Assets/Computer)底下所有「子資源清單」路徑,
    例如 /Assets/Computer/{id}/Component/Memory。
    排除最後一段是 {id} 的路徑(那是單筆查詢端點,用不到)。
    """
    prefix = main_path.rstrip("/") + "/"
    subs = []
    for path, methods in spec.get("paths", {}).items():
        if not path.startswith(prefix):
            continue
        if "get" not in methods:
            continue
        last_segment = path.rstrip("/").split("/")[-1]
        if last_segment.startswith("{"):
            continue  # 單筆查詢端點(需要子資源自己的 id),略過
        subs.append(path)
    return subs


def fetch_collection(url, headers):
    """對單一清單端點做分頁抓取(start/limit),回傳所有筆數"""
    rows = []
    start = 0
    total = None

    while total is None or start < total:
        r = requests.get(
            url,
            headers=headers,
            params={"start": start, "limit": STEP},
            verify=VERIFY_SSL,
        )
        if r.status_code not in (200, 206):
            print(f"  查詢失敗: {url} -> {r.status_code} {r.text}")
            break

        batch = r.json()
        if isinstance(batch, dict) and "data" in batch:
            batch = batch["data"]
        if isinstance(batch, dict):
            # 部分子資源(如一對一關聯 Infocom)直接回傳單一物件而非陣列
            batch = [batch] if batch else []
        if not batch:
            break
        rows.extend(batch)

        content_range = r.headers.get("Content-Range")
        if content_range and "/" in content_range:
            total = int(content_range.split("/")[-1])
        else:
            total = len(rows)

        start += STEP

    return rows


def sheet_name_from_path(item_name, main_path, sub_path):
    """把 Swagger 路徑轉成合法且易讀的 Excel 工作表名稱(<=31 字元)"""
    remainder = sub_path[len(main_path):]
    remainder = re.sub(r"\{[^/]+\}/?", "", remainder)  # 去掉 {id} 這類佔位符
    parts = [item_name] + [p for p in remainder.split("/") if p]
    name = "_".join(parts)
    return name[:31] if name else item_name[:31]


def export_itemtype(item_name, headers, spec):
    try:
        main_path = discover_collection_path(item_name, spec)
    except Exception as e:
        print(f"[{item_name}] 無法取得端點路徑: {e}")
        return {item_name: pd.DataFrame()}

    main_url = f"{API_BASE}{main_path}"
    print(f"[{item_name}] 使用端點: {main_url}")
    main_rows = fetch_collection(main_url, headers)
    print(f"[{item_name}] 主要資料已取得 {len(main_rows)} 筆")

    sheets = {}
    sheets[item_name] = (
        pd.json_normalize(main_rows, sep=".") if main_rows else pd.DataFrame()
    )

    if not EXPORT_SUB_RESOURCES or not main_rows:
        return sheets

    sub_paths = discover_sub_resource_paths(main_path, spec)
    print(f"[{item_name}] 找到 {len(sub_paths)} 個子資源端點: {sub_paths}")

    for sub_path in sub_paths:
        sheet_name = sheet_name_from_path(item_name, main_path, sub_path)
        combined_rows = []
        for parent in main_rows:
            parent_id = parent.get("id")
            if parent_id is None:
                continue
            url = f"{API_BASE}{re.sub(r'{[^/]+}', str(parent_id), sub_path, count=1)}"
            rows = fetch_collection(url, headers)
            for row in rows:
                if isinstance(row, dict):
                    row[f"{item_name}.id"] = parent_id
            combined_rows.extend(rows)

        print(f"  [{sheet_name}] 共 {len(combined_rows)} 筆")
        sheets[sheet_name] = (
            pd.json_normalize(combined_rows, sep=".")
            if combined_rows
            else pd.DataFrame()
        )

    return sheets


def main():
    token = get_token()
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    spec = get_spec(headers)

    all_sheets = {}
    for item_name in ITEM_NAMES:
        all_sheets.update(export_itemtype(item_name, headers, spec))

    # 若全部都沒資料,openpyxl 無法儲存沒有任何可見工作表的活頁簿,
    # 因此至少保留空白的工作表,避免 "At least one sheet must be visible" 錯誤
    used_names = set()
    with pd.ExcelWriter(OUTPUT_FILE, engine="openpyxl") as writer:
        for sheet_name, df in all_sheets.items():
            name = sheet_name[:31]
            # 避免截斷後名稱重複
            suffix = 1
            base_name = name
            while name in used_names:
                suffix_str = f"_{suffix}"
                name = base_name[: 31 - len(suffix_str)] + suffix_str
                suffix += 1
            used_names.add(name)

            if df.empty:
                df = pd.DataFrame({"訊息": [f"{sheet_name} 無資料或查詢失敗,請檢查上方 log"]})
            df.to_excel(writer, sheet_name=name, index=False)

    print(f"完成,已輸出到 {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
