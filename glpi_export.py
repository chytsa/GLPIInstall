import re
import time
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


def get_spec(session, headers):
    """抓取整份 Swagger(OpenAPI) 規格,只需呼叫一次"""
    r = session.get(f"{API_BASE}/doc.json", headers=headers, verify=VERIFY_SSL)
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


def fetch_collection(session, url, headers):
    """對單一清單端點做分頁抓取(start/limit),回傳所有筆數"""
    rows = []
    start = 0
    total = None

    while total is None or start < total:
        r = session.get(
            url,
            headers=headers,
            params={"start": start, "limit": STEP},
            verify=VERIFY_SSL,
        )
        if r.status_code == 404:
            # 一對一關聯(如 Infocom)在未填寫資料時,GLPI 回 404 屬正常現象,安靜跳過即可
            break
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


def print_progress_bar(current, total, prefix="", bar_length=40):
    """印出單行水平進度條(0%~100%),用 \\r 覆寫同一行"""
    if total <= 0:
        return
    fraction = min(current / total, 1.0)
    filled = int(bar_length * fraction)
    bar = "#" * filled + "-" * (bar_length - filled)
    end = "\n" if current >= total else ""
    print(f"\r{prefix} |{bar}| {fraction * 100:5.1f}% ({current}/{total})", end=end, flush=True)


def format_duration(seconds):
    minutes, secs = divmod(seconds, 60)
    hours, minutes = divmod(int(minutes), 60)
    if hours:
        return f"{hours}h{minutes}m{secs:.1f}s"
    if minutes:
        return f"{minutes}m{secs:.1f}s"
    return f"{secs:.2f}s"


def export_itemtype(item_name, headers, spec, session):
    item_start = time.perf_counter()

    try:
        main_path = discover_collection_path(item_name, spec)
    except Exception as e:
        print(f"[{item_name}] 無法取得端點路徑: {e}")
        return {item_name: pd.DataFrame()}

    main_url = f"{API_BASE}{main_path}"
    print(f"[{item_name}] 使用端點: {main_url}")
    main_start = time.perf_counter()
    main_rows = fetch_collection(session, main_url, headers)
    main_elapsed = time.perf_counter() - main_start
    print(f"[{item_name}] 主要資料已取得 {len(main_rows)} 筆 (耗時 {format_duration(main_elapsed)})")

    sheets = {}
    sheets[item_name] = (
        pd.json_normalize(main_rows, sep=".") if main_rows else pd.DataFrame()
    )

    if not EXPORT_SUB_RESOURCES or not main_rows:
        total_elapsed = time.perf_counter() - item_start
        print(f"[{item_name}] 全部完成 (總耗時 {format_duration(total_elapsed)})")
        return sheets

    sub_paths = discover_sub_resource_paths(main_path, spec)
    print(f"[{item_name}] 找到 {len(sub_paths)} 個子資源端點: {sub_paths}")

    total_parents = len(main_rows)
    for sub_path in sub_paths:
        sheet_name = sheet_name_from_path(item_name, main_path, sub_path)
        combined_rows = []
        sub_start = time.perf_counter()
        print_progress_bar(0, total_parents, prefix=f"  [{sheet_name}]")
        for idx, parent in enumerate(main_rows, start=1):
            parent_id = parent.get("id")
            if parent_id is not None:
                url = f"{API_BASE}{re.sub(r'{[^/]+}', str(parent_id), sub_path, count=1)}"
                rows = fetch_collection(session, url, headers)
                for row in rows:
                    if isinstance(row, dict):
                        row[f"{item_name}.id"] = parent_id
                combined_rows.extend(rows)

            print_progress_bar(idx, total_parents, prefix=f"  [{sheet_name}]")

        sub_elapsed = time.perf_counter() - sub_start
        print(f"  [{sheet_name}] 共 {len(combined_rows)} 筆 (耗時 {format_duration(sub_elapsed)})")
        sheets[sheet_name] = (
            pd.json_normalize(combined_rows, sep=".")
            if combined_rows
            else pd.DataFrame()
        )

    total_elapsed = time.perf_counter() - item_start
    print(f"[{item_name}] 全部完成 (總耗時 {format_duration(total_elapsed)})")
    return sheets



def fetch_agents(session, headers, spec):
    """
    抓取 /Inventory/Agent 清單(一次抓全部,不需要逐筆帶 Computer id)。
    每筆 Agent 記錄含 itemtype / items_id(對應回資產)與 remote_address
    (agent 回報庫存時的來源 IP)。
    """
    try:
        path = discover_collection_path("Agent", spec)
    except Exception as e:
        print(f"[Agent] 無法取得端點路徑: {e}")
        return pd.DataFrame()

    url = f"{API_BASE}{path}"
    print(f"[Agent] 使用端點: {url}")
    start_t = time.perf_counter()
    rows = fetch_collection(session, url, headers)
    elapsed = time.perf_counter() - start_t
    print(f"[Agent] 已取得 {len(rows)} 筆 (耗時 {format_duration(elapsed)})")
    return pd.json_normalize(rows, sep=".") if rows else pd.DataFrame()


def merge_agent_ip_into_computer(all_sheets, agents_df):
    """把 Agent 的 remote_address(來源 IP)依 itemtype/items_id 對應回 Computer 分頁"""
    if "Computer" not in all_sheets or agents_df.empty:
        return
    if "itemtype" not in agents_df.columns or "items_id" not in agents_df.columns:
        return

    comp_agents = agents_df[agents_df["itemtype"] == "Computer"].copy()
    if comp_agents.empty:
        return

    # 同一台電腦理論上只會有一個 Computer inventory agent,
    # 若有多筆(例如重複註冊),保留最近一次回報(last_contact 最新)的那筆
    if "last_contact" in comp_agents.columns:
        comp_agents = comp_agents.sort_values("last_contact", ascending=False)
    comp_agents = comp_agents.drop_duplicates(subset="items_id", keep="first")

    keep_cols = {"items_id": "id"}
    if "remote_address" in comp_agents.columns:
        keep_cols["remote_address"] = "agent_remote_address"
    if "last_contact" in comp_agents.columns:
        keep_cols["last_contact"] = "agent_last_contact"

    comp_agents = comp_agents[list(keep_cols.keys())].rename(columns=keep_cols)
    all_sheets["Computer"] = all_sheets["Computer"].merge(comp_agents, on="id", how="left")


def main():
    token = get_token()
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    with requests.Session() as session:
        spec = get_spec(session, headers)

        all_sheets = {}
        for item_name in ITEM_NAMES:
            all_sheets.update(export_itemtype(item_name, headers, spec, session))

        agents_df = fetch_agents(session, headers, spec)
        all_sheets["Agent"] = agents_df
        merge_agent_ip_into_computer(all_sheets, agents_df)

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
