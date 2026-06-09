# Sprint 4 Day 1 作業指示書（2026-06-01）

> テーマ: **チャット画面の足場と分類結線**
> 完了時の状態: `/t/{slug}/chat` でカテゴリ選択 → コンボボックスで問題名を選ぶ／「該当なし」で自然言語入力 → 分類エンドポイントを呼んで候補が画面に出る
> 推定所要: 5〜7 時間

> 着手前に必読: [`05_search_classification.md:5-35`](../05_search_classification.md)（フロー①②③）、[`sprint1/day3.md`](../sprint1/day3.md)（画面の書き方の手本）。
> 既存コンポーネント構成: ページは `apps/web/src/pages/`、再利用部品は `apps/web/src/components/`。Sprint 1 の Category CRUD は `apps/web/src/pages/categories/` に置いた。本 Sprint の Chat は `apps/web/src/pages/chat/` にまとめる。

---

## Day4-1. チャット画面の足場 `ChatPage.tsx` を作る [自分（最初の1個=画面の型）] [FE]

**目的**
利用者導線の入口になる `/t/:slug/chat` を自分の手で立てる。フロー①②③をステップ駆動で進める「画面の型」（state machine 的な union type + コンポーネント切替）をここで決める。これが Day2/Day3 の動的フォーム・確認画面・未分類キューを差し込む土台になる。面接で「チャット UI をどういう状態機械として設計したか」を語れる中核。

**自分で書く理由**
画面のステップ遷移（`ChatStep` 型と各ステップの責務分割）は後から差し替えにくい設計判断。AI に丸投げすると state が散らかり、Day2 以降のエスカレーション分岐を差し込めなくなる。型と遷移だけは自分で握る。

**前提確認**
- [ ] Sprint 1 完了（`/t/:slug/categories` が動き、Node API middleware でテナント文脈が `AsyncLocalStorage` に入る）
- [ ] **分類エンドポイントが実在し想定シグネチャで呼べるか実機確認**（`apps/api/src/classify/` を確認。無ければ Sprint 2 に戻る。[`sprint4_plan.md:18`](../sprint4_plan.md)）
- [ ] `apps/api/src/models/` の `Category` / `KnowledgeEntry` の型定義を確認（`code` / `name` / `emoji` / `sortOrder` / `requiredFieldCodes` / `autoResolution` / `guidanceMessage`）

**手順**
1. 新規 `apps/web/src/pages/chat/ChatPage.tsx`。画面の型（state machine）の**骨格だけ**を以下のシグネチャに沿って自分で組む。各 `step` に何を置くかは決まっているが、各ステップの中身（子コンポーネント配置・ハンドラ）は Day4-2 以降で埋める:
   ```tsx
   type ChatStep = 'selectCategory' | 'pickProblem' | 'freeformInput' | 'showCandidates';

   export default function ChatPage() {
     const { slug } = useParams<{ slug: string }>();

     // 画面の型: 1 セッション = 1 state machine。React state に持つ。
     // この型と遷移が後続日の差し込み口。ステップ名は自分で確定させる（Day2/Day3 で追加）
     const [step, setStep] = useState<ChatStep>('selectCategory');

     // 各ステップ間で持ち回す状態。何を保持すべきかは「Day 2 への引き継ぎメモ」を参照して自分で決める
     const [categoryId, setCategoryId] = useState<string | null>(null); // null = 「わからない」（全件フォールバック）
     const [query, setQuery] = useState(''); // ③ 自然言語入力の本文
     // 候補リスト・確定 KnowledgeEntry など、後続で必要になる状態フィールドは自分で追加

     return (
       <div>
         <h1>Help desk</h1>
         {step === 'selectCategory' && (
           {/* ここを自分で実装: Day4-2 の <CategoryPicker> を置き、選択ハンドラを結線 */}
         )}
         {step === 'pickProblem' && (
           {/* ここを自分で実装: Day4-3 の <ProblemCombobox> を置く */}
         )}
         {step === 'freeformInput' && (
           {/* Day4-4（AI）で自然言語入力を結線 */}
         )}
         {step === 'showCandidates' && (
           {/* Day4-5 のエスカレーション分岐へ */}
         )}
       </div>
     );
   }
   ```
2. React Router のルート（`apps/web/src/router.tsx`）に `/t/:slug/chat` を追加し、認証ガード HOC で保護する（Sprint 1 day3 と同じ作法）。
3. サイドバーやヘッダにチャットへ戻るリンクを足す程度に留める（CRUD との統合は範囲外）。
4. tenant_id は **クライアントから受け取らない**。書き込み時は Node API の `AsyncLocalStorage` 経由のテナント文脈から取る（Sprint 1 day3 と同じ作法）。読み取りは RLS が絞る。

**完了確認**
- [ ] 認証なしで `/t/:slug/chat` → ログイン誘導
- [ ] 別テナントの slug → 403（middleware の仕事）
- [ ] `step` を手で書き換えると対応する空ステップに切り替わる（型が機能している）

**詰まったら**
- ボタンを押しても再描画されない → `setState` の呼び出しが非同期コールバック外になっていないか確認
- テナント文脈が undefined → `/t/:slug/...` パターン外で呼ばれている／middleware 順序（Sprint 1 day3 の「詰まったら」参照）

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day4-2. カテゴリ選択 UI（ボタン式、「わからない」で全件フォールバック）[自分] [FE]

**目的**
フロー①（[`05:5-8`](../05_search_classification.md)）。カテゴリをボタンで選ばせ、選択した `categoryId` を以降の検索スコープにする。「わからない」を押したら `categoryId = null`（= 全件検索フォールバック）にする。この「わからない → 全件」の分岐が後段の検索品質に効く判断点なので自分で書く。

**自分で書く理由**
「わからない＝categoryId を絞らない」という仕様上の意味づけは設計判断。分類エンドポイント側が `categoryId?` を nullable で受ける契約（[`sprint2_plan.md:6`](../sprint2_plan.md)）と整合させる責任を自分が負う。

**前提確認**
- [ ] Day4-1 完了
- [ ] [`05:5-8`](../05_search_classification.md)（「わからない」で全件フォールバック）を読んだ

**手順**
1. `apps/web/src/components/CategoryPicker.tsx` を新規作成（再利用部品）。子→親の通知に `onSelected: (id: string | null) => void` を使う最初の部品なので、props 型と骨格だけ示す。中身は自分で実装する:
   ```tsx
   type Props = {
     onSelected: (categoryId: string | null) => void;
   };

   export function CategoryPicker({ onSelected }: Props) {
     const [categories, setCategories] = useState<Category[] | null>(null);

     useEffect(() => {
       // ここを自分で実装: GET /api/categories を fetch。sortOrder 昇順で setCategories
       // tenant_id は Authorization ヘッダで渡す（Node API が RLS に流す）
     }, []);

     // ここを自分で実装:
     // - categories が null ならローディング表示
     // - 各カテゴリを <button onClick={() => onSelected(c.id)}> で並べる（c.emoji + c.name）
     // - 末尾に「わからない」ボタンを置き、押下で onSelected(null) を呼ぶ
   }
   ```
   ヒント: `WHERE tenant_id` は書かない（Node API が RLS に流す）。並び順は `category.sortOrder`。
2. `ChatPage.tsx` で `<CategoryPicker onSelected={handleCategorySelected} />` を `selectCategory` ステップに置き、ハンドラで `setCategoryId` を保存して `setStep('pickProblem')` に進める（ハンドラ本体も自分で書く）。

**完了確認**
- [ ] 自テナントのカテゴリのみボタン表示（RLS 目視確認）
- [ ] カテゴリ押下 → `categoryId` がセットされ次ステップへ
- [ ] 「わからない」押下 → `categoryId === null` で次ステップへ

**詰まったら**
- 全テナントのカテゴリが見える → Node API の RLS 設定が効いていない（Sprint 1 Day2-4 へ）

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day4-3. コンボボックス（カテゴリ内問題名の入力フィルタ可能ドロップダウン）[自分（最初の1個）] [FE]

**目的**
フロー②（[`05:9-13`](../05_search_classification.md)）。選んだカテゴリ内の `KnowledgeEntry.name` を入力でフィルタできるドロップダウンにする。選択 → 即確定（`match_strategy=dropdown` 相当）。末尾に「該当なし／見つからない」項目を置き、それを選んだらフロー③（自然言語入力）に落とす。**入力フィルタ + 候補確定 + フォールバック導線**を持つ最初の 1 個を自分で書き、型ができたら他の入力部品は AI 複製可能にする。

**自分で書く理由**
コンボボックスは「入力でフィルタ」「選択で確定」「該当なしで自然言語へ落とす」の 3 挙動を 1 部品に同居させる。この挙動の境界（いつ確定 / いつ ③ へ）が分類フローの分岐そのもの。最初の 1 個の型は自分で握る。

**前提確認**
- [ ] Day4-2 完了
- [ ] [`05:9-13`](../05_search_classification.md)（コンボボックス／「該当なし」で ③ へ）を読んだ

**手順**
1. `apps/web/src/components/ProblemCombobox.tsx`。「入力フィルタ / 選択で確定 / 該当なしで③へ」の 3 挙動を 1 部品に同居させる最初の型。props 型と枠だけ示すので、フィルタ・読み込み・確定/フォールバックの中身は自分で実装する:
   ```tsx
   type Props = {
     categoryId: string | null; // null = 全件（「わからない」経由）
     onSelected: (entry: KnowledgeEntry) => void;
     onFallback: () => void;
   };

   export function ProblemCombobox({ categoryId, onSelected, onFallback }: Props) {
     const [filter, setFilter] = useState('');
     const [entries, setEntries] = useState<KnowledgeEntry[]>([]);

     useEffect(() => {
       // ここを自分で実装: GET /api/knowledge-entries?categoryId=... を fetch。
       //   categoryId が非 null のときだけクエリパラメータで絞り、null なら全件。
       //   name 昇順で setEntries（tenant_id は書かない＝RLS）
     }, [categoryId]);

     // 入力フィルタ: filter が空なら全件、そうでなければ name の部分一致（大文字小文字無視）
     const filtered = filter
       ? entries.filter(e => e.name.toLowerCase().includes(filter.toLowerCase()))
       : entries;

     // ここを自分で実装:
     // - <input> を filter にバインド（onChange で setFilter）
     // - filtered の結果を <li onClick={() => onSelected(k)}> で列挙（= dropdown 確定）
     // - 末尾に「該当なし / 見つからない」項目を置き、クリックで onFallback()（= ③ 自然言語へ）
   }
   ```
2. `ChatPage.tsx`:
   - `onSelected` → 確定。Day4-5 のエスカレーション分岐（`setStep('showCandidates')` で確定 1 件として扱う）に渡す。`match_strategy="dropdown"` を後で `Inquiry` に記録する前提で state に持っておく。
   - `onFallback` → `setStep('freeformInput')`。

**完了確認**
- [ ] カテゴリ選択後、その配下の問題名だけがリストに出る（「わからない」経由なら全件）
- [ ] 入力で部分一致フィルタが効く
- [ ] 問題名クリック → 確定ステップへ
- [ ] 「該当なし」クリック → 自然言語入力ステップへ

**詰まったら**
- カテゴリを変えてもリストが古いまま → `useEffect` の依存配列に `categoryId` を入れていない（`categoryId` 変化に追従）

**AI 依頼テンプレ**: なし（自分で書く範囲。フィルタ強化や仮想化が必要になったら Day4-4 以降で AI に依頼）

---

## Day4-4. 自然言語入力 → 分類エンドポイント結線 [AI] [FE] [BE]

**目的**
フロー③（[`05:15-24`](../05_search_classification.md)）。利用者の自由入力テキストを Node API の分類エンドポイントに渡し、返ってきた候補（ランク済み `KnowledgeEntry` + `match_strategy` + `confidence_score`）を画面に出すところまで結線する。検索ロジック本体は Sprint 2 実装を**呼ぶだけ**で作り直さない。

**前提確認**
- [ ] Day4-3 完了
- [ ] 分類エンドポイントのシグネチャを実機で確認（パス・リクエスト型・レスポンス型）。AI 依頼テンプレの該当箇所を実物に合わせて書き換えてから渡す

**AI 依頼テンプレ**
```
apps/web/src/pages/chat/ChatPage.tsx の freeformInput ステップを実装してほしい。

前提（実機で確認した実物に合わせて）:
- Sprint 2 の分類エンドポイント（apps/api/src/classify/ にある成果物）を Node API 経由で呼ぶ。
  POST /api/classify に { query: string, categoryId?: string } を渡すと、
  ランク済み候補リスト + match_strategy + confidence_score が返る。
  ※ 正確なパス・リクエスト型・レスポンス型は実物を確認して合わせること。内部実装は触らない。

要件:
- <textarea> で自然言語入力 + 「検索」ボタン
- ボタンで fetch（AbortController で中断可能）して分類エンドポイントを呼ぶ
- 呼び出し中はボタン無効化 + "Searching..." 表示
- 返った候補を ChatPage の state に格納し、step を 'showCandidates' へ
- 候補 0 件 or 全候補が閾値未満の場合は、Day4-12 で作る「新規問題として」導線に落とせるよう、
  step を分けて該当なしフラグを立てる
- match_strategy / confidence_score / categoryId / rawQuery は後続(Day4-9 確認画面・起票)で Inquiry に保存するため、
  ChatPage の state に保持しておく
- fetch エラー / HTTP エラーはユーザーにトースト表示し、state を戻す

制約:
- テナント文脈は Authorization ヘッダで Node API に渡す（クライアントから tenant_id を直接送らない）
- secret / API キーをログや state に出さない
```

**自分の確認ポイント**
- [ ] 入力 → 検索 → 候補が画面に出る
- [ ] LLM フォールバック（⑥）は本 Sprint では結線しない。⑤ で該当なしなら ⑦（未分類キュー、Day4-12）に直結する設計になっているか（[`sprint4_plan.md:89`](../sprint4_plan.md)）
- [ ] `fetch` が適切に中断（コンポーネントアンマウント時に AbortController）されている

---

## Day 1 終了チェックリスト

- [ ] `/t/:slug/chat` がカテゴリ選択 → コンボボックス → 自然言語入力の 3 ステップで遷移する
- [ ] 「わからない」で `categoryId=null`、「該当なし」で自然言語入力へ落ちる
- [ ] 自然言語入力 → 分類エンドポイント → 候補が画面に出る（検索本体は呼ぶだけ）
- [ ] `ChatStep` 型と子コンポーネント（`CategoryPicker` / `ProblemCombobox`）の型が確立し、Day2 のエスカレーション分岐を差し込める状態

## Day 2 への引き継ぎメモ

- 確定した `KnowledgeEntry`（dropdown 確定 or 候補選択）を 1 つに収束させる state を `ChatPage.tsx` に用意した。Day2 はその `autoResolution` / `guidanceMessage` の有無で 3 分岐する。
- `match_strategy` / `confidence_score` / `rawQuery` / `categoryId` を保持済み。Day3 の `Inquiry` 保存で使う。
