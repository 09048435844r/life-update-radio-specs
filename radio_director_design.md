# radio_director 設計仕様書

**バージョン**: 1.1.0
**作成日**: 2026-05-07
**最終更新**: 2026-05-07
**ステータス**: 設計確定 / 実装着手準備完了
**対象**: Mac Studio で構築する新台本生成パイプライン `radio_director`
**経緯**: 既存 `auto_radio_generator` (Windows) のコードベース肥大化と複数の改善試行失敗を踏まえ、ゼロベース再設計

## 関連仕様
- 上流仕様: `interface_spec.md` v1.6.0（research_pipeline との契約）
- 既存実装: `auto_radio_generator` (Windows、フォールバック環境として継続運用)
- リポジトリ: `09048435844r/life-update-radio-specs`

## 本ドキュメントの位置付け
- 新台本生成パイプライン `radio_director` の設計仕様
- 既存 `auto_radio_generator` の課題分析と廃止・統合判断の記録
- research_pipeline (`interface_spec.md`) との協調設計

---

## 1. 提案の経緯

### きっかけ

FactExtractor の改善試行（Structured Output / 2段階アーキテクチャ）が両方とも失敗し、「壊れたものを再構築するより、動いているものを守る + そもそも論で構造を見直す」方向に舵を切った。

### 失敗した改善試行（記録）

1. **vLLM Structured Output (Phase 1, commit 7a35f97)**: TopicCurator に `response_schema` を適用 → コンテンツ品質劣化（文字化け、BOM混入、トピック数不足）→ ロールバック (5d2d764)
2. **2段階アーキテクチャ (FactExtractor, commit b17b44b)**: Phase 1 markdown + Phase 2 regex → 思考プロセスが markdown のフィールド（出典等）に漏出、英語の無限ループ発生 → ロールバック予定

### 失敗の構造的理由

```
JSON 強制         → コンテンツ品質劣化（文字化け、トピック数不足）
Markdown 自由形式 → 構造破綻（思考漏出、無限ループ）
```

両極端のアプローチが両方失敗。Qwen3.5-122B (thinking model) と分析的タスク（FactExtractor）の組み合わせに本質的な無理がある。

---

## 2. 根本解決の方向性

### 解決策A: FactExtractor 廃止（推奨）

**理由**: FactSheet を実際に消費しているのは TopicCurator のみ。「判断材料」として導入されたが、TopicCurator のプロンプトで「リサーチデータから根拠となる数値・固有名詞を抽出してトピックに含めよ」と指示すれば同じ役割を果たせる。

**メリット**:
- 問題そのものが消える
- LLMコール削減（毎回1コール × 約60秒）
- エラー源削除（malformed facts、JSON切断、思考漏出）

**実装コスト**: 小〜中
- FactExtractor の呼び出し削除
- TopicCurator のプロンプト補強
- structured_facts 関連の経路整理

### 解決策B: モデル使い分け（代替案）

```
SegmentGenerator (thinking ON):  Qwen3.5-122B  ← 創造的、現状維持
TopicCurator (thinking OFF):     Qwen3.5-122B  ← 現状維持
FactExtractor (非thinkingモデル): Qwen2.5-Instruct ← 分析的、思考漏れなし
```

GX10 で 2モデル同時起動が可能なら検討価値あり。ただし運用複雑度が増す。

### Qwen3.6 系への切替検討（参考）

- 改善する可能性: あり（thinking 制御の改善、instruction following 向上）
- 改善しない可能性: あり（同じ thinking アーキテクチャなら同じ問題が再発）
- **推奨度: 低**（待ち時間と検証コストに見合う保証がない）

---

## 3. アーキテクチャ全体のスリム化候補

### 🔴 確実に削減できる（高効果・低リスク）

#### 候補1: FactExtractor 廃止
- 影響範囲: TopicCurator の判断材料のみ
- 効果: 工数 -30%、エラー源削除
- 詳細: 上記「解決策A」参照

#### 候補2: 旧 OllamaClient 系の完全廃止
- 現状: 新 OllamaAdapter と並行運用
- 残骸:
  - `workflow.py:2427` の create_script_generator(provider="ollama")
  - `scripting_phase.py:399` の use_orchestrator=False 分岐
- 削減: workflow.py の 100-200 行
- 既存 BACKLOG: Tier C Phase B (ResearchPlanner 新設)

#### 候補3: Visual Identity Generation の削除（ollama経路）
- 現状: 毎回スキップされるコードが呼ばれている
  ```
  [INFO] Ollama provider detected: Skipping visual identity generation
  [INFO] Using default visual identity
  ```
- 対応: ollama 経路では条件分岐ごと削除

#### 候補4: MetadataGenerator の経路統一
- 現状: 3箇所で生成
  - Orchestrator 内
  - scripting_phase（R1 で排除済み）
  - workflow.py:2019（残骸）
- 対応: workflow.py:2019 の経路を削除

### 🟡 検討の余地あり（中効果・要検証）

#### 候補5: ShowRunner の必要性再検討
**現在のフロー**:
```
TopicCurator → ShowRunner → SegmentGenerator
```

**提案**:
```
TopicCurator（show plan も出力） → SegmentGenerator
```

ShowRunner の出力（アーク、トーン、ブリッジ）を TopicCurator に統合する。
- メリット: LLMコール1つ削減（毎回約60秒短縮）
- デメリット: TopicCurator の責務が膨らむ

#### 候補6: SegmentGenerator の Phase 1/2 の見直し
- 現状: thinking-mode 対策として2段階（マークダウン → JSON）
- 元々: Qwen3:8b 用に作られた仕組み
- Qwen3.5-122B では本当に必要か検証する価値あり
- 1段階で動けば: コード削減 + 速度向上

#### 候補7: マルチプロバイダー対応の範囲縮小
- Gemini / OpenAI / Anthropic の各アダプタが維持されている
- 実態: ollama 経路がメイン
- 対応案: 使われていないアダプタを BACKLOG マーカーで明示、必要時のみ復活

### 🔵 リファクタリング候補（高効果・高リスク）

#### 候補8: workflow.py の分割
- 現在 **2800行** の単一ファイル
- 責務:
  - フェーズ実行
  - メタデータ生成
  - ファクトチェック呼び出し
  - サムネイル生成
  - YouTube アップロード
- 影響範囲が大きいため、別 PR で計画的に進める必要あり

#### 候補9: config の SSOT 一本化
- 現状: curator_model / segment_model / json_model 等が個別定義
- 提案: `model` 1つに統一
- 工数: L
- 効果: 保守コスト大幅削減

### 🟢 機能の取捨選択

#### 候補10: FactCheck Phase 3（自動修正）の運用方針
- 現状: high/medium severity の問題を自動修正
- 検討点: 自動修正の信頼性、視聴者向けの「真実性」保証
- 選択肢: HITL（人間確認）に戻す / 自動修正を維持

#### 候補11: mock mode の維持判断
- `dev.mock_mode` 関連コード
- 実運用ではほぼ使われていない
- 削除候補

---

## 4. 全体像の俯瞰

### 現在のパイプライン

```
Phase 1: 企画
Phase 2: リサーチ
Phase 3: 台本生成
  ├─ FactExtractor          ← 廃止候補
  ├─ TopicCurator
  ├─ ShowRunner             ← 統合候補
  ├─ SegmentGenerator × N   ← Phase 1/2 見直し候補
  ├─ MetadataGenerator
  ├─ FactChecker
  └─ FactFixAgent
Phase 4: メディア生成
  ├─ Visual Identity         ← 削除候補（ollama経路）
  ├─ 音声合成
  ├─ 動画生成
  ├─ サムネイル
  └─ YouTube アップロード
```

### 理想形（提案）

```
Phase 1: 企画
Phase 2: リサーチ
Phase 3: 台本生成
  ├─ TopicCurator (show plan 内包)
  ├─ SegmentGenerator × N
  ├─ MetadataGenerator
  ├─ FactChecker
  └─ FactFixAgent
Phase 4: メディア生成
  ├─ 音声合成
  ├─ 動画生成
  ├─ サムネイル
  └─ YouTube アップロード
```

**効果**:
- LLM コール数: 9 回 → 6-7 回（25-30% 削減）
- コードベース削減: 数百〜千行レベル
- エラー源削除（FactExtractor関連の問題消滅）

---

## 5. 推奨される次のアクション順序

1. **今すぐ**: FactExtractor 2段階アーキテクチャ（b17b44b）のロールバック
2. **次のセッション**: 候補1（FactExtractor 廃止）の影響範囲調査と実装
3. **その後**: 候補2-4（旧経路・ダミー処理の削除）を順次
4. **中期**: 候補5（ShowRunner 統合）の検証
5. **長期**: 候補8-9（workflow.py 分割、config SSOT 化）を計画的に

---

## 6. 議論を継続したいトピック

A. **削減（FactExtractor + ShowRunner 統合）の影響範囲** - 最大効果
B. **workflow.py 分割の設計案** - リファクタの本丸
C. **SegmentGenerator Phase 1/2 の必要性検証** - 単純化の可能性
D. **マルチプロバイダー対応の現状と縮小案** - 保守コスト削減
E. **その他、見落としている観点**

---

## 7. 重要な学び

### 完璧を求めない設計判断

「完璧を求めすぎて壊れたものを再構築する」より「動いているものを守る」方が運用上正しい場合がある。

具体的には:
- 元の FactExtractor (JSON形式) は「まあまあ動いていた」（4-23件抽出、malformed あり）
- 改善試行が両方失敗
- 改善しようとした原因（不完全なファクト抽出）に対しては、**FactExtractor 自体を廃止**する方が合理的

### モデル特性とタスク特性のマッチング

- thinking モデル（Qwen3.5-122B）: 創造的タスクに向く（SegmentGenerator）
- 非thinking モデル: 分析的タスクに向く（FactExtractor 相当）
- タスクごとに最適なモデルを選ぶか、タスクそのものを再設計する

### 実装より先に「やめる」選択肢を検討する

新機能の追加・改善より、**既存機能の廃止・統合**が最も低コストで高効果な場合が多い。

---

## 8. SegmentGenerator の構造分析（追加議論）

### 現状の構造

```
SegmentGenerator
  ├── Phase 1: 創造的 markdown 生成（LLM, temperature=0.85）
  │     ├── system_prompt: orchestrator.segment_*_creative
  │     ├── 出力: **A**: ... **B**: ... の対話形式
  │     └── markdown_output_dir に *_phase1.md として保存
  │
  └── Phase 2: JSON 構造化
        ├── ローカル LLM (ollama等) → Direct Regex Bypass（LLM呼ばず）
        └── クラウド LLM → 別 LLM コール → 失敗時 regex フォールバック
```

呼び出し回数: 5 セグメント（intro + deep_dive×3 + conclusion）

### 議論の論点

#### 論点1: Phase 1/2 の2段階構造は今も必要か？

**当初の理由**: Qwen3:8b で JSON 直接生成が不安定だったため。

**現状**:
- ollama 経路: Phase 2 は regex bypass なので実質 LLM コールは1回
- クラウド経路: Phase 2 で2回目の LLM コール（時間ロス）

**評価**: TopicCurator で JSON 強制が品質劣化を起こした実績あり → SegmentGenerator でも同じことが起きる可能性が高い。**現状維持を推奨**。

#### 論点2: セグメント生成の単位

**現状**: 5セグメント × 1コール = 5コール

**選択肢**:
- A. 現状維持（5コール）
- B. 全セグメント1コール（リスク大）
- C. deep_dive のみまとめる（中庸案）

**評価**: 並列化と密接に関連。Mac Studio 移植後に検討。

#### 論点3: セグメント間の context 引き継ぎ（デッドコード候補）

**調査で判明**: `_build_deep_dive_user_prompt` で `context` 引数は user prompt に挿入されていない。**deep_dive 同士の context 引き継ぎは実質使われていない**。

**意味すること**:
- deep_dive_1 / 2 / 3 は実は独立している（→ 並列化可能）
- 引き継ぎコードはデッドコード

#### 論点4: temperature=0.85 の高さ

**現状**: 創造性重視で 0.85（他のエージェントは 0.3-0.7）

**懸念**: 出力のバラつきが大きい、思考漏出のリスク

#### 論点5: Phase 1 markdown 保存の必要性

**目的**: デバッグ用

**疑問**: 本運用では使っていない。残骸ファイルが output/ に蓄積。

#### 論点6: クラウドプロバイダーの Phase 2 LLM 経路

**疑問**: 実態として ollama がメイン → クラウド経路の Phase 2 は使われていない可能性が高い。デッドコード候補。

### SegmentGenerator の優先順位

1. **論点3（context引き継ぎデッドコード削除）**: 一番安全な改善、並列化への布石
2. **論点5（markdown保存）**: I/O削減
3. **論点6（クラウドPhase2）**: デッドコード削除
4. **論点2（セグメント単位）**: Mac Studio 移植後に並列化と一緒に検討
5. **論点1（2段階構造）**: 危険、現状維持推奨
6. **論点4（temperature）**: 微調整、ABテスト要

### 結論

SegmentGenerator は現状で「動いている」状態。FactExtractor とは違って急ぎで直す必要性は低い。「掃除」レベルの改善（論点3, 5, 6）は有意義。

---

## 9. TopicCurator と FactExtractor の役割整理（追加議論）

### データフロー

```
リサーチデータ（Perplexity 出力 / 約20-30K文字）
       ↓
[FactExtractor]
   30件のファクトを抽出
       ↓
   FactSheet（構造化ファクト集）
       ↓
[TopicCurator] ← リサーチデータとFactSheet両方を受け取る
   3つのトピックを選定
       ↓
   CurationResult（トピック + 各トピックのkey_facts）
       ↓
[ShowRunner]
   番組構成プラン
       ↓
[SegmentGenerator]
   実際の対話台本
```

### それぞれの役割

**FactExtractor（事実抽出器）**
- 目的: リサーチデータから「使える事実」を機械可読に抽出
- 動機: TopicCurator に「判断材料」を提供する
- 出力: 30件のファクト
- 比喩: 長い記事を読みながら蛍光ペンで重要箇所をマークする作業

**TopicCurator（トピック選定器）**
- 目的: ラジオ番組で取り上げる3つのトピックを決める
- 動機: 一回の番組で扱える話題は限られる
- 出力: 3トピック（タイトル、内容、優先度、key_facts、選定理由）
- 比喩: 編集者が記事の中から番組の見出しを3つ立てる作業

### なぜ2段階に分けたか（設計時の推測）

- リサーチデータが長すぎて TopicCurator が見落とす可能性
- 「ファクト」と「トピック」は別の抽象レベル
- 各ステップで失敗を独立に処理できる

### 改めての疑問: 本当に2段階必要か？

- FactSheet を実際に消費しているのは TopicCurator のみ
- 現代のLLMは長コンテキスト対応（Qwen3.5-122B は 32K対応）
- TopicCurator は元々リサーチデータも受け取っているため、FactSheet を見ずに動く可能性

**結論**: FactExtractor は「TopicCurator のヘルパー」として導入されたが、**現在のLLM能力では不要**になっている可能性が高い。ShowRunner も同じ構造の問題を抱えている。

### 統合後のあるべき姿（仮説）

```
理想形:
リサーチデータ
   ↓
[ContentPlanner（仮称）]
   - リサーチを読む
   - 3トピックを選定
   - 各トピックの番組構成も作る（アーク・トーン・key_facts含む）
   ↓
[SegmentGenerator]
   - 対話台本を生成
```

**これは「分析的モジュール3個」を「1個」に統合する大胆な提案**。

#### メリット
- LLMコール大幅削減（FactExtractor + ShowRunner 削除で 2コール削減）
- 中間データ構造の保守不要
- 思考の流れが自然（一気通貫で「番組を企画する」）

#### デメリット
- 1コールでやることが増える → 思考漏出リスク上昇
- プロンプトが複雑化
- 失敗時の影響範囲が大きい

### TopicCurator 改善策の選択肢

#### 解決策A: FactExtractor 廃止と統合（最有力）
- TopicCurator のプロンプトに「リサーチから根拠数値・固有名詞を抽出してトピックに含めよ」と統合
- メリット: LLMコール削減、エラー源削除
- デメリット: TopicCurator の責務増、思考漏出リスク上昇の可能性

#### 解決策B: 創造的タスクへのリフレーミング
- TopicCurator を「分析」ではなく「創造」として再定義
- プロンプトを「分析せよ」から「書け」に変える
- SegmentGenerator が動く理由（生成タスク）を踏襲

#### 解決策C: SegmentGenerator パターンの完全適用（2段階化）
- **推奨しない**: FactExtractor の2段階化が思考漏出で失敗した経験あり

#### 解決策D: モデル使い分け
- TopicCurator を非thinkingモデルで動かす
- GX10 で 2モデル運用が可能なら検討

#### 解決策E: 現状維持 + 防御層強化
- 既存の防御層（_normalize_tone、フォールバック等）を活用
- 急ぎでなければこれで十分

### 推奨アプローチ

**解決策A + B の組み合わせ**:
```
Step 1: FactExtractor 廃止
Step 2: TopicCurator のプロンプトを以下に変更:
  - 分析的トーン → 創造的トーン
  - 「トピックを選定せよ」→「トピックを書け」
  - 「ファクトを判断材料に」→「ラジオ番組として面白い切り口で書け」
  - 統合された「リサーチからの根拠抽出」も創造的に組み込む
```

**コード変更最小、効果最大**の組み合わせ。

---

## 10. ゼロベース再設計（追加議論）

### 前提の変化

```
旧前提（小コンテキストモデル時代）:
- 段階的に情報を蒸留する必要があった
- 各ステップで「処理しやすい中間形式」に変換
- だから FactExtractor → TopicCurator → ShowRunner と細分化

新前提（32K コンテキスト + 高性能モデル / Qwen3.5-122B）:
- リサーチデータ全体を一度に LLM に渡せる
- 細分化のコストが効果を上回る
- むしろ細分化が思考の連続性を阻害している
```

### 新アーキテクチャの全体像

```
Phase A: リサーチ品質層（決定論的前処理、LLMなし）
  ↓
Phase B: 番組企画（1 LLMコール、創造的）
  ↓
Phase C: 対話生成（並列 LLMコール、創造的）
  ↓
Phase D: 品質ゲート（1 LLMコール、検証）
  ↓
Phase E: メディア生成（既存）
```

LLMコール数: 5-6回（現在9-10回、約40%削減）

### Phase A: リサーチ品質層（前処理）

**目的**: ハルシネーション・冗長・出典不明な情報を構造的に検出し除去

**処理内容（LLMなし、決定論的）**:
```python
def preprocess_research(research_brief: ResearchBrief) -> CleanedResearch:
    # 1. ソース信頼度スコアリング（Life Update Radio パイプライン参照）
    sources = score_sources_by_domain(research_brief.sources)

    # 2. 主張と出典のひも付け
    claims = extract_claims_with_sources(research_brief.text)

    # 3. クロス検証（同じ主張が複数ソースに存在するか）
    for claim in claims:
        claim.cross_validation = count_sources(claim, claims)

    # 4. 信頼度フラグ付け
    #    - AAA: 公的機関、論文
    #    - AA: 大手メディア、企業公式
    #    - A: 業界メディア
    #    - B: 個人ブログ、出典不明

    # 5. 重複排除
    return deduplicate(claims)
```

**ポイント**: LLMなし、失敗したら明示的にエラー。

### Phase B: 番組企画（1 LLMコール）

**入力**: CleanedResearch（信頼度付きの構造化データ）
**出力**: ShowSpec（番組仕様の完全版）

```python
ShowSpec {
  title: str           # 番組タイトル
  hook: str            # 視聴者を引き込む冒頭の問い
  arc: str             # 全体のアーク
  tone: str            # 全体のトーン
  topics: [
    {
      title: str
      hook: str
      key_claims: [
        { text: str, source: str, confidence: str }  # 信頼度付き
      ]
      tone: str
      estimated_turns: int
    }
  ]
  conclusion_message: str  # まとめのメッセージ
}
```

**ポイント**:
- 1コールで番組全体を企画
- key_claims に信頼度が付いているので、ハルシネーションを下流で防げる
- FactExtractor + TopicCurator + ShowRunner を統合
- プロンプトは「分析せよ」ではなく「ラジオ番組のディレクターとして企画書を書け」（創造的タスクとしてフレーミング）

### Phase C: 対話生成（並列 LLMコール）

**処理**:
- ShowSpec を入力に各セグメントを並列生成
  - intro
  - topic_1, topic_2, topic_3（並列）
  - conclusion

**ポイント**:
- 各セグメントは独立（現状の deep_dive context 引き継ぎはデッドコード）
- 並列化で大幅高速化
- key_claims を入力に渡すことでハルシネーションを構造的に抑制
- 既存の Phase 1 markdown + Phase 2 regex は維持（動いているため）

### Phase D: 品質ゲート（1 LLMコール）

**処理**:
- 入力: 完成台本 + CleanedResearch（信頼度付き）
- 1. ハルシネーション検出
- 2. 自動修正（high/medium severity）
- 3. メタデータ生成（title, description, hashtags, chapters）
- 出力: 検証済み台本 + メタデータ

**ポイント**:
- FactChecker + FactFixAgent + MetadataGenerator を統合
- 信頼度付きデータと突き合わせるため精度が上がる

### 主要な設計判断

#### 判断1: LLMコールを「タスク類型」で分ける

```
分析的タスク（情報整理）→ 決定論的処理に寄せる（Phase A）
創造的タスク（生成）→ LLM の得意領域（Phase B, C）
検証的タスク（チェック）→ LLM + 構造化データ（Phase D）
```

現状の問題: 分析的タスクを LLM にやらせて思考漏出を起こしている。

#### 判断2: 信頼度を最初から持ち回す

各 claim に「どのソースから」「どれくらい確からしいか」を付与する。これにより:
- 後段がハルシネーションに惑わされない
- FactChecker の精度が上がる
- 視聴者向けの「出典明示」も可能

#### 判断3: 中間表現を1つに統一

現状は FactSheet / CurationResult / ShowPlan / Script など多数の中間データ構造があり、保守コストが高い。新設計では:
- CleanedResearch（信頼度付き素材）
- ShowSpec（番組企画書、ここから台本まで一貫）
- Script（最終出力）

3つに集約。

---

## 11. 移行戦略：Windows フォールバック + Mac Studio ゼロベース構築

### 戦略の概要

```
Windows機:
  - 既存の auto_radio_generator を維持
  - 本運用を継続
  - フォールバック・バックアップとして機能

Mac Studio:
  - ゼロベースで新プロジェクト構築
  - 新アーキテクチャ（Phase A〜D）を実装
  - 安定確認後、メイン環境に移行
```

### なぜこの戦略か

- **リスクゼロ**: 既存本運用を止めない
- **真のゼロベース**: レガシーに引きずられない設計が可能
- **research_pipeline 移行との整合**: 新コードベースは最初から research_pipeline を想定して設計できる
- **過去の失敗からの学び**: 「動いているものを直しに行って壊した」経験を踏まえた安全策

### 決定事項

#### 決定1: コードベース戦略

**推奨: 別リポジトリで完全に独立**

```
auto_radio_generator (既存、Windows)
  - 現状維持
  - フォールバック用

radio_director (新規、Mac Studio)
  - ゼロベース
  - 新アーキテクチャ実装
```

理由: ゼロベースの恩恵を最大化するため。共通部分（VOICEVOXクライアント等）の再利用は後で検討。

#### 決定2: プロジェクト名

候補:
- `radio_director`（番組企画の中核を表現）← 推奨
- `radio_studio`
- `auto_radio_v2`

新設計では「Phase B: 番組企画」が中核なので、`radio_director` がコンセプトを表現。

#### 決定3: 役割分担の境界

```
Mac Studio (radio_director, 新規):
  Phase A: リサーチ品質層
  Phase B: 番組企画
  Phase C: 対話生成
  Phase D: 品質ゲート
  → 出力: 検証済み Script + メタデータ

Windows (auto_radio_generator, 既存):
  Phase E のみ: メディア生成
  - Mac Studio から script.json を受け取る
  - 音声合成 + 動画生成 + サムネイル + アップロード
  → フォールバック用に Phase A〜D も残す（削除しない）
```

**ユーザー操作フロー**:
1. Mac Studio で台本生成
2. ファクトチェック結果を確認
3. script.json を Windows にコピー
4. Windows で「台本から動画作成」ボタンを押す

#### 決定4: research_pipeline 移行のタイミング

```
今:     Mac Studio の Phase A に Perplexity 結果の品質処理を実装
将来:   research_pipeline が成熟したら入力源を切り替え
        Phase A の品質処理は維持（出力フォーマットを揃える）
```

Phase A を **抽象化レイヤー** として設計しておけば、入力源（Perplexity / research_pipeline）の切替がスムーズ。

### 開発スケジュール

```
Sprint 1（数日〜1週間）:
  - Mac Studio に新リポジトリ作成（radio_director）
  - Phase E のインターフェース定義（script.json の仕様確定）
  - 共通ライブラリの切り出し検討（VOICEVOXクライアントなど）

Sprint 2-3（数週間）:
  - Phase A 実装（リサーチ品質層、決定論的処理）
  - Phase B 実装（番組企画、1 LLMコール）
  - 単体テストで動作確認

Sprint 4（1週間）:
  - Phase C 実装（対話生成、並列化込み）
  - 既存 SegmentGenerator から流用可能な部分を移植

Sprint 5（1週間）:
  - Phase D 実装（品質ゲート）
  - Mac Studio → Windows の手渡しフロー確立

Sprint 6+:
  - 本運用テスト（Mac Studio 系）
  - 安定確認後、Windows 系を非推奨化（削除はしない）
```

### 並行運用の原則

- Windows 機の本運用は Mac Studio 系が完全に安定するまでプライマリ
- Mac Studio 系の本運用化は段階的（最初は実験運用、徐々にプライマリへ）
- 両系統を比較できる期間を設けることで、新設計の検証が可能

---

## 12. 設計判断の振り返りメモ

### 「動いているものを守る」原則

このドキュメントを通じて再確認された原則:

1. **完璧を求めて壊すリスク**を常に意識する
2. **既存機能の廃止・統合**は新機能追加よりも価値が高い場合が多い
3. **モデル特性とタスク特性のマッチング**が重要
4. **段階的移行**で本運用を止めない

### 失敗から学んだこと

- **JSON 強制**: 構造は守れるが日本語コンテンツ品質が落ちる
- **Markdown 自由形式**: 構造が破綻する（思考漏出、無限ループ）
- **2段階アーキテクチャ**: 創造的タスク（SegmentGenerator）には有効だが、分析的タスク（FactExtractor）には逆効果

### 今後の指針

- 既存の動作している部分を変更する前に、**廃止・統合の選択肢を先に検討**する
- LLM の特性を踏まえた**タスク設計**（分析より創造、細分化より統合）
- **信頼度・出典**を最初から持ち回すことで下流のハルシネーション対策コストを下げる

---

## 13. 各 Phase の詳細設計案

実装着手前に詰めておくべき4つの設計ポイントの具体案。

### 13.1 Phase A の詳細仕様

#### 設計判断: 「LLMなし完全決定論」を緩和

当初は「Phase A は LLMなし」と設計したが、再考の結果、**claim 抽出だけは軽量LLMが必要**。自然言語からの構造化抽出は決定論では精度が出ない。

**修正案**:
```
Phase A の処理:
  1. ソース信頼度（決定論）: URL → ティア（AAA/AA/A/B）マッピング
  2. テキスト前処理（決定論）: 重複除去、長さ正規化
  3. claim 抽出（軽量LLM、別モデル）: optional
  4. クロス検証（決定論）: claim 間の類似度判定
```

#### ソース信頼度ルール

```python
SOURCE_TIERS = {
    "AAA": [  # 公的機関・論文
        ".gov", ".go.jp", ".edu", ".ac.jp",
        "lancet.com", "nature.com", "science.org",
        "pubmed.ncbi.nlm.nih.gov", "arxiv.org", "ieee.org",
    ],
    "AA": [  # 大手メディア・企業公式
        "nikkei.com", "asahi.com", "yomiuri.co.jp",
        "reuters.com", "bloomberg.com", "wsj.com",
        "wikipedia.org",  # 注: 編集可能だが概ね信頼できる
    ],
    "A": [  # 業界メディア
        "techcrunch.com", "itmedia.co.jp", "ascii.jp",
        "engadget.com", "diamond.jp",
    ],
    "B": "default"  # その他（個人ブログ、出典不明、SNS等）
}
```

#### claim 抽出（軽量LLM）

旧 FactExtractor との違い:
- 旧 FactExtractor: 番組のメインデータ（30件、詳細）
- 新 claim 抽出: 信頼度判定用のメタデータ（数値・固有名詞・引用のみ）

シンプルなので軽量モデルで十分:
```
入力: テキスト 1段落
出力: ["数値: X", "固有名詞: Y", "引用: Z"]
```

複雑な分類・スコアリングをしないので思考漏出リスクが低い。

#### CleanedResearch の最終形

```python
class CleanedResearch(BaseModel):
    theme: str
    sources: List[Source]  # ティア順にソート
    cleaned_text: str  # 重複除去・長さ正規化済み
    extracted_claims: List[Claim]  # オプショナル

class Source(BaseModel):
    url: str
    title: str
    tier: Literal["AAA", "AA", "A", "B"]
    domain: str

class Claim(BaseModel):
    text: str  # "Hugging Face は 2024 年に評価額 45 億ドルへ到達"
    source_url: str
    tier: str  # ソースのティア
    cross_validated: bool  # 複数ソースで確認できたか
```

---

### 13.2 Phase B のプロンプト設計

#### 核心: 「役割」と「制約」の明確化

「ディレクターとして書け」を抽象論で終わらせず、**プロンプトの構造で創造的タスクとして体験させる**。

#### プロンプト設計の3要素

```
1. 役割の具体化
   ❌ 「あなたはディレクターです」（抽象的）
   ✅ 「30 分ラジオ番組のディレクターとして、視聴者を引き込む企画書を書いてください」

2. 出力フォーマットを「企画書」として提示
   ❌ JSON スキーマを直接見せる（分析的に感じる）
   ✅ 「企画書のテンプレート」として示す（創造的に感じる）

3. 制約を「業務上のルール」として書く
   ❌ 「リサーチデータ以外の情報を使うな」
   ✅ 「番組の信頼性のため、企画書の各事実には必ず出典タグを付けてください」
```

#### サンプルプロンプト

```
あなたは経験豊富なラジオ番組ディレクターです。

# 番組仕様
- 配信先: YouTube ラジオ
- 出演者:
  - ずんだもん (A): 好奇心旺盛、視聴者代表として「えーっ？」と驚く役
  - 四国めたん (B): 解説役、専門知識を分かりやすく伝える
- 雰囲気: 「驚き」と「学び」のバランス
- 視聴ターゲット: 知的好奇心の高い社会人

# あなたの仕事
リサーチ素材を元に、30分ラジオ番組の企画書を書いてください。

企画書には以下の構成が必要です:
- 番組タイトル（視聴者がクリックしたくなるもの）
- イントロ（最初の 2 分で視聴者の関心をつかむフック）
- 深掘りトピック × 3（各 7-8 分）
- まとめ（視聴後のアクションを示唆）

各トピックには:
- 魅力的なタイトル
- 「実は〇〇」というフック
- 根拠となる事実（3-5 個、出典タグ付き）
- そのトピックのトーン（驚き / 議論 / 解説 など）

# 重要なルール
番組の信頼性を保つため、企画書の各事実には必ず以下のタグを付けてください:
- [AAA] 公的機関・論文（最も信頼できる）
- [AA] 大手メディア・企業公式
- [A] 業界メディア
- [B] 出典曖昧（使う場合は「とされる」「報じられている」等の表現で）

リサーチ素材にない情報は絶対に補足しないでください。
B 級の主張は慎重に扱い、A 以上の主張を優先してください。

# リサーチ素材
{cleaned_research}

# 出力（JSON）
{schema}
```

#### 思考漏出を防ぐ工夫

- 「企画書」という創造的フォーマットを提示
- 出力フォーマットは最後に置く（先に「業務」を理解させる）
- ルールを「番組の信頼性のため」という文脈で書く（業務的な必然性として）

---

### 13.3 Phase C の並列実行設計

#### 設計: 段階的並列 + Semaphore + リトライ

#### 並列の構造

```
Time →
─────────────────────────────────────────
intro      ████              (並列開始)
topic_1    ████              (並列開始)
topic_2    ████              (並列開始)
topic_3    ████              (並列開始)
                  ──────
conclusion          ████     (intro + topics 完了後)
```

intro と各 topic は完全独立 → 並列実行
conclusion は他のセグメント情報を参照 → 最後に sequential

#### 実装案

```python
async def generate_all_segments(
    show_spec: ShowSpec,
    config: Config,
) -> List[ScriptSegment]:
    # vLLM の max_num_seqs に合わせて並列度を制限
    semaphore = asyncio.Semaphore(config.max_concurrent_llm_calls)  # 例: 4

    # Step 1: intro と topics を並列実行
    parallel_tasks = [
        _generate_with_retry(show_spec.intro_spec, "intro", semaphore),
        *[
            _generate_with_retry(topic, f"topic_{i}", semaphore)
            for i, topic in enumerate(show_spec.topics)
        ],
    ]

    parallel_results = await asyncio.gather(
        *parallel_tasks,
        return_exceptions=True
    )

    # Step 2: 失敗を判定、フォールバック適用
    intro = _resolve_or_fallback(parallel_results[0], "intro")
    topics = [
        _resolve_or_fallback(r, f"topic_{i}")
        for i, r in enumerate(parallel_results[1:])
    ]

    # Step 3: conclusion を sequential で生成（他セグメントの情報を渡す）
    conclusion = await _generate_with_retry(
        show_spec.conclusion_spec,
        "conclusion",
        semaphore,
        prior_segments=[intro] + topics,
    )

    return [intro] + topics + [conclusion]


async def _generate_with_retry(
    spec, segment_id, semaphore, max_retries=2,
):
    async with semaphore:
        for attempt in range(max_retries + 1):
            try:
                return await _generate_segment(spec, segment_id)
            except Exception as e:
                if attempt == max_retries:
                    raise SegmentGenerationError(segment_id, e)
                await asyncio.sleep(2 ** attempt)  # exponential backoff
```

#### エラーハンドリング戦略

| 失敗パターン | 対処 |
|---|---|
| 1セグメント失敗 | 自動リトライ（2回） |
| リトライ後も失敗 | テンプレートのフォールバック台本で継続 |
| 全セグメント失敗 | パイプライン全体を中断、明示的にエラー |
| Semaphore 取得失敗 | タイムアウト後にエラー |

#### 想定効果

```
現状（直列）: 5セグメント × 約60秒 = 約300秒
新設計（並列）: 1並列バッチ + conclusion = 約120-150秒
削減: 50%
```

---

### 13.4 Phase D の統合設計

#### 設計判断: 「1コール統合」は危険、「並列+順次」が中庸

当初は「FactCheck + FactFix + Metadata を1コールに統合」と設計したが、再考の結果、**1コールに統合するのはリスクが高すぎる**。

**1コール統合のリスク**:
- 3タスクを1コールでやると max_tokens が爆発（24K 以上必要）
- thinking モデルの思考漏出リスクが集中する
- 失敗時の影響範囲が大きい

#### 修正案: 並列+順次の中庸案

```
Time →
─────────────────────────────────────────
FactCheck      ████                  (台本を読む)
Metadata       ████                  (台本を読む、並列)
                    ────
FactFix              ████             (FactCheck 結果を受けて修正)
```

**LLMコール: 3回（同時並列で 2 つ走るので体感は 2 コール分）**

#### 実装案

```python
async def run_quality_gate(
    script: Script,
    cleaned_research: CleanedResearch,
) -> QualityGateResult:
    # Step 1: FactCheck と Metadata を並列実行
    fact_check_task = _run_fact_check(script, cleaned_research)
    metadata_task = _run_metadata_generation(script)

    fact_check_report, metadata = await asyncio.gather(
        fact_check_task,
        metadata_task,
    )

    # Step 2: 修正が必要なら FactFix を実行
    if fact_check_report.has_high_or_medium_issues():
        fixed_script = await _run_fact_fix(
            script,
            fact_check_report,
            cleaned_research,
        )
    else:
        fixed_script = script  # 修正不要

    return QualityGateResult(
        fact_check_report=fact_check_report,
        fixed_script=fixed_script,
        metadata=metadata,
    )
```

#### 各タスクの設計

**FactCheck**:
- 入力: Script + CleanedResearch（信頼度付き）
- 重要: 信頼度タグ付きデータと突き合わせるので精度が上がる
- 出力: FactCheckReport

**FactFix**:
- 入力: Script + FactCheckReport + CleanedResearch
- 修正対象: high / medium のみ（low はスキップ）
- 既存実装の流用が可能

**Metadata**:
- 入力: Script のみ
- FactCheck と並列で実行可能（依存なし）
- 出力: title, description, hashtags, chapters

#### 想定効果

```
現状（直列）: FactCheck → FactFix → Metadata = 約60秒 × 3 = 180秒
新設計（並列）: max(FactCheck, Metadata) + FactFix = 約60秒 + 60秒 = 120秒
削減: 33%
```

---

### 13.5 全体の効果試算

```
現状の ScriptOrchestrator: 約500秒
  - FactExtractor: 60秒
  - TopicCurator: 60秒
  - ShowRunner: 60秒
  - SegmentGenerator × 5: 300秒（直列）
  - MetadataGenerator: 20秒

新設計: 約240-280秒
  - Phase A: 5秒（LLMなし）または 30秒（軽量LLM）
  - Phase B（番組企画）: 60秒
  - Phase C（対話生成、並列）: 120-150秒
  - Phase D（品質ゲート、並列+順次）: 60-90秒
```

**合計約 50% 短縮**。さらに重要なのは、**ハルシネーション抑制が構造的に組み込まれている**こと。

---

## 14. research_pipeline との統合状況（重要な発見）

### 既存仕様書の存在

別チャットで開発中の research_pipeline には、すでに `interface_spec.md v1.5.0` という成熟した仕様書が存在することが判明（2026-05-07 確認）。

GitHub: `https://github.com/09048435844r/life-update-radio-specs/blob/main/interface_spec.md`

### 既に存在する仕様の概要

#### structured_facts（構造化ファクト）

```python
{
  "structured_facts": {
    "key_numbers": [
      {"value": "2.94", "unit": "倍", "context": "...", "source_idx": 3}
    ],
    "key_entities": [
      {"name": "慶應義塾大学医学部", "type": "institution", "role": "...", "source_idx": 1}
    ],
    "surprising_claims": [
      {"statement": "...", "why_surprising": "...", "source_idx": 7}
    ],
    "controversies": [
      {"position_a": "...", "position_b": "...", "source_indices": [2, 5]}
    ]
  }
}
```

#### research_sources の品質情報

- `domain_tier`: AAA / AA / A / B のソース信頼度
- `domain_score`: 数値スコア
- `snippet`: 引用テキスト（Phase 3 タスクで有効化予定）

#### Phase 3 既に実装済み（Windows 機）

`auto_radio_generator` は ScriptOrchestrator Step 0.5 で structured_facts を読み取り、**FactExtractor を完全にスキップして FactSheet を直接生成し TopicCurator に渡す経路** が既に実装済み（commit 確認済み）。

実機検証結果（v1.3.0 / 2026-05-02）:
- FactExtractor LLM 呼び出し: ゼロ
- 合成 structured_facts 13件 → そのまま FactSheet 13 件
- 台本本文 43 ターン中の数値: 41個

### 重要な認識転換

**「Windows 機の auto_radio_generator は、すでに研究パイプライン統合のパスを持っている」**

このドキュメント執筆中、当該チャットの文脈にこの情報がなかったため見落としていた。実態としては:

```
現在の Windows 機:
  research_pipeline → structured_facts → FactExtractor スキップ → ...
                                          （ただし条件付き、フォールバックでFactExtractor復活）

新設計（radio_director）:
  research_pipeline → CleanedResearch → ContentPlanner → ...
                                          （FactExtractor が最初から存在しない）
```

**新設計は research_pipeline がやろうとしていることをより素直に表現する形** になっている。

### 既存仕様と新設計要求の照合

| 提案項目 | 既存仕様での扱い | 状態 |
|---|---|---|
| 構造化された claim リスト | structured_facts (key_numbers, key_entities 等) | ✅ 既存 |
| ソース信頼度（AAA/AA/A/B） | research_sources.domain_tier | ✅ 既存 |
| クロス検証情報 | source_idx で参照可能、複数ソース確認の明示なし | △ 要拡張 |
| ハルシネーションリスクフラグ | なし | ❌ 不足 |
| 視点の多様性 | controversies, surprising_claims | ✅ 部分的にあり |
| 引用と数値の特別扱い | key_numbers, surprising_claims | ✅ 既存 |
| 出版日 | 言及なし | ❌ 不足 |
| 信頼度メトリクス | 件数は明示、品質スコアは暗黙 | △ 要強化 |

### v1.6 として追加提案する項目（優先度: 低、Optional）

既存仕様で十分機能するため必須ではないが、ハルシネーション防止をさらに強化するため:

```python
# 各 key_numbers / key_entities エントリに追加可能なメタデータ
class ClaimMetadata(BaseModel):
    confidence: Literal["high", "medium", "low"]
    # high:   複数ソースで確認できた
    # medium: 単一ソース
    # low:    B級ソースのみ
    
    cross_validated_sources: List[int]
    # 同じ事実を裏付けるソースの source_idx リスト
    # 現状の source_idx (単数) を補完する形
    
    flags: List[str]
    # "highly_specific":     妙に具体的（ハルシネーション特徴）
    # "expert_quote":        専門家の引用
    # "no_publication_date": 出版日不明
    # ...
```

```python
# research_sources に追加
class Source(BaseModel):
    # 既存フィールド（url, title, domain_tier, domain_score, snippet 等）
    publication_date: Optional[str]  # ISO 8601 形式
    # → 台本で「2024年の最新研究によると」等の表現が可能に
```

### 新設計（radio_director）と既存仕様の整合性

新設計は既存仕様 v1.5.0 をほぼそのまま消費できる。Phase A の役割が変わる:

```
旧設計（私の初期提案）:
  Phase A: 軽量LLMで claim 抽出 + ソース信頼度評価

新設計（既存仕様を活かす）:
  Phase A: structured_facts を CleanedResearch に変換するだけ
           （decoder のみ、LLM不要）
```

**Phase A が完全に決定論的処理で済む**。当初の懸念（軽量LLMが必要かも）は解消される。

### 進め方の修正

#### Before（私の初期提案）

```
ResearchOutput スキーマをゼロから設計
  ↓
research_pipeline チームと擦り合わせ
  ↓
両方が実装
```

#### After（既存仕様を活かす）

```
既存 interface_spec.md v1.5.0 をそのまま活用
  ↓
radio_director を structured_facts 消費前提で設計
  ↓
必要に応じて v1.6 で軽微な拡張を提案
```

工数削減: 大（仕様作成のラウンドトリップ不要）

---

## 15. research_pipeline チームへの提案メッセージ

別チャットで開発中の research_pipeline に伝えるためのハンドオフメッセージ:

```markdown
[FROM: radio_director（新台本生成パイプライン）設計チャット]
[TO: research_pipeline 開発チャット]
[件名: 新台本生成パイプライン radio_director の設計について]

# 文脈
auto_radio_generator (Windows) の本運用は維持しつつ、
Mac Studio で radio_director（新台本生成パイプライン）を
ゼロベース設計する方針が決まりました。

新設計の方針:
- FactExtractor を廃止
- TopicCurator + ShowRunner を統合（番組企画フェーズに）
- 並列実行でセグメント生成
- structured_facts を直接消費（条件付きフォールバックなし）

# 結論
interface_spec.md v1.5.0 は新設計の要求をほぼ満たしています。
大きな変更は不要、既存仕様を活かして進めます。

# 軽微な追加提案（v1.6 候補、優先度低）
台本側のハルシネーション防止をさらに強化するため、以下が
あると嬉しい:

1. 各 claim に confidence: Literal["high", "medium", "low"]
   - 「複数ソースで確認できた」= high
   - 「単一ソース」= medium
   - 「B級ソースのみ」= low

2. 各 claim に cross_validated_sources: List[int]
   - 同じ事実を裏付けるソースのリスト（source_idx の配列）
   - 現状の source_idx (単数) を拡張する形

3. 各 claim に flags: List[str]
   - "highly_specific" : 妙に具体的（ハルシネーション特徴）
   - "expert_quote"   : 専門家の引用
   - "no_publication_date" : 出版日不明
   - 等

4. research_sources に publication_date: Optional[str]
   - ソースの新しさを台本で表現できる
     （「2024年の最新研究によると」等）

# 負担と効果の見積もり
これらは Optional フィールド追加で実装可能、後方互換維持。
台本側のハルシネーション検出精度が向上、
番組品質が安定化する効果が期待できます。

# 質問
1. 上記 1-4 の実装可能性と工数感
2. v1.6 として追加するか、別途議論するか
3. 新台本生成パイプライン radio_director の文脈で、
   逆に research_pipeline 側の都合で台本側に伝えておくべきことはあるか
```

---

## 16. research_pipeline チームからの返信と合意事項

### v1.6 実装計画への合意（2026-05-07）

research_pipeline チームから以下の段階的実装方針が提案され、合意:

| Phase | 内容 | 工数 |
|---|---|---|
| **Phase A** | 提案1+2: confidence + cross_validated_sources | 1日 |
| **Phase B** | 提案3a: highly_specific フラグ | 数時間 |
| Phase C | 提案4: publication_date | 2-3日（v1.7+ で慎重に） |
| Phase D | 提案3b: expert_quote | 1日（v1.7+ で慎重に） |

Phase A + B を v1.6 として進める。Phase C・D は後回し。

### confidence ロジックの合意

```python
# research_pipeline 側で実装
if cross_validated_sources >= 2:
    confidence = "high"
elif cross_validated_sources == 1 and tier_score >= 60:  # AAA/AA/A
    confidence = "medium"
else:
    confidence = "low"
```

### research_pipeline からの注意事項4つと radio_director の対応

#### 注意事項1: Variance の大きさ

```
key_numbers: 3〜62件
key_entities: 15〜68件
research_content: 15,761〜40,392字
```

**radio_director の対応**: Phase A に**品質ゲート**を実装。

```python
def run_phase_a(research_output: ResearchOutput) -> Tuple[CleanedResearch, QualityReport]:
    quality = assess_quality(research_output)

    if quality.key_numbers_count < 5:
        log_warning("key_numbers が少ない (5件未満)")

    if quality.key_numbers_count == 0:
        raise InsufficientResearchQualityError(
            "key_numbers が0件。再リサーチを推奨"
        )

    return CleanedResearch(...), quality
```

ハードに失敗させず、警告ログ + ユーザー判断の UX を維持。

#### 注意事項2: Gap-fill 由来の記事

source_idx の大きい記事は Pass3 後の補完情報。

**radio_director の対応**: v1 では特別扱いしない。将来必要なら source_idx の閾値で区別。

#### 注意事項3: structured_facts vs research_content（重要な設計判断）

**radio_director の決定**: **構造化主軸 + 本文をコンテキスト** で進める。

```python
# Phase B のプロンプト設計
{
  "system": "あなたはディレクターです...",
  "user": """
# 主要な事実（必ず台本に組み込んでください）
{structured_facts}

# 背景情報・文脈（参考として活用してください）
{research_content の要約版}

# あなたの仕事
上記を元に番組企画書を書いてください。
事実関係は「主要な事実」セクションを根拠としてください。
背景情報からも引用できますが、その場合は出典を明示してください。
"""
}
```

**核心**:
- structured_facts を「権威ある事実」として扱う
- research_content を「参考情報」として活用
- 両者の優先順位を明確に区別
- これにより FactExtractor 復活を防ぎつつ、情報量を最大化

#### 注意事項4: angle の尊重

**radio_director の対応**: angle を Phase A → B → C で**貫通**させる。

```python
class ShowSpec(BaseModel):
    title: str
    angle: str  # ← research 時の angle をそのまま継承
    arc: str
    topics: List[Topic]
```

angle を「再解釈」「改善」しない。そのまま番組構成のベースに使う。

---

## 17. 品質ゲートと再リサーチの設計（将来拡張）

### 基本方針

将来的に台本パイプラインが「リサーチ不十分」を自動検出して再リサーチをトリガーできる仕組みを目指す。

### 段階的な実装パス

```
v1（今）: 検出のみ、手動対応
  Phase A → 品質レポート → ユーザーが見て判断 → 手動で再リサーチ

v2（中期）: 推奨機能
  Phase A → 品質レポート + 再リサーチ推奨 → ユーザーがワンクリックで実行

v3（長期）: 自動化
  Phase A → 閾値未達なら自動的に再リサーチをトリガー → 結果をマージ
```

### 必要なデータ構造

#### radio_director 側

```python
class QualityReport(BaseModel):
    overall_quality: Literal["sufficient", "warning", "insufficient"]
    metrics: Dict[str, Any]  # key_numbers_count, etc.

    # 再リサーチが必要な場合の推奨情報
    re_research_recommendations: List[ResearchGap]


class ResearchGap(BaseModel):
    severity: Literal["blocker", "warning", "improvement"]
    gap_type: str
    # 例:
    # "insufficient_numbers"
    # "missing_perspective"
    # "low_confidence"
    # "single_source_dominant"

    description: str  # "key_numbers が3件のみ。最低5件必要"
    suggested_queries: List[str]  # 補完のための具体的な検索クエリ
    target_field: str  # どのフィールドを補完したいか
```

#### research_pipeline 側で必要な API（v2 以降）

```python
# 既存: 全体リサーチ
research_pipeline.run(theme="睡眠と免疫", angle="...")

# 新規: ギャップ補完
research_pipeline.fill_gaps(
    existing_brief=research_brief.json,
    gaps=[
        ResearchGap(
            gap_type="insufficient_numbers",
            suggested_queries=["睡眠不足 免疫低下 統計データ"],
            target_field="key_numbers"
        )
    ]
) -> ResearchBrief  # 補完済み
```

### 各層の責任

```
radio_director:
  - 品質を評価する（何が足りないか判断）
  - 不足の種類を分類する（数値不足 / 視点不足 等）
  - 補完用のクエリを生成する（テーマに沿った具体的検索語）

research_pipeline:
  - ギャップ補完リサーチを実行する
  - 既存データを破壊せずマージする
  - 重複検出（既に取得済みの情報は除外）
```

### v1 段階での実装範囲

```
✅ Phase A で品質レポート生成
✅ ログ警告 + ユーザー判断
❌ research_pipeline.fill_gaps の API は v2 以降
```

v1 では radio_director 側の品質評価機能のみを実装。research_pipeline 側の対応は不要。

---

## 18. 更新版: research_pipeline チームへの返信メッセージ

```markdown
[FROM: radio_director（新台本生成パイプライン）設計チャット]
[TO: research_pipeline 開発チャット]
[件名: v1.6 提案への返信と新パイプライン設計方針]

# v1.6 実装への合意

## 進める項目（v1.6）
✅ 提案1+2: confidence + cross_validated_sources（Phase A、1日工数）
✅ 提案3a: highly_specific フラグ（Phase B、数時間）

→ 提案された段階的実装方針に合意します。

## 後送りに合意する項目
🟡 提案3b (expert_quote) → v1.7 以降で慎重に検討
🟡 提案4 (publication_date) → v1.7 以降で慎重に検討

publication_date は 60-70% 取得率でも radio_director 側は許容します。
台本表現で「最近の研究によると」等にフォールバックできるためです。

# 4つの注意事項への対応方針

## 1. Variance の大きさ
radio_director の Phase A に品質ゲートを実装します:
- key_numbers < 5: 警告ログ、続行
- key_numbers == 0: エラー、ユーザーに再リサーチを促す
ハードに失敗させない UX で対応します。

## 2. Gap-fill 由来の記事
v1 では特別扱いしません。
将来必要になれば source_idx の閾値で区別する方針で対応可能です。

## 3. structured_facts vs research_content（重要な設計判断）
radio_director は **構造化主軸 + 本文をコンテキスト** で進めます:
- structured_facts: 「権威ある事実」として台本に必ず組み込む対象
- research_content: 「参考情報」として LLM のプロンプトに含めるが、
  数値・固有名詞の引用元としては structured_facts を優先

これにより:
- ハルシネーション抑制（structured_facts のみを根拠扱い）
- 情報量最大化（research_content も活用）
- FactExtractor が再発しない（追加抽出はしない）

## 4. angle の尊重
angle を radio_director の Phase A→B→C で貫通させます。
再解釈・改善は一切行わず、そのまま番組構成のベースに使います。

# 将来拡張への配慮（v1.7+ で議論したい）

新台本パイプラインは将来的に「リサーチ不十分」を自動検出して
再リサーチを実行する仕組みを目指しています。

## 将来必要になる API（要件として残しておきたい）

```python
research_pipeline.fill_gaps(
    existing_brief: ResearchBrief,
    gaps: List[ResearchGap]
) -> ResearchBrief  # 補完済み
```

## 期待する挙動

- 既存の structured_facts を破壊せず、追加抽出する
- 重複検出（同じ source_idx の数値は除外）
- 補完で取得した source は research_sources の末尾に追加
  （Gap-fill 由来として既に対応されている挙動と同じ）

## v1 段階での要望（最小限）

- Phase A 側で品質レポートを生成し、
  「key_numbers が少ない」等を検出する仕組みは radio_director 側で実装
- research_pipeline は v1 段階では特別な対応不要
- 将来的に fill_gaps API が議論可能であれば、
  radio_director 側の品質ゲート機能を本格化したい

# 新台本パイプライン radio_director の設計概要（共有）

```
Phase A: リサーチ品質層（決定論的）
  - structured_facts → CleanedResearch に変換
  - 品質ゲート（key_numbers 等の検証）
  - confidence/flags の活用

Phase B: 番組企画（1 LLMコール）
  - FactExtractor + TopicCurator + ShowRunner を統合
  - 「ディレクターとして書け」というフレーミング
  - structured_facts を主軸、research_content を文脈として使用
  - angle を必ず参照

Phase C: 対話生成（並列 LLMコール）
  - intro + topic_1〜N を並列実行
  - conclusion は最後に sequential
  - 各 topic に key_facts（confidence 付き）を渡す

Phase D: 品質ゲート
  - structured_facts と台本を突き合わせて検証
  - confidence の低い claim を使った場合は警告
  - 自動修正 + メタデータ生成
```

# 要相談

1. v1.6 の実装完了予定時期は？
   radio_director の実装スケジュールに影響します。

2. Phase A・B の実装後、ベンチマーク結果を共有いただけますか？
   confidence 付与後の信頼度分布を radio_director 設計に反映したいです。

3. 「睡眠と免疫」テーマでの v1.6 実機データを早めに入手できると、
   radio_director の設計検証に使えます。

4. 既存の Gap-fill 機能は内部実装ですが、
   外部から「特定のフィールドを補完して」と指示する API への
   拡張可能性はどう見えますか？

5. 将来 fill_gaps を実装する場合、
   既存の structured_facts に追加するか、
   完全に再生成するか、どちらの方針が研究側として実装しやすいですか？
```

---

## 19. v1.6 最終合意事項（2026-05-07）

### スケジュール確定

```
Day 1 (5/7): Phase A 実装着手
Day 2 (5/8): Phase A テスト + Phase B 実装
Day 3 (5/9 末): ベンチマーク + 仕様書 v1.6 更新 + データ共有
```

### ベンチマーク前提条件の明記

ベンチマーク数値は以下の環境での実測値であることを記録:

```
ハードウェア: ASUS Ascent GX10
              （NVIDIA GB10 Grace Blackwell Superchip / 128GB LPDDR5x）
モデル:       Qwen3.5-122B-A10B-NVFP4 (vLLM)
並列度:       Pass1=8 / Pass2=5
構成:         Mac Studio Proxy 経由
```

**異なる環境では数値が大きく変わる可能性があります**（特に Qwen3-30B-A3B など軽量モデル使用時）。
将来「軽量モデルに切り替えたら挙動が変わった」等の議論時、本記録を参照点として使用。

### 共有データパッケージ（5/9 末予定）

#### メインデータ
- research_brief.json 全体（v1.6 スキーマ）
- 実行ログ（パイプライン全体・vLLM メトリクス含む）

#### 統計サマリー
- confidence 分布（high/medium/low の件数比率）
- cross_validated_sources の分布（最大・平均・中央値）
- highly_specific フラグ発生率

#### highly_specific サンプル（全件提供）
```
当初は 2-3 件と思っていたが、研究側より「全件提供」の提案あり。
理由: 少数事例より多くのサンプルがある方がパターン分析しやすい。

各サンプルに以下を添付:
- 元の文（research_content 内の該当箇所）
- 抽出された structured_facts の該当エントリ
- フラグが立った理由（どのヒューリスティクスにマッチしたか）
```

これは radio_director Phase D（ハルシネーションチェック）の設計に直接活きる情報。

#### 処理時間
- 全体実行時間
- ステージ別内訳（STAGE1/2/3/4）
- Pass1/2/3 それぞれの所要時間
- Gap-fill 発火有無

### structured_facts 主軸設計への補足（重要）

研究側からの指摘:
> structured_facts に含まれない事実が research_content に豊富にある場合、
> 台本生成 LLM が research_content 側の情報を引用するリスクがあります。

**radio_director Phase B プロンプト要件**:
```
「数値・固有名詞・統計を引用する場合は structured_facts から選ぶこと」
```

これを Phase B プロンプトに**必ず明示**する。
忘れずに設計に組み込むこと。

### ResearchGap 型の役割分担合意

v1.7 で fill_gaps API を実装する際の責任分担:

```
severity (radio_director 側):
  - どの gap を優先的に埋めるか
  - 例: blocker / warning / improvement
  - 台本生成可否の判断基準

gap_type (research_pipeline 側):
  - どう検索すべきか
  - 例: missing_topic / missing_fact / outdated_source / low_confidence
  - クエリ生成・検索戦略の根拠
```

両方が揃うと運用がきれいになる。v1.7 議論時の出発点として記録。

### radio_director の使用方針

v1.6 完成後の活用:
1. v1.6 形式の research_brief.json をモックデータとして
   Phase A プロトタイプ実装に使用
2. highly_specific サンプル全件を Phase D の設計検証に活用
3. confidence 分布を Phase B プロンプトの「優先度ロジック」に反映

---

## 20. バージョン履歴

| バージョン | 日付 | 変更内容 |
|---|---|---|
| 0.1.0 | 2026-05-07 | 初版（セクション 1-7、SegmentGenerator 議論まで） |
| 0.2.0 | 2026-05-07 | TopicCurator/FactExtractor 役割整理、ゼロベース再設計、Mac Studio 移行戦略を追加（セクション 8-12） |
| 0.3.0 | 2026-05-07 | 各 Phase の詳細設計案を追加（セクション 13） |
| 0.4.0 | 2026-05-07 | research_pipeline 既存仕様（interface_spec.md v1.5.0）の発見と統合状況を反映（セクション 14-15） |
| 0.5.0 | 2026-05-07 | research_pipeline チームとの v1.6 合意事項、品質ゲートと再リサーチの設計を追加（セクション 16-18） |
| 1.0.0 | 2026-05-07 | v1.6 最終合意事項を反映、ハードウェア前提・データ共有パッケージ・役割分担を確定（セクション 19）。GitHub 管理開始 |
| 1.1.0 | 2026-05-07 | research_pipeline 側の v1.6 実装が当初予定（5/9末）より2日前倒しで完了。実機データを受領し設計に反映（セクション 21） |

---

## 21. v1.6 実機データの反映（2026-05-07）

### 受領データの概要

research_pipeline 側で v1.6 実装が前倒し完了（5/9末予定 → 5/7 完了）。
スモークテスト「睡眠と免疫」テーマでの実機データを受領。

### 受領内容

```
- research_brief.json (38,567字、全116 fact に v1.6 メタデータ付与)
- 詳細実行ログ
- ベンチマーク統計 CSV
- highly_specific サンプル全件
- 利用ガイド (radio_director 側 Phase A/B/D の運用方針)
```

### confidence 分布の実態

```
key_entities:    high=3 / medium=74 / low=0
key_numbers:     high=0 / medium=34 / low=0
surprising_claims: high=0 / medium=5 / low=0

合計: high=3 / medium=113 / low=0
```

### 重要な発見1: key_numbers の cross-validation 率 0% 問題

**当初仮定**:
```
confidence="high":   cross_validated_sources >= 2
confidence="medium": 単一ソース + AAA/A tier
confidence="low":    それ以外
```

**実機の実態**:
```
key_numbers では cross_validated_sources >= 2 が 0件
→ key_numbers の confidence は実質「medium 一択」
```

**原因**:
- `_merge_structured_facts` の dedup キー `(value, unit, context[:30])` が厳格すぎる
- 同じ「2.94倍」でも context の冒頭30字が異なれば別 fact として登録される
- key_entities は `(name, type)` キーで照合できるため一致しやすい

**v1.7 で対応予定**:
- 候補(a): 数値完全一致モード - キー: `(value 数値部分のみ, unit)`
- 候補(b): 数値+context lemmatize モード - キー: `(value, unit, lemmatize(context[:50]))`

### 重要な発見2: highly_specific フラグの false-positive

**実機データ**:
```
発生件数: 2件 / 全 key_numbers 34件 (5.9%)
両方とも nature.com (AAA tier) の Scientific Reports 論文由来
- OR=0.207 (95% CI 下限)
- OR=0.800 (95% CI 上限)
```

**判定**: 両方とも**実際にはハルシネーションではなく、正規論文の95% CI 値**

**学び**:
- highly_specific フラグは「示唆」であって「確定」ではない
- domain_tier との組み合わせで判断する必要がある
- false-positive 率 5.9% は許容範囲

### radio_director Phase B/D 設計の修正

#### Phase B プロンプトの優先度ロジック（修正版）

当初の設計:
```
high の claim を優先 → medium → low はスキップ
```

修正後の設計:
```
1. confidence="high" の claim を最優先
2. confidence="medium" のうち domain_tier="AAA"/"AA"/"A" のもの
3. confidence="medium" のうち domain_tier="B" のもの（慎重に使用）
4. confidence="low" は原則引用回避

key_numbers については特に:
  domain_tier (AAA/AA/A/B) を主要シグナル、confidence は補助シグナル
  v1.7 dedup 改善後に再度 confidence ベースに寄せる
```

#### Phase D 検証ロジック（修正版）

当初の設計:
```
highly_specific フラグ → ハルシネーション疑いとして警告
```

修正後の設計:
```
1. highly_specific フラグ単体では断定しない
2. (highly_specific = true) AND (source_idx の tier = "B") のみ要警告
3. (highly_specific = true) AND (source_idx の tier = "AAA"/"AA"/"A") は許容
   （正規論文の精密値の可能性が高い）
4. confidence="medium" でも domain_tier が高ければ実用上「裏取り済」扱い
5. confidence="low" の claim が台本に使われていたら警告
```

### Phase A 品質ゲートの実装基準

研究側からの「利用ガイド」に基づく実装基準:

```
Phase A 品質ゲート (radio_director):
  1. key_numbers 件数 >= 5 (本実行 34 件 ✓)
  2. confidence="high" + "medium" の比率 >= 80% (本実行 100% ✓)
  3. domain_tier="AAA" + "AA" + "A" の比率 (新規追加判定基準)
  
判定:
  すべてOK → CleanedResearch を生成して Phase B に進む
  どれか NG → 警告ログ + ユーザー判断（再リサーチ推奨表示）
  完全失敗 → エラー終了（key_numbers が 0 件など）
```

### v1.7 議論項目の追記

```
1. dedup ロジックの改善（最優先）
   - radio_director 側で confidence="high" を実用化するために必須
   - 候補(a)/(b) を研究側と相談して決定

2. publication_date の追加
   - 取得率 60-70% でも radio_director 側は許容
   - 「最近の研究によると」等のフォールバック表現で対応

3. expert_quote / no_publication_date フラグ
   - 余裕があれば

4. fill_gaps API の外部公開
   - 再リサーチ自動化のための基盤
```

### 残された質問（research_pipeline 側へ）

```
1. v1.6.0-rc → v1.6.0 への昇格は完了しました（実機データで検証済み）
2. highly_specific 判定ロジックの詳細を Phase D 実装時に共有してほしい
   （同等のロジックを台本中の発言にも適用するため）
3. v1.7 dedup 改善の議論を radio_director の Phase A プロトタイプ完成後に開始したい
```

---

**END**
