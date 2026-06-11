// Day3-1 [自分-B] daily stats → 検知（emerging / rising）。design/05 §F2 が正。
// spike では単純統計（平均・標準偏差）で可。本番は μ・σ とも EWMA 系に統一する（05 参照）。

export interface DayStat {
  day: string;            // "YYYY-MM-DD"
  termSlug: string;
  locale: string;
  mentions: number;
  distinctSources: number;
  share: number;          // mentions ÷ その day×locale の総 mentions
}

export interface Detection {
  type: "emerging" | "rising";
  termSlug: string;
  locale: string;
  score: number;
  evidence: Record<string, unknown>; // baseline/recent の数値・該当日など、目視評価で使う材料
}

// パラメータ（spike 初期値。Day3-3 で振って感度を見る）
export const PARAMS = {
  EPS: 1,        // baseline 合計がこの件数以下なら「ほぼゼロ」
  N_MIN: 2,      // ★spike はソースが HN+Qiita(+Trending) の 2〜3 本しかないので 2。
                 //   本番値（3+）の較正には源泉が足りない、という事実自体を findings に書く
  M_MIN: 5,      // 直近窓の最小サポート
  Z_TH: 2.5,     // 急上昇 z 閾値
  BASE_FROM: 30, // baseline 窓: asOf の 30 日前から
  BASE_TO: 8,    //              8 日前まで（直近 7 日は含めない）
  RECENT_DAYS: 7,
};

// emerging: baseline 期間の mentions 合計 <= EPS
//           かつ 直近窓の distinctSources（日次の max でよい） >= N_MIN
//           かつ 直近窓の mentions 合計 >= M_MIN
//           → score = distinctSources
// rising:   baseline 期間の share 系列の 平均 μ・標準偏差 σ（単純統計）
//           recentShare = 直近窓の share 平均
//           z = (recentShare - μ) / σ（σ === 0 はスキップ）
//           z >= Z_TH かつ直近 mentions 合計 >= M_MIN → score = z
// term×locale ごとに判定し、emerging が成立したら rising は見ない（新出が優先）
export function detect(stats: DayStat[], asOf: string): Detection[] {
  // TODO
  throw new Error("not implemented");
}
