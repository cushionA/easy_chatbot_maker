// Day1-2 [自分-B] HN Algolia から過去 30 日の story を取得し out/hn-raw.jsonl に保存する。
// 仕様の正: design/14_data_sources.md §1（1 クエリ 1000 件天井 → created_at_i< で時間窓スライド）
// 完成コードは無い。シグネチャと手順コメントを埋めていく。

const BASE = "https://hn.algolia.com/api/v1/search_by_date";
const UA = "trendscope-spike (contact: tatuki.m1105@outlook.jp)"; // ★自分の連絡先に書き換える

const DAYS = 30;
const MIN_POINTS = 5; // 低ポイント story を足切りして 1 窓 1000 件以内に収めやすくする

// 1 リクエスト分。created_at_i の窓と points 下限で絞った hits 配列を返す
async function fetchWindow(sinceSec: number, beforeSec: number): Promise<any[]> {
  // TODO:
  // 1. URLSearchParams で組む:
  //    tags=story, hitsPerPage=1000,
  //    numericFilters=`created_at_i>=${sinceSec},created_at_i<${beforeSec},points>=${MIN_POINTS}`
  //    （エンコードは URLSearchParams が自動でやる）
  // 2. fetch(`${BASE}?${params}`, { headers: { "User-Agent": UA } })
  // 3. res.ok を確認して json → data.hits を返す
  throw new Error("not implemented");
}

// 時間窓スライドの本体:
//   since = now - 30日, cursor = now
//   loop: fetchWindow(since, cursor) → hits 空なら終了
//         → out/hn-raw.jsonl に 1 行 1 hit で追記
//         → cursor = バッチ内の最小 created_at_i（ここが「窓を後ろにずらす」）
//         → 300ms sleep（礼儀）→ cursor <= since になったら終了
// 最後に件数と日付範囲（最古/最新）を console に出す
async function main() {
  // TODO（fs/promises の appendFile、ディレクトリは fs.mkdirSync("out", { recursive: true })）
}

main();
