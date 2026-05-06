# Life Update Radio パイプライン インターフェース仕様書

バージョン: 1.4.0
作成日: 2026-04-26
最終更新: 2026-05-03
ステータス: 確定（Phase 2 リサーチ側 + Hybrid ベンチマーク + Phase 3 structured_facts 台本側参照を実装完了 / GX10 推論インフラ確定）

---

## 0. 全体像

```
[リサーチパイプライン] (Mac Studio / research_pipeline)
  ↓ research_brief.json を生成
[台本生成パイプライン] (auto_radio_generator)
  ↓ script.json を生成
[放送]
```

### 0.1 情報フロー（台本側調査で判明した実態）

```
research_content（全文）
  ↓ 全文投入
  ├─→ FactExtractor (qwen3:8b)
  │     → FactSheet { facts[], theme_summary }
  │
  └─→ TopicCurator (qwen3:8b)
        → CurationResult { topics[2-3件] }
        各topic: title / content(500-800字) / key_facts[3-5件]
        ※ここで18,000字→約2,000字に圧縮（6〜9倍）
              ↓
        SegmentGenerator（台本生成）
        ※research_contentを直接参照しない
              ↓
        台本完成
```

**重要**: research_contentの品質が台本品質を決定する最大の要因

### 0.2 推論インフラ構成（2026-05-03 確定）

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│ Mac Studio                  │         │ GX10 (192.168.0.73)          │
│  ├ Ollama (port 11434)      │         │  └ vLLM (port 8000)          │
│  │   └ deepseek-r1:14b      │         │      └ Qwen3-Next-80B-A3B-   │
│  │     [Pass1]              │         │        Instruct-NVFP4        │
│  │                          │         │        served-model-name:    │
│  └ Mac Studio Proxy         │ ──────▶ │        qwen3-next-80b        │
│    (port 11435)             │ Ollama  │        [Pass2 / Pass3]       │
│    Ollama→OpenAI 変換ブリッジ │ 形式 →   │                              │
│                             │ OpenAI  │                              │
│                             │ 形式    │                              │
└─────────────────────────────┘         └──────────────────────────────┘
```

**役割分担**:

| ステージ | モデル | エンドポイント | プロトコル |
|---|---|---|---|
| stage1 / stage3_pass1 | `deepseek-r1:14b` | Mac Studio `localhost:11434` (Ollama 直叩き) | Ollama 形式 |
| stage3_pass2 / stage3_pass3 | `Qwen3-Next-80B-A3B-Instruct-NVFP4` (`served-model-name: qwen3-next-80b`) | Mac Studio Proxy `localhost:11435` → GX10 `192.168.0.73:8000` (vLLM) | クライアントは Ollama 形式 / Proxy が OpenAI 形式 (`/v1/chat/completions`) に変換して GX10 vLLM へ転送 |

**ポート規約**:
- vLLM: port 8000 （GX10 側）
- Ollama: port 11434 （Mac Studio 側 / GX10 側ともに従来 Ollama を使う場合は同一）
- Mac Studio Proxy: port 11435 （vLLM 変換ブリッジ）

**ブリッジの役割**: 既存のリサーチパイプラインは Ollama 互換 API を呼び出す前提で実装済み。
Proxy (port 11435) が `/api/chat` 等の Ollama 形式リクエストを受けて OpenAI 形式 (`/v1/chat/completions`) に
変換し、GX10 の vLLM (port 8000) に転送する。これにより既存コードを書き換えずに NVFP4 量子化された
80B モデルを利用できる。

---

## 1. research_brief.json フィールド仕様

### 1.1 フィールド使用状況（調査確定）

| フィールド | 型 | 台本側での使用 | リサーチ品質への影響 |
|---|---|---|---|
| theme | str | ✅ 全エージェントに伝播 | - |
| research_mode | str | ✅ プロンプトに反映 | - |
| research_content | str | ✅ **最重要・全文投入** | - |
| research_sources | List[dict] | △ title+urlのみMetadataGeneratorが参照 | - |
| angle | str | ❌ 現状未使用 | ✅ アウトライン構成に影響 |
| queries | List[str] | ❌ 現状未使用 | ✅ ソース品質・数値密度に影響 |
| session_id | str | △ ログのみ | - |
| created_at | str | ❌ 未使用 | - |

### 1.2 research_content の品質基準

| 指標 | 現状 | 目標（v1.0） | 目標（v2.0） |
|---|---|---|---|
| 文字数 | 8,000〜9,000字 | 15,000字以上 | 20,000字以上 |
| 統計値・数値の個数 | 少ない | 50個以上 | 100個以上 |
| 引用番号[N]の個数 | 少ない | 50個以上 | 80個以上 |
| 空セクション数 | 0〜1個 | 0個 | 0個 |
| AAA+AAソース率 | テーマ依存 | 50%以上 | 70%以上 |

**根拠**: TopicCuratorが6〜9倍圧縮するため、入力が豊富なほど
圧縮後の2,000字に重要情報が残りやすい。

### 1.3 research_sources の品質基準

| フィールド | 現状 | 目標 |
|---|---|---|
| title | ✅ あり | 維持 |
| url | ✅ あり | 維持 |
| snippet | ❌ null | **有効化必須**（台本側が引用文を参照できない） |
| domain_score | ✅ あり | 維持 |
| domain_tier | ✅ あり | 維持 |
| citation_id | ❌ なし | 追加推奨（content内の[N]との紐付け） |

---

## 2. angleとqueriesの役割

### 2.1 angle

```
リサーチへの影響:
  Stage1のアウトライン生成に使用
  → セクション構成・掘り下げ方向が変わる
  → research_contentの内容・構成が変わる
  → TopicCuratorが圧縮する材料が変わる
  → 間接的に台本品質に影響

台本への影響:
  現状: 未使用（ResearchResult変換時に破棄）
  対応予定: angleをResearchResult経由で
           TopicCurator/SegmentGeneratorまで伝播（台本側タスク）

品質基準:
  - 50字以内
  - 番組コンセプトが明確に伝わること
  - 例: 「睡眠不足で免疫力がこんなに低下する！？」
```

### 2.2 queries

```
リサーチへの影響:
  クエリの質がソースの質を決定する
  → 良いクエリ = 高品質ソースの収集
  → 高品質ソース = 数値・固有名詞の豊富な本文
  → 豊富な本文 = research_contentの数値密度向上
  → 数値密度向上 = TopicCurator圧縮後も数値が残る

品質基準（Phase 1-A実装後）:
  - 5件（日本語3件+英語2件）+ AAA強化2件 = 7件
  - キーワード列挙ではなく質問文型
  - 期待するデータ型を明記
  - 期間制約を含む（直近3年優先）
  - ソースタイプを明記（RCT/メタアナリシス等）
```

---

## 3. structured_facts フィールド（Phase 2 リサーチ側 + Phase 3 台本側 参照 実装済み）

台本側調査で判明した最大の課題は「情報の圧縮損失」です。
これを解決するためにresearch_brief.jsonに構造化ファクトを追加しました。
Phase 2（リサーチ側）で実装完了、Phase 3（台本側参照）も
2026-05-02 に実装完了しました（§3.4 / §5 Phase 3 参照）。

### 3.1 structured_facts フィールド定義

```json
{
  "structured_facts": {
    "key_numbers": [
      {
        "value": "2.94",
        "unit": "倍",
        "context": "睡眠不足者の感染率は充分な睡眠者の2.94倍",
        "source_idx": 3
      }
    ],
    "key_entities": [
      {
        "name": "慶應義塾大学医学部",
        "type": "institution",
        "role": "腸内細菌と精神疾患の関連研究機関",
        "source_idx": 1
      }
    ],
    "surprising_claims": [
      {
        "statement": "睡眠不足のマウスは5日で免疫細胞が40%減少",
        "why_surprising": "短期間でこれほど急激に低下するとは思われていなかった",
        "source_idx": 7
      }
    ],
    "controversies": [
      {
        "position_a": "8時間睡眠が最適",
        "position_b": "質が高ければ6時間で十分",
        "source_indices": [2, 5]
      }
    ]
  }
}
```

### 3.2 structured_factsの期待効果

```
現状:
  FactExtractor（台本側）が
  research_contentから毎回ファクト抽出
  → facts=[]が頻発（qwen3:8bの限界）

改善後:
  リサーチ側がより高精度に抽出して永続化
  → TopicCuratorが直接参照可能
  → 引用番号とソースの紐付けが保持
  → SegmentGeneratorが「〇〇大学の研究によると2.94倍」と言える
```

### 3.3 品質基準（Phase 2 実装後の実測値）

2026-04-28 時点のリサーチ側テスト実行結果:

```
テーマ: 「睡眠と免疫」 / mode=lecture
ソース数: 20件 / Pass1 成功: 19件
所要時間: 24分41秒
```

| サブフィールド | 1回の実行で取得できた件数 | v1.0 目標（最低基準） | v2.0 目標 |
|---|---|---|---|
| key_numbers | 9 件 | 5 件以上 | 15 件以上 |
| key_entities | 10 件 | 5 件以上 | 15 件以上 |
| surprising_claims | 3 件 | 2 件以上 | 5 件以上 |
| controversies | 4 件 | 1 件以上 | 3 件以上 |

**判定**:
- 全サブフィールドが v1.0 最低基準を一発でクリア
- ソース20件で key_numbers 9件 = 平均 0.45 件/ソース
- 引用番号 (`source_idx`) も全件付与され、TopicCurator から元ソースを辿れる状態

**未達成**:
- research_content は 7,096 文字（v1.0 目標 15,000 字には未達）
- Pass3 補完が 3 回試行されても 8,000 字に届かず → 別途要改善

#### 3.3.1 Hybrid 構成 (Pass1=deepseek-r1:14b / Pass2/3=qwen2.5:72b) のベンチマーク

2026-05-01 時点。`config.OLLAMA_ENDPOINTS` で stage_key 単位に振り分け:
- stage1 / stage3_pass1: Mac Studio ローカルの deepseek-r1:14b 直接呼出
- stage3_pass2 / stage3_pass3: Proxy (port 11435) 経由で GX10 (192.168.0.73:11434) の qwen2.5:72b に転送

同一テーマ・同一 angle (「睡眠と免疫」 / mode=lecture / angle=「睡眠不足で免疫力がこんなに低下する」) で 3 構成を実測:

| 指標 | deepseek-r1:14b 単独 | qwen2.5:72b 単独 | **Hybrid** | v1.0 目標 | v2.0 目標 |
|---|---:|---:|---:|---:|---:|
| 実行時間 | 24分41秒 | 69分01秒 | **51分21秒** | — | — |
| research_content 文字数 | 7,096 | 10,136 | **9,879** | 15,000 | 20,000 |
| ソース数 | 20 | 20 | 25 | — | — |
| key_numbers | 9 | 8 | **14** | 5 以上 | 15 以上 |
| key_entities | 10 | 1 | **6** | 5 以上 | 15 以上 |
| surprising_claims | 3 | 4 | **3** | 2 以上 | 5 以上 |
| controversies | 4 | 0 | **6** | 1 以上 | 3 以上 |

**判定**:
- Hybrid 構成は key_numbers / key_entities / surprising_claims / controversies の全項目で v1.0 最低基準をクリア
- key_numbers 14 件は v2.0 目標 (15 件以上) の直前まで到達。controversies 6 件は v2.0 目標 (3 件以上) を超過
- qwen2.5:72b 単独で発生していた構造化ファクトの崩壊 (key_entities=1, controversies=0) を Pass1 を deepseek-r1:14b に切り替えることで回避
- 実行時間は qwen2.5:72b 単独比で −1,060 秒 (−25%) の改善。長文生成ボリュームは qwen2.5:72b 単独 (10,136 字) とほぼ同水準を維持

**役割分担の根拠**:
- 構造化抽出 (Pass1): JSON 出力の安定性と固有名詞・数値の網羅性で deepseek-r1:14b が優位
- 長文生成 (Pass2/3): 文章の流暢さ・セクション構成の一貫性で qwen2.5:72b が優位

#### 3.3.2 Qwen3-Next-80B ベンチマーク確定値 (2026-05-03)

§0.2 の確定インフラ構成 (Pass1=deepseek-r1:14b @ Mac Studio Ollama / Pass2/3=Qwen3-Next-80B-A3B-Instruct-NVFP4 @ GX10 vLLM) で、§3.3.1 と同一のテーマ・angle (「睡眠と免疫」 / mode=lecture) を実測:

| 指標 | Hybrid (qwen2.5:72b) | **Hybrid (Qwen3-Next-80B)** | v1.0 目標 | v2.0 目標 |
|---|---:|---:|---:|---:|
| 実行時間 | 51分21秒 | **17分34秒** | — | — |
| research_content 文字数 | 9,879 | **17,409** | 15,000 | 20,000 |
| key_numbers | 14 | **21** | 5 以上 | 15 以上 |

**判定**:
- research_content 17,409 字は v1.0 目標 (15,000 字) を 2,409 字 (約 16%) 超過。v2.0 目標 (20,000 字) まで残り 2,591 字
- key_numbers 21 件は v2.0 目標 (15 件以上) を 6 件超過
- 実行時間 17分34秒は qwen2.5:72b Hybrid 比で −2,027 秒 (−66%)。NVFP4 量子化と vLLM の連続バッチング・PagedAttention により大幅短縮
- v1.0 目標 (15,000 字) を初めて単体実行で突破した構成。これをもって Phase 2 の文字数未達課題 (§5 Phase 2 の "文字数は 7,096 字に留まり目標未達 → 継続改善") は実質解消

**今後の主戦構成**: 本構成 (Pass1=deepseek-r1:14b / Pass2/3=Qwen3-Next-80B) を当面のデフォルトとして運用する。

### 3.4 台本側実装（Phase 3 / 2026-05-02 完了）

リサーチ側が出力する `structured_facts` を、台本側 `auto_radio_generator` が
ScriptOrchestrator Step 0.5 で読み取り、`FactExtractor` を完全にスキップして
`FactSheet` を直接生成し `TopicCurator` に渡す経路を実装。

**実装内容**:

- `core/models/artifacts.py`: `ResearchBrief.structured_facts: Optional[Dict[str, Any]]`
  を追加（Pydantic Optional・既定 None で後方互換維持）
- `core/models/fact_sheet.py`: `FactSheet.from_structured_facts(dict) -> FactSheet`
  クラスメソッドを新設
- `core/interfaces/researcher.py`: `ResearchResult` dataclass に `structured_facts`
  フィールドを追加（`research_brief → research_data` の搬送経路）
- `services/pipeline/scripting_phase.py`: ResearchResult 構築点で伝播
- `services/script_generation/orchestrator.py` Step 0.5: 優先順位を整理
  1. `preset_fact_sheet`（HITL 編集済み） > 即採用
  2. `research_data.structured_facts`（リサーチ側事前抽出）> `from_structured_facts`
     で変換し FactExtractor をスキップ
  3. `fact_extractor.enabled` かつ Curator が走る場合 > FactExtractor 実行
  4. それ以外 > `fact_sheet=None`

**変換マッピング**（interface_spec.md 3.1 → ExtractedFact）:

| structured_facts のサブフィールド | FactCategory | surprise_score | source 引用保持 |
|---|---|---|---|
| `key_numbers` | 数値 | 7 | `source_idx` → `[N]` 形式で `source_citation` |
| `key_entities` | type で分岐（人物 / 定義 / 技術 / イベント / その他） | 5 | 同上 |
| `surprising_claims` | その他 | 9 | 同上 |
| `controversies` | 比較 | 7 | `source_indices` → `[N,M]` 形式 |

**実機検証**（2026-05-02 / Ollama qwen3:32b）:

| 検証項目 | 結果 |
|---|---|
| Step 0.5 で structured_facts → FactSheet 変換 | ✅ ログに「FactExtractor スキップ」「FactSheet 構築 (facts=13)」 |
| FactExtractor LLM 呼び出し回数 | ✅ ゼロ（合成 structured_facts 13 件 → そのまま FactSheet 13 件） |
| TopicCurator が選定したトピックに数値含有 | ✅ 3 トピックすべてに数値（20% / 18% vs 25% / 5%・1.5倍） |
| 台本本文 43 ターン中の数値・固有名詞 | ✅ 数値 41 個、BMI 4 回、HIIT 4 回、アディポ 3 回 等 |
| `facts=[]` 系エラー発生 | ✅ ゼロ |

**失敗時の挙動**: `from_structured_facts` 変換中に例外が出た場合は、防御的に
FactExtractor へフォールバック（後方互換維持）。`structured_facts=None` /
不在の場合も従来通り FactExtractor を実行する。

**Hybrid 構成（§3.3.1）との関係**: Hybrid 構成は **リサーチ側で structured_facts を
高精度に生成する**手段、Phase 3（§3.4）は**それを台本側で消費する**経路。両者が揃って
初めて facts=[] の根本原因（小型モデル依存のファクト抽出失敗）が構造的に解消される。

---

## 4. 両者の合意事項

### 4.1 変更時のルール

```
フィールドの追加・変更・削除を行う場合:
1. この仕様書を先に更新する
2. 相手のAIに共有する
3. 両方が対応してからリリース
4. バージョン番号を上げる
```

### 4.2 互換性の保持

```
フィールドの追加: Optional[型]で追加
                  既存コードへの影響なし
フィールドの削除: 最低1バージョン前から非推奨宣言
フィールドの変更: 原則禁止・新フィールドとして追加
```

### 4.3 品質判定の責任分担

```
リサーチ側が保証する指標:
  - research_contentの文字数
  - AAA+AAソース数
  - 統計値・数値の個数
  - 空セクション数
  - snippetの有無

台本側が評価する指標:
  - TopicCuratorが圧縮後も数値が残っているか
  - key_factsに固有名詞が含まれているか
  - surprising_claimsが台本のフックに使われているか
```

---

## 5. ロードマップ

### Phase 1（実装中）: 即効・小コスト
```
✅ クエリ質問文化（1-A）
✅ must_coverスロット化（1-C）
✅ 統計密度フィルタ（2-B）
✅ 引用明示化（3-D）
期待効果: 数値密度向上・クエリ精度向上
```

### Phase 2（実装完了 2026-04-28）: 基盤改修・本丸
```
[x] Pass1を構造化ファクト抽出に変更
[x] structured_factsフィールドの新設
[x] Pass2をセクション別逐次生成に変更
[x] Pass3をファクトカバレッジ判定に変更
期待効果: 文字数20,000字・数値密度大幅向上
実測効果: structured_facts は §3.3 の通り基準クリア
         文字数は 7,096 字に留まり目標未達 → 継続改善
```

### Phase 3（台本側対応）
```
[ ] angleをResearchResult経由で伝播
[x] structured_factsをTopicCuratorに渡す（2026-05-02 実装完了 / §3.4 参照）
[ ] snippetを有効化
期待効果: 番組コンセプトの全層伝達・引用追跡
実測効果: structured_facts 経路は実機検証で facts=[] ゼロ・数値固有名詞含む
         台本生成を 1 本完走（§3.4 末尾の検証表）
```

### Phase 4（拡張）
```
[ ] PubMed/arxiv API拡充
[ ] 反復検索（穴埋め）
[ ] 出力検証エージェント
期待効果: Perplexityを超える日本語特化リサーチ
```

---

## 6. バージョン履歴

| バージョン | 日付 | 変更内容 |
|---|---|---|
| 0.1.0 | 2026-04-26 | 骨子作成（ドラフト） |
| 1.0.0 | 2026-04-26 | 台本側調査結果を反映・全文更新 |
| 1.1.0 | 2026-04-28 | Phase 2 実装完了を反映。§3.3 にリサーチ側テスト実測値（key_numbers=9 / key_entities=10 / surprising_claims=3 / controversies=4）を追記 |
| 1.2.0 | 2026-05-01 | §3.3.1 を新設し Hybrid 構成 (Pass1=deepseek-r1:14b / Pass2/3=qwen2.5:72b) のベンチマーク実測値を追加。3 構成 (deepseek 単独 / qwen 単独 / Hybrid) の比較表を反映 |
| 1.3.0 | 2026-05-03 | Phase 3 のうち「structured_facts を TopicCurator に渡す」が台本側で実装完了。§3.4 を新設し台本側実装内容（ResearchBrief / FactSheet / ScriptOrchestrator Step 0.5 の変更点・変換マッピング・実機検証結果）を追記。§5 Phase 3 のチェックボックスを更新。残タスク（angle 伝播・snippet 有効化）は引き続き未実装。注: 元々 2026-05-02 に commit 69d0a45 として一度仕様書に反映していたが、リサーチ側 v1.2.0 (commit c05b993) が 69d0a45 を上書きする形で進められたため、本コミットで §3.3.1 (Hybrid) と §3.4 (Phase 3) を改めて統合 |
| 1.4.0 | 2026-05-03 | §0.2 を新設し GX10 推論インフラを確定 (vLLM port 8000 / Ollama port 11434 / Mac Studio Proxy port 11435 が Ollama 形式→OpenAI 形式に変換して GX10 vLLM へ転送 / Pass1=deepseek-r1:14b @ Mac Studio Ollama / Pass2/3=Qwen3-Next-80B-A3B-Instruct-NVFP4 @ GX10 vLLM, served-model-name=qwen3-next-80b)。§3.3.2 を新設し Qwen3-Next-80B 構成のベンチマーク確定値を反映 (実行時間 17分34秒 / research_content 17,409 字 / key_numbers 21 件)。research_content が初めて v1.0 目標 (15,000 字) を単体実行で突破し、key_numbers は v2.0 目標 (15 件以上) を超過 |
| 1.5.0 | 2026-05-06 | §7（ベンチマーク基準値）・§8（Variance 観測）・§9（推奨ベンチマークテーマ）を新設。リサーチ側 `benchmark_themes.py` (5 テーマ × repeat 3 = 15 ラン) の実測値: 平均 17 分 7 秒 / research_content 27,565 字 / key_numbers 23.7 件 / KV ピーク 12.3% を基準値として記録。同一テーマ内 σ がテーマ間 σ を上回る observation を踏まえ、設定変更比較には repeat=5 以上を推奨。最も安定したテーマ「睡眠と免疫」(σ=6.7 秒) を新規設定変更の効果検証時の優先テーマに指定 |

---

## 7. ベンチマーク基準値（2026-05-06 実施）

リサーチ側 `benchmark_themes.py` を用いた **5 テーマ × repeat 3 = 15 ラン** の実測値。並列度は Pass1=8 / Pass2=5 構成（vLLM proxy 経由で `qwen3.5-122b` を使用）。今後の設定変更比較におけるベースラインとして本値を参照する。

| 指標 | 平均 |
|---|---|
| 全体実行時間 | **17 分 7 秒** (1,027 秒) |
| `research_content` 文字数 | **27,565 字** |
| `key_numbers` 件数 | **23.7 件** |
| `key_entities` 件数 | **39.4 件** |
| KV キャッシュピーク | **12.3 %** |

完走率は 15/15 (100%)。検証 run の保存先は `benchmark_themes_results/run_20260506_173706/results.csv`。

---

## 8. Variance 観測

§7 のベンチで観察された重要事項として、**同一テーマ内のラン間標準偏差が、テーマ間の標準偏差を上回る** 現象が確認された。

| 観点 | σ |
|---|---|
| テーマ間 σ (テーマ平均値の散らばり) | **103.6 秒** |
| 同一テーマ内 σ の代表値 (例: プラスチック汚染 σ=283.4 / リチウム電池 σ=205.8) | テーマ間 σ を上回るケースが複数 |

→ ラン間ばらつきが支配的な状況では、`repeat=3` では設定変更の効果サイズを統計的に確定しにくい。**今後の設定変更比較には repeat=5 以上を推奨**。`benchmark_themes.py` の `--repeat` 引数で調整可能。

```bash
venv/bin/python benchmark_themes.py --repeat 5   # 5 テーマ × 5 = 25 ラン (約 7.5 時間)
```

---

## 9. 推奨ベンチマークテーマ

§8 の variance 観測において、テーマ別の duration σ は次のとおり:

| # | テーマ | duration σ |
|---|---|---|
| 1 | **睡眠と免疫** | **6.7 秒** ← 最も安定 |
| 2 | 量子コンピューティングの実用化 | 111.0 秒 |
| 3 | 認知行動療法のうつ病への効果 | 103.7 秒 |
| 4 | プラスチック汚染の海洋生態系への影響 | 283.4 秒 |
| 5 | リチウムイオン電池のリサイクル | 205.8 秒 |

**「睡眠と免疫」が最も安定した variance を示している (σ=6.7 秒)** ため、新規設定変更の効果検証時はこのテーマを優先利用すること。並列度・モデル・閾値などの A/B 比較は、まず「睡眠と免疫」で 5 ラン以上を取り、その後に他テーマで一般化検証するのが効率的。
