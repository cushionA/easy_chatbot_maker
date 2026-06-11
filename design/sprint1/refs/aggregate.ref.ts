// 参考実装（Day2-4 を自分で書き終えてから見る）。spike/aggregate.ts の答え合わせ用。
// 型は手元の spike/types.ts / detect.ts に合わせて読み替えること。

interface Occurrence {
  termSlug: string;
  source: string;
  docId: string;
  day: string;
  locale: string;
  where: "tag" | "title";
}

interface DayStat {
  day: string;
  termSlug: string;
  locale: string;
  mentions: number;
  distinctSources: number;
  share: number;
}

export function aggregate(occs: Occurrence[]): DayStat[] {
  // 1 パス目: term×day×locale ごとに mentions と source 集合を数える
  const byKey = new Map<string, { mentions: number; sources: Set<string>; docs: Set<string> }>();
  for (const o of occs) {
    const key = `${o.termSlug}|${o.day}|${o.locale}`;
    const e = byKey.get(key) ?? { mentions: 0, sources: new Set<string>(), docs: new Set<string>() };
    if (!e.docs.has(o.docId)) {
      // 同一文書の重複 occurrence を防ぐ（extract 側で潰していても防御的に）
      e.mentions += 1;
      e.docs.add(o.docId);
      e.sources.add(o.source);
    }
    byKey.set(key, e);
  }

  // 2 パス目: day×locale ごとの総 mentions を出して share を計算
  const totals = new Map<string, number>();
  for (const [key, e] of byKey) {
    const [, day, locale] = key.split("|");
    const t = `${day}|${locale}`;
    totals.set(t, (totals.get(t) ?? 0) + e.mentions);
  }

  return [...byKey.entries()].map(([key, e]) => {
    const [termSlug, day, locale] = key.split("|");
    return {
      termSlug,
      day,
      locale,
      mentions: e.mentions,
      distinctSources: e.sources.size,
      share: e.mentions / (totals.get(`${day}|${locale}`) || 1),
    };
  });
}
