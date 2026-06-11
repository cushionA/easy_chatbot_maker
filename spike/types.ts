// Day1-4 [自分-B] 正規化スキーマ。design/06_destinations.md の CollectedItem を spike 用に写経し、
// 実データ（out/*-raw.jsonl）に当てて過不足を findings.md に記録するのが目的。

export type Source = "hackernews" | "qiita" | "github_trending";
export type Locale = "global" | "jp";

// 1 収集アイテム = 1 文書（言及の母体）。design/06 の CollectedItem 相当
export interface SpikeItem {
  source: Source;
  externalId: string;   // ソース内 ID。dedup キーは `${source}:${externalId}`
  title: string;
  url: string | null;   // HN の self-post（Ask HN 等）は null
  tags: string[];       // 構造化タグ（Qiita tags[].name 等、高信頼の抽出元）。HN は []
  popularity: number;   // points / likes_count（ソース相対・表示用。集計に混ぜない）
  publishedAt: string;  // ★UTC ISO8601。normalizer が正規化を保証する
  locale: Locale;
}

// TODO(Day1-4): HN Algolia の 1 hit → SpikeItem
// ヒント: created_at_i は Unix「秒」。new Date(sec * 1000).toISOString()
//         url が無い hit もある（null にする）。popularity は points
export function fromHnHit(hit: any): SpikeItem {
  throw new Error("not implemented");
}

// TODO(Day1-4): Qiita /items の 1 記事 → SpikeItem
// ヒント: created_at は "+09:00" 付き ISO 文字列。new Date(s).toISOString() で UTC になる
//         tags は [{ name, versions }] の配列 → name だけ取り出す。popularity は likes_count
export function fromQiitaItem(item: any): SpikeItem {
  throw new Error("not implemented");
}

// 出現（occurrence）= 用語 × 文書。BigQuery occurrences 相当（spike はメモリ + JSON）
export interface Occurrence {
  termSlug: string;
  source: Source;
  docId: string;          // `${source}:${externalId}`
  day: string;            // "YYYY-MM-DD"（UTC、publishedAt 由来）
  locale: Locale;
  where: "tag" | "title"; // 抽出層（design/05 の (a)構造化タグ / (b)自由文）
}
