// Day2-3 [自分-B] SpikeItem[] → Occurrence[]（2 層抽出）。design/05 §用語候補の抽出（2 層）が正。
import type { SpikeItem, Occurrence } from "./types.ts";

// 辞書（dict/terms.json）の 1 エントリ
export interface DictEntry {
  slug: string;        // 正規キー: "kubernetes"
  display: string;     // "Kubernetes"
  aliases: string[];   // ["k8s", "kubernetes"] 表記揺れ（slug 自身も入れておくと楽）
  ambiguous?: boolean; // "go" 等、一般語と衝突する → 共起ホワイトリスト必須
}

// (a) タグ層: item.tags を正規化（NFKC + lowercase + trim）して alias に「完全一致」で照合。
//     高信頼・曖昧性解消不要（タグ自体が文脈）。
// (b) タイトル層: alias ごとに単語境界つき・大文字小文字無視でマッチ。
//     ambiguous な alias は、共起ホワイトリスト（dict/ambiguous.json の co-occurrence 語が
//     同じタイトル内にある時だけ）採用する。
// 共通: excluded（dict/excluded.json）の slug は出現に数えない。
//       1 文書 × 1 term は 1 occurrence（mention=1。タグとタイトル両方で出ても 1）。
//       day は item.publishedAt の先頭 10 文字（UTC "YYYY-MM-DD"）。
export function extract(
  items: SpikeItem[],
  dict: DictEntry[],
  excluded: Set<string>,
  cooccur: Record<string, string[]>,
): Occurrence[] {
  // TODO
  throw new Error("not implemented");
}

// 未知語候補: 辞書に無い CamelCase / xxx.js / @scope/pkg / 大文字頭字語 をタイトルから集める
// → 出現回数つき Map。out/unknown-candidates.json に保存（辞書育成 + 将来の NER の種）
// 注意: タイトルは攻撃者が書ける外部入力。正規表現は単純なものだけ・1 タイトル 500 文字で打ち切る
export function unknownCandidates(items: SpikeItem[], dict: DictEntry[]): Map<string, number> {
  // TODO
  throw new Error("not implemented");
}
