import { appendFile, mkdir, writeFile } from "fs/promises";

const BASE = "https://qiita.com/api/v2/items";
const UA = "trendscope-spike (contact: tatuki.m1105@outlook.jp)";
const DAYS = 30;
const PER_PAGE = 100;
const WAIT_MS = 500;

type QiitaItem = {
  id: string;
  title: string;
  created_at: string;
  url: string;
};

type PageResult = {
  items: QiitaItem[];
  remaining: string | null;
  reset: string | null;
};

function loadEnv() {
  try {
    // .env の値を process.env から参照できる状態にする
    process.loadEnvFile?.("./.env");
  } catch {
  }
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function fetchPage(page: number, query: string): Promise<PageResult> {
  // URLSearchParams がクエリ文字列のエンコードまで行う
  const params = new URLSearchParams({
    page: String(page),
    per_page: String(PER_PAGE),
    query,
  });
  const headers: Record<string, string> = {
    "User-Agent": UA,
  };

  if (process.env.QIITA_TOKEN) {
    headers.Authorization = `Bearer ${process.env.QIITA_TOKEN}`;
  }

  // 1ページ分の記事と、次のリクエスト判断に使うレート情報を取得する
  const res = await fetch(`${BASE}?${params}`, { headers });
  const remaining = res.headers.get("Rate-Remaining");
  const reset = res.headers.get("Rate-Reset");

  if (!res.ok) {
    throw new Error(`Qiita request failed: ${res.status} ${res.statusText}`);
  }

  const items = (await res.json()) as QiitaItem[];
  return { items, remaining, reset };
}

async function waitIfRateLow(remaining: string | null, reset: string | null) {
  if (remaining === null || Number(remaining) >= 10 || reset === null) {
    return false;
  }

  // 残り回数が少ない場合は、APIが示すリセット時刻まで待つ
  const waitMs = Math.max(Number(reset) * 1000 - Date.now(), WAIT_MS);
  console.log(`rate remaining=${remaining} waitMs=${waitMs}`);
  await sleep(waitMs);
  return true;
}

async function main() {
  loadEnv();
  await mkdir("out", { recursive: true });
  await writeFile("out/qiita-raw.jsonl", "");

  const since = Date.now() - DAYS * 24 * 60 * 60 * 1000;
  let count = 0;
  let pages = 0;
  let oldest = "";
  let newest = "";
  let windowEnd = Date.now();
  const seenIds = new Set<string>();

  // Qiitaのページ上限を避けるため、30日間を最大7日ずつに分けて取得する
  while (windowEnd >= since) {
    const windowStart = Math.max(since, windowEnd - 6 * 24 * 60 * 60 * 1000);
    // Qiitaの検索日は日本時間を基準に組み立てる
    const startDate = new Date(windowStart + 9 * 60 * 60 * 1000).toISOString().slice(0, 10);
    const endDate = new Date(windowEnd + 9 * 60 * 60 * 1000).toISOString().slice(0, 10);
    const query = `created:>=${startDate} created:<=${endDate}`;
    let page = 1;

    while (true) {
      const { items, remaining, reset } = await fetchPage(page, query);
      pages += 1;

      if (items.length === 0) {
        break;
      }

      // 日付窓の境界で同じ記事が返っても、ID単位で一度だけ保存する
      const newItems = items.filter((item) => {
        const createdAtMs = new Date(item.created_at).getTime();
        if (createdAtMs < since || seenIds.has(item.id)) {
          return false;
        }
        seenIds.add(item.id);
        return true;
      });

      if (newItems.length > 0) {
        // 1件ずつではなくページ単位で追記し、ファイルI/Oを減らす
        await appendFile(
          "out/qiita-raw.jsonl",
          newItems.map((item) => JSON.stringify(item)).join("\n") + "\n",
        );
        for (const item of newItems) {
          newest ||= item.created_at;
          oldest = item.created_at;
        }
        count += newItems.length;
      }

      console.log(
        `range=${startDate}..${endDate} page=${page} items=${items.length} total=${count} rateRemaining=${remaining ?? "unknown"}`,
      );
      const waitedForReset = await waitIfRateLow(remaining, reset);
      if (items.length < PER_PAGE) {
        break;
      }
      page += 1;
      if (!waitedForReset) {
        await sleep(WAIT_MS);
      }
    }

    windowEnd = windowStart - 24 * 60 * 60 * 1000;
  }

  console.log(`fetched ${count} items pages=${pages} range=${oldest}..${newest}`);
}

main();
