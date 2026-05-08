Life Update Radio パイプライン インターフェース仕様書
バージョン: 1.7.0 作成日: 2026-04-26 最終更新: 2026-05-09 ステータス: 確定（v1.6 実装完了 / 実機データ検証済 2026-05-07 / vLLM 設定詳細追記 2026-05-08 / radio_director Step 1 SSOT 化反映 2026-05-09）

0. 全体像
[リサーチパイプライン] (Mac Studio / research_pipeline)
  ↓ research_brief.json を生成
[台本生成パイプライン] (auto_radio_generator / radio_director [新])
  ↓ script.json を生成
[放送]

注: 2026-05-07 時点で台本生成パイプラインは2系統:
  - auto_radio_generator (Windows): 既存実装、フォールバックとして本運用継続
  - radio_director (Mac Studio): 新規ゼロベース構築中、structured_facts 主軸設計
  詳細は §10 を参照。

0.1 情報フロー（台本側調査で判明した実態）
research_content（全文）
  ↓ 全文投入
  ├─→ FactExtractor (qwen3:8b)  ← radio_director では廃止予定
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
重要: research_contentの品質が台本品質を決定する最大の要因

0.2 推論インフラ構成（2026-05-03 確定）
┌─────────────────────────────┐         ┌──────────────────────────────┐
│ Mac Studio                  │         │ GX10 (192.168.0.73)          │
│  ├ Ollama (port 11434)      │         │  └ vLLM (port 8000)          │
│  │   └ deepseek-r1:14b      │         │      └ Qwen3.5-122B-A10B-    │
│  │     [Pass1]              │         │        NVFP4                 │
│  │                          │         │        served-model-name:    │
│  └ Mac Studio Proxy         │ ──────▶ │        qwen3.5-122b-a10b     │
│    (port 11435)             │ Ollama  │        [Pass2 / Pass3]       │
│    Ollama→OpenAI 変換ブリッジ │ 形式 →   │                              │
│                             │ OpenAI  │                              │
│                             │ 形式    │                              │
└─────────────────────────────┘         └──────────────────────────────┘
役割分担:

ステージ	モデル	エンドポイント	プロトコル
stage1 / stage3_pass1	deepseek-r1:14b	Mac Studio localhost:11434 (Ollama 直叩き)	Ollama 形式
stage3_pass2 / stage3_pass3	Qwen3.5-122B-A10B-NVFP4	Mac Studio Proxy localhost:11435 → GX10 192.168.0.73:8000 (vLLM)	クライアントは Ollama 形式 / Proxy が OpenAI 形式 (/v1/chat/completions) に変換して GX10 vLLM へ転送

ポート規約:

vLLM: port 8000 （GX10 側）
Ollama: port 11434 （Mac Studio 側 / GX10 側ともに従来 Ollama を使う場合は同一）
Mac Studio Proxy: port 11435 （vLLM 変換ブリッジ）

ブリッジの役割: 既存のリサーチパイプラインは Ollama 互換 API を呼び出す前提で実装済み。 Proxy (port 11435) が /api/chat 等の Ollama 形式リクエストを受けて OpenAI 形式 (/v1/chat/completions) に 変換し、GX10 の vLLM (port 8000) に転送する。これにより既存コードを書き換えずに NVFP4 量子化された 122B モデルを利用できる。

vLLM サーバー設定（2026-05-08 確認）:

項目	値	備考
モデル能力	256K context	Qwen3.5-122B-A10B-NVFP4 のアーキテクチャ的な最大値
max_model_len	32,768	vLLM 起動時に制限（KV cache 制約のため）
max-num-seqs	8	並列度（ベンチマーク §7 参照）

注意事項:
- モデル自体は 256K まで扱えるが、現在の vLLM 起動設定で 32K に制限
- 32K 制約により、prompt + max_tokens の合計を 32,768 以下に保つ必要がある
- 例: radio_director Phase B では prompt 25,615 tokens + max_tokens 4,096 = 29,711 で運用
- 将来 max_model_len 拡張が必要になった場合は KV cache 容量と並列度のトレードオフを検討

1. research_brief.json フィールド仕様
1.1 フィールド使用状況（調査確定）
フィールド	型	台本側での使用	リサーチ品質への影響
theme	str	✅ 全エージェントに伝播	-
research_mode	str	✅ プロンプトに反映	-
research_content	str	✅ 最重要・全文投入	-
research_sources	List[dict]	△ title+urlのみMetadataGeneratorが参照	-
angle	str	❌ 現状未使用 / radio_director では必須	✅ アウトライン構成に影響
queries	List[str]	❌ 現状未使用	✅ ソース品質・数値密度に影響
session_id	str	△ ログのみ	-
created_at	str	❌ 未使用	-

1.2 research_content の品質基準
指標	現状	目標（v1.0）	目標（v2.0）
文字数	8,000〜9,000字	15,000字以上	20,000字以上
統計値・数値の個数	少ない	50個以上	100個以上
引用番号[N]の個数	少ない	50個以上	80個以上
空セクション数	0〜1個	0個	0個
AAA+AAソース率	テーマ依存	50%以上	70%以上
根拠: TopicCuratorが6〜9倍圧縮するため、入力が豊富なほど 圧縮後の2,000字に重要情報が残りやすい。

1.3 research_sources の品質基準
フィールド	現状	目標
title	✅ あり	維持
url	✅ あり	維持
snippet	❌ null	有効化必須（台本側が引用文を参照できない）
domain_score	✅ あり	維持
domain_tier	✅ あり	維持
citation_id	❌ なし	追加推奨（content内の[N]との紐付け）
publication_date	❌ なし	v1.7+ で追加検討（取得率60-70%想定、optional）

2. angleとqueriesの役割
2.1 angle
リサーチへの影響:
  Stage1のアウトライン生成に使用
  → セクション構成・掘り下げ方向が変わる
  → research_contentの内容・構成が変わる
  → TopicCuratorが圧縮する材料が変わる
  → 間接的に台本品質に影響

台本への影響:
  現状 (auto_radio_generator): 未使用（ResearchResult変換時に破棄）
  radio_director (新): 必須項目、Phase A→B→C で貫通使用
                       再解釈・改善は禁止、研究側の意図をそのまま尊重

品質基準:
  - 50字以内
  - 番組コンセプトが明確に伝わること
  - 例: 「睡眠不足で免疫力がこんなに低下する！？」

2.2 queries
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

3. structured_facts フィールド（Phase 2 リサーチ側 + Phase 3 台本側 参照 実装済み）
台本側調査で判明した最大の課題は「情報の圧縮損失」です。 これを解決するためにresearch_brief.jsonに構造化ファクトを追加しました。 Phase 2（リサーチ側）で実装完了、Phase 3（台本側参照）も 2026-05-02 に実装完了しました（§3.4 / §5 Phase 3 参照）。

3.1 structured_facts フィールド定義（v1.6 拡張）
v1.5.0 から v1.6.0 にかけて、各 claim に confidence・cross_validated_sources・flags の3フィールドを追加します（後方互換維持のため Optional）。

```json
{
  "structured_facts": {
    "key_numbers": [
      {
        "value": "2.94",
        "unit": "倍",
        "context": "睡眠不足者の感染率は充分な睡眠者の2.94倍",
        "source_idx": 3,
        "cross_validated_sources": [3, 12, 18],  // v1.6 新規
        "confidence": "high",                     // v1.6 新規
        "flags": []                               // v1.6 新規
      }
    ],
    "key_entities": [
      {
        "name": "慶應義塾大学医学部",
        "type": "institution",
        "role": "腸内細菌と精神疾患の関連研究機関",
        "source_idx": 1,
        "cross_validated_sources": [1],           // v1.6 新規
        "confidence": "medium",                    // v1.6 新規
        "flags": ["highly_specific"]              // v1.6 新規
      }
    ],
    "surprising_claims": [
      {
        "statement": "睡眠不足のマウスは5日で免疫細胞が40%減少",
        "why_surprising": "短期間でこれほど急激に低下するとは思われていなかった",
        "source_idx": 7,
        "cross_validated_sources": [7],           // v1.6 新規
        "confidence": "medium",                    // v1.6 新規
        "flags": []                               // v1.6 新規
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

3.1.1 v1.6 で追加する3フィールドの仕様

confidence: Literal["high", "medium", "low"]
  high:   cross_validated_sources >= 2（複数ソースで確認できた）
  medium: cross_validated_sources == 1 かつ tier_score >= 60（AAA/AA/A tier）
  low:    それ以外（B tier 単独ソース）

cross_validated_sources: List[int]
  同じ事実を裏付けるソースの source_idx リスト
  既存の source_idx (単数、最初に出現したソース) を補完する形で追加
  後方互換のため source_idx は維持

flags: List[str]
  ハルシネーション特徴等を示すフラグ
  v1.6 で実装するフラグ:
    "highly_specific": 妙に具体的な数値・固有名詞（ハルシネーション特徴）
                       例: 「23.847%」「2,847,193件」のような高精度数値
                       例: 細かすぎる集計値（百万単位の細かい数字）
                       LLMがハルシネーションする時に出やすいパターン
  v1.7+ で議論予定のフラグ:
    "expert_quote":        専門家の発言・引用
    "no_publication_date": 出版日不明
    "outdated":            古い情報

3.1.2 confidence 判定ロジックの実装方針
_merge_structured_facts (stage3_synthesize.py) の修正:

```python
# 重複排除時に「マージされたsourcesリスト」を保持
merged_fact = {
    "value": "...",
    "source_idx": 5,                      # 既存（後方互換のため最初のソース）
    "cross_validated_sources": [5,12,18], # v1.6 新規（全contributing sources）
    "confidence": "high",                 # v1.6 新規（ロジックで決定）
    "flags": ["highly_specific"]          # v1.6 新規（判定ロジックで付与）
}
```

3.2 structured_factsの期待効果
現状:
  FactExtractor（台本側）が
  research_contentから毎回ファクト抽出
  → facts=[]が頻発（qwen3:8bの限界）

改善後（v1.5.0 段階で実装済み）:
  リサーチ側がより高精度に抽出して永続化
  → TopicCuratorが直接参照可能
  → 引用番号とソースの紐付けが保持
  → SegmentGeneratorが「〇〇大学の研究によると2.94倍」と言える

v1.6 でのさらなる改善:
  → 各 claim に confidence が付与される
  → radio_director (新台本生成パイプライン) で
    confidence="low" の claim を引用しない判断が可能に
  → ハルシネーションリスクの構造的削減

3.3 品質基準（Phase 2 実装後の実測値）
2026-04-28 時点のリサーチ側テスト実行結果:

テーマ: 「睡眠と免疫」 / mode=lecture
ソース数: 20件 / Pass1 成功: 19件
所要時間: 24分41秒
サブフィールド	1回の実行で取得できた件数	v1.0 目標（最低基準）	v2.0 目標
key_numbers	9 件	5 件以上	15 件以上
key_entities	10 件	5 件以上	15 件以上
surprising_claims	3 件	2 件以上	5 件以上
controversies	4 件	1 件以上	3 件以上

判定:

全サブフィールドが v1.0 最低基準を一発でクリア
ソース20件で key_numbers 9件 = 平均 0.45 件/ソース
引用番号 (source_idx) も全件付与され、TopicCurator から元ソースを辿れる状態

未達成:

research_content は 7,096 文字（v1.0 目標 15,000 字には未達）
Pass3 補完が 3 回試行されても 8,000 字に届かず → 別途要改善

3.3.1 Hybrid 構成 (Pass1=deepseek-r1:14b / Pass2/3=qwen2.5:72b) のベンチマーク
2026-05-01 時点。config.OLLAMA_ENDPOINTS で stage_key 単位に振り分け:

stage1 / stage3_pass1: Mac Studio ローカルの deepseek-r1:14b 直接呼出
stage3_pass2 / stage3_pass3: Proxy (port 11435) 経由で GX10 (192.168.0.73:11434) の qwen2.5:72b に転送

同一テーマ・同一 angle (「睡眠と免疫」 / mode=lecture / angle=「睡眠不足で免疫力がこんなに低下する」) で 3 構成を実測:

指標	deepseek-r1:14b 単独	qwen2.5:72b 単独	Hybrid	v1.0 目標	v2.0 目標
実行時間	24分41秒	69分01秒	51分21秒	—	—
research_content 文字数	7,096	10,136	9,879	15,000	20,000
ソース数	20	20	25	—	—
key_numbers	9	8	14	5 以上	15 以上
key_entities	10	1	6	5 以上	15 以上
surprising_claims	3	4	3	2 以上	5 以上
controversies	4	0	6	1 以上	3 以上

判定:

Hybrid 構成は key_numbers / key_entities / surprising_claims / controversies の全項目で v1.0 最低基準をクリア
key_numbers 14 件は v2.0 目標 (15 件以上) の直前まで到達。controversies 6 件は v2.0 目標 (3 件以上) を超過
qwen2.5:72b 単独で発生していた構造化ファクトの崩壊 (key_entities=1, controversies=0) を Pass1 を deepseek-r1:14b に切り替えることで回避
実行時間は qwen2.5:72b 単独比で −1,060 秒 (−25%) の改善。長文生成ボリュームは qwen2.5:72b 単独 (10,136 字) とほぼ同水準を維持

役割分担の根拠:

構造化抽出 (Pass1): JSON 出力の安定性と固有名詞・数値の網羅性で deepseek-r1:14b が優位
長文生成 (Pass2/3): 文章の流暢さ・セクション構成の一貫性で qwen2.5:72b が優位

3.3.2 Qwen3.5-122B-A10B-NVFP4 ベンチマーク確定値 (2026-05-03)
§0.2 の確定インフラ構成 (Pass1=deepseek-r1:14b @ Mac Studio Ollama / Pass2/3=Qwen3.5-122B-A10B-NVFP4 @ GX10 vLLM) で、§3.3.1 と同一のテーマ・angle (「睡眠と免疫」 / mode=lecture) を実測:

指標	Hybrid (qwen2.5:72b)	Hybrid (Qwen3.5-122B)	v1.0 目標	v2.0 目標
実行時間	51分21秒	17分34秒	—	—
research_content 文字数	9,879	17,409	15,000	20,000
key_numbers	14	21	5 以上	15 以上

判定:

research_content 17,409 字は v1.0 目標 (15,000 字) を 2,409 字 (約 16%) 超過。v2.0 目標 (20,000 字) まで残り 2,591 字
key_numbers 21 件は v2.0 目標 (15 件以上) を 6 件超過
実行時間 17分34秒は qwen2.5:72b Hybrid 比で −2,027 秒 (−66%)。NVFP4 量子化と vLLM の連続バッチング・PagedAttention により大幅短縮
v1.0 目標 (15,000 字) を初めて単体実行で突破した構成。これをもって Phase 2 の文字数未達課題 (§5 Phase 2 の "文字数は 7,096 字に留まり目標未達 → 継続改善") は実質解消

今後の主戦構成: 本構成 (Pass1=deepseek-r1:14b / Pass2/3=Qwen3.5-122B) を当面のデフォルトとして運用する。

3.3.3 v1.6 スモークテスト実測値 (2026-05-07)
v1.6 実装完了直後の検証実行結果（テーマ「睡眠と免疫」、自動生成 angle 「寝不足が『風邪』を呼ぶ？睡眠時間が免疫細胞の数を劇的に減らす最新データ」）:

実行環境:
- 全 stage を Qwen3.5-122B-A10B-NVFP4 @ GX10 vLLM で実行（Pass1 も 122B 統一）
- 並列度 Pass1=8 / Pass2=5

実行結果:

指標	実測値	v1.0 目標	v2.0 目標
全体実行時間	23分32秒	—	—
research_content 文字数	38,567 字	15,000	20,000
ソース数	44件 (AAA=23 / A=2 / B=19)	—	—
key_numbers	34件	5以上	15以上
key_entities	77件	5以上	15以上
surprising_claims	5件	2以上	5以上
controversies	0件	1以上	3以上

v1.6 拡張フィールドの実測:

confidence 分布:
- high:   3件 (key_entities のみ)
- medium: 113件 (全カテゴリ)
- low:    0件

cross_validated_sources の分布:
- 件数1 (単独ソース): 113件 (97.4%)
- 件数2 (2ソース裏取り): 3件 (2.6%)（key_entities のみ: NK細胞 / サイトカイン / 短鎖脂肪酸）
- 件数3以上: 0件

highly_specific フラグ:
- 発生件数: 2件 / 全 key_numbers 34件 (5.9%)
- 両方とも nature.com (AAA tier) の Scientific Reports 論文由来
- OR=0.207 / OR=0.800 (95% CI 値、小数3桁検出によるフラグ)
- 実際にはハルシネーションではなく正規論文の数値だが、フラグの設計通りの動作

Gap-fill 発火: あり (Pass3 後品質未達 → 1クエリ追加で +3,654字を補完)

判定:
- v2.0 目標 (20,000字) を 1.9 倍超過、文字数は完全達成
- key_numbers / key_entities は v2.0 目標を超過
- v1.6 拡張フィールドは設計通り動作
- highly_specific の false-positive 率 5.9% は許容範囲

3.3.4 v1.6 で判明した制約: key_numbers cross-validation 率の低さ
v1.6 実機検証で判明した重要な制約。

現象:
- key_entities では cross_validated_sources >= 2 (confidence="high") が 3件発生
- key_numbers では cross_validated_sources >= 2 が 0件 (全件 cvs=1)
- 結果として key_numbers の confidence は実質「medium 一択」となる

原因:
- _merge_structured_facts の dedup キーが (value, unit, context[:30])
- 同じ「2.94倍」でも context の冒頭30字が異なれば別 fact として登録される
- key_entities は (name, type) キーで照合できるため一致しやすい

影響:
- 当初の confidence ロジック（high=複数ソース確認）が key_numbers ではほぼ発動しない
- radio_director 側の Phase B/D 設計に影響（§10.3 参照）

対応方針:
- v1.6 段階: 制約として記録、運用で対応
- v1.7: dedup キーの緩和を別タスクで議論
  - 候補(a): 数値完全一致モード - キー: (value 数値部分のみ, unit)
  - 候補(b): 数値+context lemmatize モード - キー: (value, unit, lemmatize(context[:50]))

3.4 台本側実装（Phase 3 / 2026-05-02 完了）
リサーチ側が出力する structured_facts を、台本側 auto_radio_generator が ScriptOrchestrator Step 0.5 で読み取り、FactExtractor を完全にスキップして FactSheet を直接生成し TopicCurator に渡す経路を実装。

実装内容:

core/models/artifacts.py: ResearchBrief.structured_facts: Optional[Dict[str, Any]] を追加（Pydantic Optional・既定 None で後方互換維持）
core/models/fact_sheet.py: FactSheet.from_structured_facts(dict) -> FactSheet クラスメソッドを新設
core/interfaces/researcher.py: ResearchResult dataclass に structured_facts フィールドを追加（research_brief → research_data の搬送経路）
services/pipeline/scripting_phase.py: ResearchResult 構築点で伝播
services/script_generation/orchestrator.py Step 0.5: 優先順位を整理
preset_fact_sheet（HITL 編集済み） > 即採用
research_data.structured_facts（リサーチ側事前抽出）> from_structured_facts で変換し FactExtractor をスキップ
fact_extractor.enabled かつ Curator が走る場合 > FactExtractor 実行
それ以外 > fact_sheet=None

変換マッピング（interface_spec.md 3.1 → ExtractedFact）:

structured_facts のサブフィールド	FactCategory	surprise_score	source 引用保持
key_numbers	数値	7	source_idx → [N] 形式で source_citation
key_entities	type で分岐（人物 / 定義 / 技術 / イベント / その他）	5	同上
surprising_claims	その他	9	同上
controversies	比較	7	source_indices → [N,M] 形式

実機検証（2026-05-02 / Ollama qwen3:32b）:

検証項目	結果
Step 0.5 で structured_facts → FactSheet 変換	✅ ログに「FactExtractor スキップ」「FactSheet 構築 (facts=13)」
FactExtractor LLM 呼び出し回数	✅ ゼロ（合成 structured_facts 13 件 → そのまま FactSheet 13 件）
TopicCurator が選定したトピックに数値含有	✅ 3 トピックすべてに数値（20% / 18% vs 25% / 5%・1.5倍）
台本本文 43 ターン中の数値・固有名詞	✅ 数値 41 個、BMI 4 回、HIIT 4 回、アディポ 3 回 等
facts=[] 系エラー発生	✅ ゼロ

失敗時の挙動: from_structured_facts 変換中に例外が出た場合は、防御的に FactExtractor へフォールバック（後方互換維持）。structured_facts=None / 不在の場合も従来通り FactExtractor を実行する。

Hybrid 構成（§3.3.1）との関係: Hybrid 構成は リサーチ側で structured_facts を 高精度に生成する手段、Phase 3（§3.4）はそれを台本側で消費する経路。両者が揃って 初めて facts=[] の根本原因（小型モデル依存のファクト抽出失敗）が構造的に解消される。

4. 両者の合意事項
4.1 変更時のルール
フィールドの追加・変更・削除を行う場合:
1. この仕様書を先に更新する
2. 相手のAIに共有する
3. 両方が対応してからリリース
4. バージョン番号を上げる

4.2 互換性の保持
フィールドの追加: Optional[型]で追加
                  既存コードへの影響なし
フィールドの削除: 最低1バージョン前から非推奨宣言
フィールドの変更: 原則禁止・新フィールドとして追加

4.3 品質判定の責任分担
リサーチ側が保証する指標:
  - research_contentの文字数
  - AAA+AAソース数
  - 統計値・数値の個数
  - 空セクション数
  - snippetの有無
  - structured_facts の confidence（v1.6 以降）
  - structured_facts の flags（v1.6 以降）

台本側が評価する指標:
  - TopicCuratorが圧縮後も数値が残っているか
  - key_factsに固有名詞が含まれているか
  - surprising_claimsが台本のフックに使われているか
  - confidence="low" の claim を不適切に使っていないか（v1.6 以降）

5. ロードマップ
Phase 1（実装中）: 即効・小コスト
✅ クエリ質問文化（1-A）
✅ must_coverスロット化（1-C）
✅ 統計密度フィルタ（2-B）
✅ 引用明示化（3-D）
期待効果: 数値密度向上・クエリ精度向上

Phase 2（実装完了 2026-04-28）: 基盤改修・本丸
[x] Pass1を構造化ファクト抽出に変更
[x] structured_factsフィールドの新設
[x] Pass2をセクション別逐次生成に変更
[x] Pass3をファクトカバレッジ判定に変更
期待効果: 文字数20,000字・数値密度大幅向上
実測効果: structured_facts は §3.3 の通り基準クリア
         文字数は 7,096 字に留まり目標未達 → §3.3.2 で Qwen3.5-122B 採用により解消

Phase 3（台本側対応）
[ ] angleをResearchResult経由で伝播（auto_radio_generator）
[ ] angle を Phase A→B→C で貫通使用（radio_director）
[x] structured_factsをTopicCuratorに渡す（2026-05-02 実装完了 / §3.4 参照）
[ ] snippetを有効化
期待効果: 番組コンセプトの全層伝達・引用追跡
実測効果: structured_facts 経路は実機検証で facts=[] ゼロ・数値固有名詞含む
         台本生成を 1 本完走（§3.4 末尾の検証表）

Phase 4（拡張）
[ ] PubMed/arxiv API拡充
[ ] 反復検索（穴埋め）
[ ] 出力検証エージェント
期待効果: Perplexityを超える日本語特化リサーチ

Phase 5（v1.6 / 2026-05-07 実装完了）: 信頼度メタデータの追加
[x] structured_facts に cross_validated_sources を追加
[x] structured_facts に confidence を追加
[x] structured_facts に flags を追加（highly_specific のみ）
[x] _merge_structured_facts の dedup 拡張
[x] confidence 判定ロジック実装
[x] 後方互換テスト全件 PASS
実測効果: §3.3.3 参照、全 116 fact に v1.6 メタデータが付与
判明した制約: key_numbers の cross-validation 率が 0%（§3.3.4 参照、v1.7 で対応予定）

Phase 6（v1.7+ 議論予定）: 拡張フラグ・publication_date・dedup 改善
[ ] _merge_structured_facts の dedup ロジック改善（§3.3.4 の制約解消）
[ ] flags に "expert_quote" を追加
[ ] flags に "no_publication_date" を追加
[ ] research_sources に publication_date を追加（取得率60-70%想定）
[ ] fill_gaps API の外部公開（Gap-fill ロジックのリファクタリング）
期待効果: より精緻な品質管理、再リサーチの自動化、key_numbers の confidence 実用化

6. バージョン履歴
バージョン	日付	変更内容
0.1.0	2026-04-26	骨子作成（ドラフト）
1.0.0	2026-04-26	台本側調査結果を反映・全文更新
1.1.0	2026-04-28	Phase 2 実装完了を反映。§3.3 にリサーチ側テスト実測値（key_numbers=9 / key_entities=10 / surprising_claims=3 / controversies=4）を追記
1.2.0	2026-05-01	§3.3.1 を新設し Hybrid 構成 (Pass1=deepseek-r1:14b / Pass2/3=qwen2.5:72b) のベンチマーク実測値を追加。3 構成 (deepseek 単独 / qwen 単独 / Hybrid) の比較表を反映
1.3.0	2026-05-03	Phase 3 のうち「structured_facts を TopicCurator に渡す」が台本側で実装完了。§3.4 を新設し台本側実装内容（ResearchBrief / FactSheet / ScriptOrchestrator Step 0.5 の変更点・変換マッピング・実機検証結果）を追記。§5 Phase 3 のチェックボックスを更新。残タスク（angle 伝播・snippet 有効化）は引き続き未実装
1.4.0	2026-05-03	§0.2 を新設し GX10 推論インフラを確定 (vLLM port 8000 / Ollama port 11434 / Mac Studio Proxy port 11435 が Ollama 形式→OpenAI 形式に変換して GX10 vLLM へ転送 / Pass1=deepseek-r1:14b @ Mac Studio Ollama / Pass2/3=Qwen3-Next-80B-A3B-Instruct-NVFP4 @ GX10 vLLM, served-model-name=qwen3-next-80b)
1.5.0	2026-05-06	§7（ベンチマーク基準値）・§8（Variance 観測）・§9（推奨ベンチマークテーマ）を新設。リサーチ側 benchmark_themes.py (5 テーマ × repeat 3 = 15 ラン) の実測値: 平均 17 分 7 秒 / research_content 27,565 字 / key_numbers 23.7 件 / KV ピーク 12.3% を基準値として記録
1.6.0-rc	2026-05-07	§3.1 に v1.6 拡張フィールド (confidence / cross_validated_sources / flags) を追加。§3.1.1, §3.1.2 を新設し各フィールドの仕様と判定ロジック実装方針を記載。§5 Phase 5 を新設し v1.6 ロードマップを定義。§5 Phase 6 を新設し v1.7+ 拡張議論項目を整理。§10 を新設し radio_director (Mac Studio 新パイプライン) との協調設計を記載。§4.3 の責任分担に v1.6 の confidence/flags 担保項目を追加
1.6.0	2026-05-07	v1.6 実装完了（当初予定 5/9 末より2日前倒し）、実機データで検証完了。§3.3.3 を新設し v1.6 スモークテスト実測値を追加（research_content 38,567字、全116 fact に v1.6 メタデータ付与、highly_specific 2件発生で false-positive 率 5.9%）。§3.3.4 を新設し key_numbers の cross-validation 率 0% 制約と v1.7 対応方針を記録。§5 Phase 5 を実装完了状態に更新、Phase 6 に dedup 改善を追加。§10.3 を実機データに基づく Phase B/D 設計に修正
1.6.1	2026-05-08	§0.2 に vLLM サーバー設定の詳細を追加。Qwen3.5-122B 自体は 256K context だが、現在 max_model_len=32,768 に制限されていることを明記（KV cache 制約のため）。radio_director Phase B プロトタイプ実装中に発見された制約。将来拡張の検討メモも追加
1.7.0	2026-05-09	radio_director Step 1 SSOT 化を反映。台本側 (radio_director) の VerifiedScript が Windows 側 auto-radio-generator への引き渡しに必要な情報をすべて内包する（thumbnail_title / references / chapters / hashtags / description / title）。research_brief.json スキーマ自体は変更なし。radio_director 側の実装変更は radio_director_design.md v1.6.0 §26 を参照

7. ベンチマーク基準値（2026-05-06 実施）
リサーチ側 benchmark_themes.py を用いた 5 テーマ × repeat 3 = 15 ラン の実測値。並列度は Pass1=8 / Pass2=5 構成（vLLM proxy 経由で qwen3.5-122b を使用）。今後の設定変更比較におけるベースラインとして本値を参照する。

ハードウェア前提:
  ASUS Ascent GX10
  （NVIDIA GB10 Grace Blackwell Superchip / 128GB LPDDR5x）
  モデル: Qwen3.5-122B-A10B-NVFP4 (vLLM)
  並列度: Pass1=8 / Pass2=5
  構成: Mac Studio Proxy 経由

異なる環境では数値が大きく変わる可能性があります（特に Qwen3-30B-A3B など軽量モデル使用時）。

指標	平均
全体実行時間	17 分 7 秒 (1,027 秒)
research_content 文字数	27,565 字
key_numbers 件数	23.7 件
key_entities 件数	39.4 件
KV キャッシュピーク	12.3 %

完走率は 15/15 (100%)。検証 run の保存先は benchmark_themes_results/run_20260506_173706/results.csv。

8. Variance 観測
§7 のベンチで観察された重要事項として、同一テーマ内のラン間標準偏差が、テーマ間の標準偏差を上回る 現象が確認された。

観点	σ
テーマ間 σ (テーマ平均値の散らばり)	103.6 秒
同一テーマ内 σ の代表値 (例: プラスチック汚染 σ=283.4 / リチウム電池 σ=205.8)	テーマ間 σ を上回るケースが複数

→ ラン間ばらつきが支配的な状況では、repeat=3 では設定変更の効果サイズを統計的に確定しにくい。今後の設定変更比較には repeat=5 以上を推奨。benchmark_themes.py の --repeat 引数で調整可能。

venv/bin/python benchmark_themes.py --repeat 5   # 5 テーマ × 5 = 25 ラン (約 7.5 時間)

台本側への影響: structured_facts の件数も大きく変動する。
  key_numbers: 3〜62件
  key_entities: 15〜68件
  research_content: 15,761〜40,392字
台本側は「最低限N件のkey_numbersがあること」を前提にせず、少ない場合のフォールバックを実装すること。

9. 推奨ベンチマークテーマ
§8 の variance 観測において、テーマ別の duration σ は次のとおり:

#	テーマ	duration σ
1	睡眠と免疫	6.7 秒 ← 最も安定
2	量子コンピューティングの実用化	111.0 秒
3	認知行動療法のうつ病への効果	103.7 秒
4	プラスチック汚染の海洋生態系への影響	283.4 秒
5	リチウムイオン電池のリサイクル	205.8 秒

「睡眠と免疫」が最も安定した variance を示している (σ=6.7 秒) ため、新規設定変更の効果検証時はこのテーマを優先利用すること。並列度・モデル・閾値などの A/B 比較は、まず「睡眠と免疫」で 5 ラン以上を取り、その後に他テーマで一般化検証するのが効率的。

10. 台本側パイプライン構成（2026-05-07 確定）
2026-05-07 時点で台本生成パイプラインは2系統で運用される。

10.1 auto_radio_generator (Windows、既存)
役割: 既存実装、フォールバック環境として本運用継続

設計:
  - structured_facts を ScriptOrchestrator Step 0.5 で消費（§3.4 実装済）
  - FactExtractor は条件付きスキップ、フォールバックで復活
  - TopicCurator → ShowRunner → SegmentGenerator の3段構成
  - FactChecker + FactFixAgent でハルシネーション対策

備考: 大幅な変更は radio_director 安定化まで凍結

10.2 radio_director (Mac Studio、新規構築中)
役割: ゼロベース構築の新台本生成パイプライン

設計概要:
  Phase A: リサーチ品質層（決定論的）
    - structured_facts → CleanedResearch に変換
    - 品質ゲート（key_numbers 等の検証、不足時は警告）
    - confidence/flags の活用

  Phase B: 番組企画（1 LLMコール）
    - FactExtractor + TopicCurator + ShowRunner を統合
    - 「ディレクターとして書け」というフレーミング
    - structured_facts を主軸、research_content を文脈として使用
    - angle を必ず参照、再解釈・改善は禁止

  Phase C: 対話生成（並列 LLMコール）
    - intro + topic_1〜N を並列実行
    - conclusion は最後に sequential
    - 各 topic に key_facts（confidence 付き）を渡す

  Phase D: 品質ゲート
    - structured_facts と台本を突き合わせて検証
    - confidence の低い claim を使った場合は警告
    - 自動修正 + メタデータ生成

10.3 v1.6 が radio_director 設計に与える影響（実機データ反映）
v1.6 実機検証 (§3.3.3 / §3.3.4) を踏まえた設計反映:

confidence フィールドの実態:
  - key_entities では "high" が発生する（複数ソース確認）
  - key_numbers では "high" がほぼ発生しない（dedup キー厳格性、§3.3.4 参照）
  - "low" は AAA/A tier 比率が高ければほぼ発生しない
  → radio_director Phase B/D は domain_tier を主要シグナル、confidence を補助シグナルとする

cross_validated_sources フィールドの実態:
  - key_entities で複数ソース確認の事実は引用時に強調（「複数の研究で確認されている」等）
  - key_numbers では当面 [single source] が大半
  → v1.7 dedup 改善後に運用ロジック見直し

flags["highly_specific"] の解釈:
  - フラグ単体では「ハルシネーション疑い」と断定しない
  - source_idx の domain_tier を必ず確認
  - AAA/AA tier 由来 + highly_specific = 許容（正規論文の精密値の可能性）
  - B tier 由来 + highly_specific = 警告（ハルシネーション可能性高）
  - false-positive 率 5.9% は許容範囲（実機検証）

radio_director Phase B プロンプトの優先度ロジック:
```
1. confidence="high" の claim を最優先
2. confidence="medium" のうち domain_tier が AAA/AA/A のもの
3. confidence="medium" のうち domain_tier が B のもの（慎重に使用）
4. confidence="low" は原則引用回避
```

radio_director Phase D 検証ロジック:
```
1. highly_specific フラグがある claim が台本に含まれたら詳細チェック
   - source_idx の tier が AAA/AA/A → 許容
   - source_idx の tier が B → 警告（手動確認推奨）
2. confidence="medium" でも domain_tier が高ければ実用上「裏取り済」扱い
3. confidence="low" の claim が台本に使われていたら警告

10.4 重要な設計補足（research_pipeline 側からの指摘）
structured_facts に含まれない事実が research_content に豊富にある場合、
台本生成 LLM が research_content 側の情報を引用するリスクがある。

radio_director の対策:
  Phase B プロンプトに以下を必ず明示:
  「数値・固有名詞・統計を引用する場合は structured_facts から選ぶこと」

10.5 将来の協調項目（v1.7+）
fill_gaps API:
  radio_director の Phase A が品質不足を検出した場合、
  research_pipeline に補完リサーチを依頼する API。
  
  責任分担:
    severity (radio_director 側): どの gap を優先的に埋めるか
    gap_type (research_pipeline 側): どう検索すべきか
  
  実装方針: incremental（既存 structured_facts に追加）
  既存の Gap-fill ロジックの外部公開化として実現可能。