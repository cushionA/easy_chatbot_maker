import { appendFile, mkdir } from "fs/promises";

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
  const params = new URLSearchParams({
    tags:"story", 
    hitsPerPage:"1000",
    numericFilters:`created_at_i>=${sinceSec},created_at_i<${beforeSec},points>=${MIN_POINTS}`});
  
  const res = await fetch(`${BASE}?${params}`, { headers: { "User-Agent": UA } });

  if(res.ok){
    const data = await res.json();
    return data.hits;
  }

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
  // PromiseはTaskと同じ。setTimeoutはコールバック関数rをms後に実行する
  // rはresolveというPromiseを完了させる関数の意味。JSランタイムの中身
  const sleep = (ms:number)=> new Promise(r => setTimeout(r,ms));
  let res = [];
  const nowSec = Math.floor(Date.now() / 1000);
  const since = nowSec - (30 * 24 * 60 * 60);// 30日が何秒か、と言うので引く
  let cursor = nowSec;

  // ディレクトリ作成。recursiveですでにあってもエラーにならん
  await mkdir("out", { recursive: true });

  //const hits =  await fetchWindow(since,cursor);
  //console.log(hits);
  // TODO（fs/promises の appendFile、ディレクトリは fs.mkdirSync("out", { recursive: true })）
  do{
    // 30日前以後、は動かさない。
    // 今日からn日目まで取れてるなら、で以前のところを今日から動かしていく
    const hits =  await fetchWindow(since,cursor);
    if (hits.length === 0) {
  break;
}
    res.push(...hits); 
    cursor = hits.sort((a, b) => a.created_at_i - b.created_at_i)[0]['created_at_i'];
    for (const hit of hits) {
  await appendFile("out/hn-raw.jsonl", JSON.stringify(hit) + "\n");
}
  console.log("リクエスト実施")
  await sleep(300); // 3秒待機
  }while( cursor > since )
    
  // sortにはa,bの比較関数を
  // 2つの値を比べて、結果を『正・負・ゼロ』の数値で受け取る」というルール
  res = res.sort((a, b) => a.created_at_i - b.created_at_i);
  console.log(`取得結果 ${res.length}件 期間${res[0]["created_at"]} ~ ${res[res.length-1]["created_at"]}`);
}

main();
