# プロジェクトバックログ

複数リポジトリにまたがる課題、もしくはプロジェクト全体の改善要望を集約。
単一リポジトリ内で完結する課題は当該リポジトリの docs/ 配下で管理する。

各項目は **対象リポジトリ** を明示。Step 4 以降の計画立案時の参照用。

最終更新: 2026-05-15 (Step 10a「関連性フィルタ強化」完了 + Step 10 section §16 新設 + 旧 §15.3 を §16.3 に再配置)

---

## 1. references=0 件問題

**対象:** radio_director (Phase B/C プロンプト改修)
**優先度:** 中
**発覚:** Step 1 完了報告 (2026-05-09)

**現状:**
Phase B/C が出典タグを `[AAA]` の tier-only 形式で書くため、
citation_normalizer が source_idx を解決できず、
VerifiedScript.metadata.references が常に空になる。

**対応:**
Phase B/C プロンプトに「数値・固有名詞引用時は `[src=N][TIER]` 形式で
source_idx も書くこと」を追加。

**= 即時着手可 (Mac 側プロンプト改修、item 6/7/8 と一緒に扱うのが筋)**

---

## 2. 旧 LLM 経路の物理削除

**対象:** auto-radio-generator
**優先度:** 中 (次の本運用が安定して 1 本回った直後、本運用とは分離して着手)
**発覚:** Step 3 完了報告 (2026-05-09)

**Step 3 で `@deprecated` 警告付き残置にした項目を物理削除する:**
- `services/research/` (PerplexityResearcher)
- `services/script_generation/gemini_client.py` の `GeminiClient.generate`
- `services/cost_calculator.py`
- `core/interfaces/script_generator.py`、`researcher.py`
- `core/models/usage.py` の `GeminiUsage` / `PerplexityUsage` 部分
- `services/pipeline/research_phase.py`、`scripting_phase.py`
- 旧 Generator タブ UI の Deprecated アコーディオン全体
- `main.py` の `--phase research/script/all` 経路
- `run_workflow_sync` の `theme` / `avoid_topics` / `second_mode` 引数

**追加で発覚した連動先:**
- `services/pipeline/scripting_phase.py` 内の `ResearchSource` import (3 箇所)
- `core/models/research.ResearchSource` は publishing が依存中、
  別モデル置換 or publishing 側のシグネチャ調整が必要

**ゲート緩和の経緯 (2026-05-10):** 「連続 10 回成功」ゲートは Yuru-Stoic
と矛盾し、ゲート自体が目的化していたため撤廃。本運用と分離して着手すれば
破壊的変更でも運用に支障は出ない。

**= Step 4 (v2)**

**完了: 2026-05-10 (feature/v2-remove-gemini-script-path → main マージ済)**

実装中の依存関係調査で以下が判明し、Yuru-Stoic 方向に縮退:
- `services/pipeline/scripting_phase.py`: HITL タブが必須使用 → 物理削除撤回、`@deprecated` 注記のみ
- `services/pipeline/research_phase.py`: `GeminiClient.create_research_plan` 依存を `queries=[theme]` のシンプル経路に refactor して解消
- `visual_palette_generator.py` / `image_prompt_generator.py`: production pipeline で使用 → 削除撤回
- `core/interfaces/script_generator.py` (`IScriptGenerator`): OpenAI/Anthropic/Ollama が実装 → 削除撤回

最終 pytest: 312 passed, 0 failed。外部台本モード E2E 確認済。
詳細: `auto_radio_generator/docs/step4_implementation_plan.md` (v1.1)

---

## 3. サムネイル生成 LLM のローカル化

**対象:** auto-radio-generator (services/media_processing/thumbnail_generator.py 等)
**優先度:** 中 (Step 4 と並行 or 後)
**発覚:** Step 3 完了報告 (2026-05-09)

**現状:**
サムネイル背景画像 (FLUX.1) の生成プロンプト (英語) を Gemini API で
動的生成している。FLUX.1 自体はローカル (Windows 機の RTX 4070) だが、
プロンプト変換が外部 API 依存。

**対応:**
Mac Studio Proxy (port 11435) → vLLM (Qwen3 系) を呼び出して
英語プロンプトを生成する経路に置換。

**作業量:** 小 (~2-3 時間想定)

**= Step 5 (Step 4 と一緒に着手推奨)**

**完了: 2026-05-10 (commit `24f200d` / auto_radio_generator main)**

`ImagePromptGenerator` の Gemini API 直叩き (`google.genai`) を
`LLMAdapterFactory.create(config, "ollama")` 経由の Mac Studio Proxy
(port 11435 → vLLM Qwen3.5-122B) に置換。

- 対象: `services/script_generation/image_prompt_generator.py`
  - `generate_prompt()` / `generate_thumbnail_prompt()` の両メソッド
  - `from google import genai` import 完全削除 (静的検査で確認済)
- フォールバック (`_get_fallback_*_prompt`) は現状維持
- 新規テスト: `tests/test_image_prompt_generator.py` (+4 件)
- 既存回帰: `tests/test_thumbnail_regeneration.py` 5 件 PASS

---

## 4. 起動時の依存サービス事前チェック

**対象:** auto-radio-generator
**優先度:** 中
**発覚:** 本運用 1 本目 (2026-05-09)

**現状の課題:**
本運用 1 本目で ComfyUI 未起動状態で動画生成を開始し、セグメント背景画像が
5 回連続で接続失敗 → static フォールバック発生。

**現状のチェック実装:**
- VOICEVOX サーバー: 起動チェックあり ✓
- ComfyUI サーバー: **起動チェックなし** ← 問題
- Mac Studio Proxy (port 11435): 起動チェックなし

**求める機能:**
動画生成開始時に依存サービスをヘルスチェック、未起動なら警告/エラー表示:

1. VOICEVOX サーバー (既存維持)
2. ComfyUI サーバー (新規) — port 8188 へのヘルスチェック
3. (任意) Mac Studio Proxy — 外部台本モードでは不要、旧 LLM 経路で必要

**実装規模:** 小〜中
- `services/media_processing/comfyui_client.py` にヘルスチェックメソッド追加
- 既存 VOICEVOX チェックと同じパターンで実装
- Gradio UI でステータス表示 (緑/赤)

**= Step 6 (運用改善、Step 4 + 5 と並行で着手可)**

---

## 5. Mac 側 time_estimator の精度向上

**対象:** radio_director
**優先度:** 低
**発覚:** 本運用 1 本目 (2026-05-09)

**現状:**
本運用 1 本目で Mac 側 chapters の予想時刻と実動画の VOICEVOX 出力時刻に
**2.5 倍の乖離** が発覚:

- VerifiedScript 予想 (chapters): 4:50 で完結 (約 5 分)
- 実動画 (VOICEVOX 合成後): 10:52 で完結 (約 12 分)

VOICEVOX で再計算するため正常動作だが、Mac 側予想精度が低い。

**対応:**
- Mac 側で turn ごとの推定発話時間係数を VOICEVOX 実測値ベースに調整
- もしくは Mac 側 chapters 生成自体を廃止し、VOICEVOX 側のみで計算

**作業量:** 小

**= Step 6 候補**

---

## 6. Phase C 完全 sequential 化 (連続性向上)

**対象:** radio_director (Phase C)
**優先度:** 中〜高
**発覚:** 本運用 1 本目レビュー (2026-05-10)

**現状:**
intro / deep_dive_0/1/2 を並列、conclusion のみ sequential。各 segment が
前の実テキストを参照しないため「ミニ完結番組」化、自然なブリッジが弱い。

**対応:**
intro → dd0 → dd1 → dd2 → conclusion を全直列化、各 segment が前の全
segment の実テキストを context として受け取る。所要時間 102s → ~250-300s。

**設計判断:**
完全 sequential を採用 (品質重視、Yuru-Stoic 的に部分並列は特殊ロジック増、
§11.1 の小改善判定: radio_director 単一 / append-only 可)。

**= 即時着手可 (Mac 側完結)**

---

## 7. Phase B 話題排他性強化 + Phase D 重複検出

**対象:** radio_director (Phase B プロンプト + Phase D)
**優先度:** 中
**発覚:** 本運用 1 本目レビュー (2026-05-10)

**現状:**
Phase B が生成する 3 topic 間で内容範囲・key_claims に重複が生じる
可能性。実機データ §24 では未検証。

**対応:**
- Phase B プロンプトに「3 つの topic は内容範囲が重複しないこと」「topic 間
  は階層 / 対比 / 深さ のいずれかで明確に区別」を追加
- Phase D に `topic_overlap_warning` を新規追加 (key_claims source_idx
  重複率測定、警告のみ)

**= 即時着手可 (Mac 側完結)**

---

## 8. キャラクター口調管理 (致命的バグ対処)

**対象:** radio_director (Phase C プロンプト + Phase D)
**優先度:** 高
**発覚:** 本運用 1 本目レビュー (2026-05-10)

**現状の課題:**
1. **致命的**: speaker B (四国めたん) が「〜なのだ」「〜のだ」語尾を使う
   ケースが発生。本来 ずんだもん (A) 専用。
2. ずんだもん「なのだ」、めたん「ですわ」を過剰使用、語尾が単調。
3. キャラ名の表記揺れ (例: 「四国メタン」)。

**対応 (二段構え):**
- Phase C プロンプト: ずんだもん「なのだ」は 30-50% に抑制、めたんは
  「のだ」語尾**禁止**を明記、語尾バリエーション (「ですね」「ですよ」等)
  を許可
- Phase D 決定論検証: `wrong_speaker_voice` (誤キャラ語尾検出) +
  `character_name_corruption` (表記揺れ検出) を新規 WarningCode に追加
- v1 は警告のみ、自動修正は v2 へ

**運用ルール:** `wrong_speaker_voice` 警告が出たら人間リジェクト→再生成。

**= 即時着手可 (Mac 側完結、優先度高)**

---

## 9. VOICEVOX 感情表現対応 (style_id 台本付与)

**対象:** interface_spec.md (v1.7) + radio_director + auto-radio-generator
**優先度:** 中
**発覚:** 本運用 1 本目レビュー (2026-05-10)

**現状:**
DialogTurn は speaker / text のみ、VOICEVOX は全ターン「ノーマル」で合成。
感情の起伏が音声に反映されない。

**対応:**
- interface_spec.md v1.7: DialogTurn に `style: str = "ノーマル"` 追加
  (Optional、後方互換維持)
- radio_director Phase C: style 選択指示をプロンプトに追加 (許可リストは
  キャラ別、A=8 種 / B=6 種)、Phase C で同時付与 (LLM 1 コール、別フェーズ
  化せず)
- radio_director Phase D: 不正 style 値は決定論で「ノーマル」フォールバック
  + `invalid_style_fallback` warning
- auto-radio-generator: VOICEVOX クライアントに名前→style_id マップ追加、
  欠損時は「ノーマル」フォールバック (旧 verified_script.json も読める)

**§11.1 判定:** 複数リポジトリ影響 + interface_spec.md SSOT 更新 = 大きな
構造変更。アーキテクトレビュー必要。

**= Step 7 (新規、アーキテクトレビュー後着手)**

(本項目は当初 Step 7 候補だったが、Step 7 は 2026-05-12 にパイプライン品質
改善として確定。本項目は将来の Step として温存)

---

## 10. (将来追加項目はここに)

(本運用中に発覚した課題があれば順次追加)

---

## 11. 運用方針メモ (2026-05-10 追記)

### 11.1 レビューサイクルの軽量化

小改善 (単一リポジトリ完結 / append-only / 互換性破壊なし):
  調査 → Plan (1〜2 行) → 実装着手

大きな構造変更 (複数リポジトリ影響 / 互換性破壊リスク / 新規モジュール):
  調査 → Plan (フル) → アーキテクトレビュー → 実装着手

### 11.2 ゼロリライト検討シグナル

将来、以下のうち 2 つ以上が同時に観測されたら、リライトを選択肢として
真剣に検討する。今すぐの判断材料ではなく観測アンテナとして記録:

- 1 つの改善を入れるのに、無関係な 3 箇所以上を触る必要が出始めた
- backlog 項目が「同じ根本原因」を別角度で記述したものばかりになった
- 新しい本運用課題が「既知の構造的制約」に毎回ぶつかる
- SSOT (interface_spec.md) が現実とズレ始め、修正が追いつかない

### 11.3 改善の取り込み方針

本運用で発覚した小改善は append-only で随時取り込む (待たない)。
backlog.md への記録は最小限でよい (1 項目 = 数行)。
肥大化したら Step 4 のような「やめる選択肢」を実行する経験は既にある。

### 11.4 Append-Only 例外: テスト更新の許容条件 (2026-05-12 追記)

原則として既存テストの修正は禁止 (Append-Only)。ただし、既存テストが
「修正対象のバグ挙動」をアサートしていた場合に限り、新挙動に合わせた
テスト更新を許容する。

条件:
1. コミットメッセージで「old buggy behavior を asserting していたケースの
   update」と明示
2. テスト名・趣旨は維持し、assertion 値のみを新基準に合わせる
3. 同一コミット内に新挙動の追加テストも含める

**先例:** Step 7 の C4 (`tests/phase_d/test_number_extractor.py` の
`test_highly_specific_decimal_2` / `test_highly_specific_million_with_round_suffix`
等) / C6 (`tests/phase_c/test_prompt_builder.py` の `_common_directives_present`
等) で発生。いずれもバグ的閾値・旧タグ形式を asserting していた既存テストを
新基準で update した。

---

## 12. Step 7: パイプライン品質改善 (完了 2026-05-12)

**対象:** research_pipeline + radio_director
**優先度:** 高 (本運用品質の構造的問題への対応)
**発覚:** 2026-05-12 調査 (`research_pipeline/.investigations/2026-05-12-quality-investigation.md`)

### 目的

調査で特定した三層問題への **Stage I** 対応:

1. **入口の汚染:** クエリ stale-date 強制 / arxiv・ieee site: 機械的付与 /
   `.edu/.ac.jp/.gov` 内容盲目で AAA 計上 / `domain_scorer` の substring
   suffix match バグ
2. **中間の捏造:** Pass2 が「具体的数値・統計を中心に」と長さ目標を強制
   される一方「出典記載値以外を生成するな」制約が欠落し、structured_facts
   に存在しない数値・固有名詞 (例「Harvard Medical School」「日本スポーツ
   医学会」「n=1,250」「膝衝撃 15-20% 減」) を多数発明
3. **出口の素通り:** radio_director Phase D は warning を積むだけで gate
   を引かず、`verified_script.json` を matched_ratio 0% でも保存。
   `false_positive_candidates` 判定基準 (小数3桁以上 OR 100万以上整数で
   末尾≠000) が実用的な医学・統計数値を全てスルー

### スコープ (Stage I 8 項目 + 派生 1)

| ID | 内容 | 影響範囲 |
|---|---|---|
| **A6** | `domain_scorer` の substring suffix match バグ修正 (`bigGO.jp` が `go.jp` の score 91 を踏む等を防止) | research_pipeline |
| **A7** | `stage1_plan` の queries 正規化で reserved field 名 ("outline" 等) の混入を防止 | research_pipeline |
| **Q1** | DOMAIN_SCORES の `.edu/.ac.jp/.gov/.go.jp` を AAA から降格 (75-80、A tier) | research_pipeline |
| **C6** | Phase C プロンプトのタグ形式を `[src=N]` のみに簡素化、tier/confidence は別 metadata ブロックに分離 | radio_director |
| **C2** | Phase B プロンプト注入直前に `research_content` の数値統計を placeholder 置換 (年号は保護) | radio_director |
| **C1** | Phase D production gate 化: matched_ratio < 0.30 で soft gate → 1 retry → hard fail (`verified_script.failed.json` 隔離) | radio_director |
| **C4** | `_is_highly_specific` 拡張: 閾値 100/小数1桁以上、% と統計量表記 (n=/OR=/p<等) を specific 扱い。`PHASE_D_UNMATCHED_AS_FP_CANDIDATE=True` で unmatched 全件を fp_candidate に積む | radio_director |
| **C5** | Phase B prompt 上限 (40k chars) を超えたら structured_facts を confidence 優先で上位 K 件に絞り再構築 (diabetes2 の 53k → 400 Bad Request 対策) | radio_director |
| 派生 | `citation_normalizer` に `[src=N]` 単独形式の認識を追加 (C6 の補完、regression で発覚) | radio_director |

### コミット (9 本、未 push)

**research_pipeline (main):**
- `56084ac` fix: domain_scorer の substring suffix match バグ修正 (A6)
- `542a2fd` fix: stage1_plan の queries 正規化で field 名混入を防止 (A7)
- `76ded3b` chore(config): DOMAIN_SCORES の `.edu/.ac.jp/.gov/.go.jp` を AAA から降格 (Q1)

**radio_director (feature/topic_exclusivity):**
- `b5e3164` fix(phase_c): タグ形式を `[src=N]` のみに簡素化 (C6)
- `1d4a4db` feat(phase_b): research_content の数値統計を placeholder 置換 (C2)
- `ab3ef61` feat(phase_d): matched_ratio < threshold で soft gate (C1)
- `d75bd01` feat(phase_d): highly_specific 判定を拡張、unmatched を fp_candidate に (C4)
- `f63c159` feat(phase_b): prompt サイズガード (C5)
- `0148090` fix(phase_d): citation_normalizer に `[src=N]` 単独形式を追加 (C6 補完)

### 結果 (5 brief regression、再走は radio_director のみ)

| label | matched_ratio (before → after) | 改善倍率 | 結果 |
|---|---|---|---|
| barefoot | 9.5% → **50.0%** | 5.3x | ✅ gate pass |
| exo | 4.4% → **42.4%** | 9.5x | ✅ gate pass |
| qwen36 | 5.4% → 17.6% | 3.3x | ❌ gate fail (Stage II 必須) |
| deepseekv4 | 0.0% → 3.7% | ∞x | ❌ gate fail (Stage II 必須) |
| DGX | n/a | — | ❌ Phase B 安定性 (Step 7 外、§14 参照) |

**4/5 ブリーフで設計通り作動:** 「清いブリーフは gate pass、汚いブリーフは
正しく gate fail」。DGX は Step 7 外の確率的失敗。

### Content quality 検証 (spot-check)

barefoot の捏造構造 (Harvard Medical School / 日本スポーツ医学会 / n=1,250 /
膝衝撃 15-20% 減 / 足底筋 25% 増 等) は after で完全に消失し、
structured_facts 由来の実数値 (「足部の内在筋 22 個」等) で構成される
自然な対話に置き換わった。台本の抽象退化なし。
exo も同様に Mac 5 台 (実数値) / 2024 年 / `[src=11]` 形式の正しい引用で
構成され、`[AAA][medium]` 付与なし。

### ガード機能の初稼働

- `false_positive_candidates`: 7 件中 7 件で 0 → 5-70/script (C4 が機能)
- `citation_tags_total`: 0 → 7-9/script (citation_normalizer fixup 後の再カウント)
- `topic_overlap_warning`: barefoot で Jaccard=1.0 が解消、exo は引き続き発火

### 詳細レポート

`research_pipeline/.investigations/2026-05-12-step7-regression.md`

### アーキテクト判断保留事項

- **マージ戦略:** radio_director の Step 7 commit は `feature/topic_exclusivity`
  ブランチ (Step 7 着手時点で main より 3 commit ahead、§6/§7/§8 関連の
  Phase B/C/D 強化を含む) の上に積んだ。本ブランチ全体 (8 commits) を 1 PR
  でマージするか、§6/§7/§8 と Step 7 を分けて段階マージするかは要判断。
- **push タイミング:** ユーザーが手動 push (現状は未 push)

---

## 13. Step 8: Stage II — 研究側 fact 品質強化 (完了 2026-05-13)

**対象:** research_pipeline + radio_director
**優先度:** 高 (Step 7 の汚いブリーフ救済)
**発覚:** Step 7 regression で qwen36 (17.6%) / deepseekv4 (3.7%) が gate fail

### 目的

Step 7 単独では救済できない汚いブリーフ (research_pipeline 側の structured_facts
そのものへの anchor 不足) を、入口・中間・出口を強化して底上げする:

1. **入口**: クエリの stale-year ハードコード撤廃 (A1)、ベンダー公式の AAA tier 化
   (A3)、Gap-fill 拒否文言 / PubMed AAA 自動加算など 2026-05-13 exo 本運用失敗
   カスケードを起点とする緊急修正 (A8 / A9)
2. **中間**: Pass2 制約強化 + structured_facts 直接注入 (B1) で「サマリー外の
   数値・機関名を新規に出すな」をハード化
3. **出口**: Phase B 出力の source attribution validator (C3) と Phase D 数値
   マッチャー正規化 (P1) で偽陽性検出と偽陰性削減

### スコープ (Stage II 7 項目)

| ID | 内容 | 影響範囲 |
|---|---|---|
| **A1** | クエリ stale-date 動的注入 (`date.today()` 起点、ハードコード「2023-2025年」撤廃) + post-process フィルタ | research_pipeline (stage1_plan) |
| **A3** | DOMAIN_SCORES にベンダー公式を計 22 件追加 (deepseek.com / qwenlm.github.io / nvidia.com / developer.nvidia.com / openai.com / anthropic.com / mistral.ai / x.ai / ai.meta.com / huggingface.co / 他 + pubmed.ncbi.nlm.nih.gov の維持) | research_pipeline (config.py) |
| **B1** | Pass2 プロンプトに「出典記載値以外の数値・固有名詞を本文に書くな」ハード制約を追加、structured_facts を Pass2 prompt に直接注入。長さ pressure を「fact 数 × 200 文字」目安に緩和 | research_pipeline (stages/stage3_synthesize.py) |
| **A8** (v2 追加) | Gap-fill クエリ生成で LLM 拒否文言の混入を防止 (長さ制限 + 拒否パターン blacklist)。2026-05-13 exo 本運用失敗 (`"The provided research material does not contain..."` が query として通過) を起点 | research_pipeline (stage1_plan) |
| **A9** (v2 追加) | PubMed 結果の AAA tier 自動加算を廃止、通常の domain_scorer + 関連性フィルタ経路を通す。非医学テーマで偶然マッチした医学論文 (ICAMP 等) の AAA 混入を防止 | research_pipeline (stage2_fetch) |
| **C3** | Phase D post-validation: ShowSpec.key_claims の数値・固有名詞が structured_facts または `source_idx` が指すソースの snippet/title に整合するかを deterministic にチェック、不整合は `source_attribution_mismatch` warning | radio_director (phase_d/source_attribution_validator.py 新規) |
| **P1** (v2 追加) | Phase D 数値マッチャーのトークン化正規化 (NFKC 全角→半角・スペース除去・カンマ除去・日本語単位剥がし)。"1000 億" (script) vs "1000億パラメータ" (SF) の偽 unmatched を解消 | radio_director (phase_d/hallucination_detector.py) |

### コミット (7 本)

**research_pipeline (main):**
- `d00bdbe` feat(stage1_plan): 現在日時を動的注入し stale-date クエリを除去 (A1)
- `4598875` feat(config): AI/HW ベンダー公式を DOMAIN_SCORES に追加 (A3)
- `bb4a500` feat(stage3): Pass2 に structured_facts を直接注入し捏造禁止制約を追加 (B1)
- `54e8780` fix(stage1_plan): Gap-fill クエリ生成で LLM 拒否文言の混入を防止 (A8)
- `2319dbb` refactor(stage2_fetch): PubMed 結果に関連性フィルタを適用 (A9)

**radio_director (main):**
- `a819aa4` feat(phase_d): source attribution validator を追加 (C3)
- `c804bf1` fix(phase_d): 数値マッチャーのトークン化を正規化 (P1)

### Regression 結果 (5 brief、postscript Phase 4 込み)

| label | matched_ratio (Step 7 → Step 8) | 結果 | 備考 |
|---|---|---|---|
| **qwen36** | 17.6% → **47%** ★ | ✅ gate pass | Step 7 比 **2.7x** (主目標達成) / citation 21 件 全 normalized / C3 source_attribution 多数発火 |
| **barefoot** | 50% → **50% 維持** | ✅ gate pass | citation 13 → 22 件 (P1 の正規化で偽 mismatch 削減) |
| **DGX** | Phase B fail → **93%** | ✅ gate pass (postscript Phase 4) | ※ §14.3 stochasticity 観察を参照 |
| **exo** | 42% → **47%** | ✅ gate pass (postscript Phase 4) | Step 9a (§15.1) の thumbnail truncate fallback が実機発火して完走 |
| deepseekv4 | 0% → 評価不能 | ❌ pre-existing pydantic bug | `KeyNumber.unit: str` が None を拒絶、§15.2 残課題 |

→ **4/5 brief で gate pass**、qwen36 主目標達成、exo は Step 9a 連携で完走。deepseekv4 のみ別 Step 課題。

### Content quality 検証 (spot-check)

qwen36 で **matched 0% → 47%** に飛躍。C3 source_attribution が「Phase B の当てずっぽう source_idx 帰属」を多数検出 (e.g. claim 数値が structured_facts にも source snippet にも無いケース)。citation_tags 21 件すべて [src=N] 形式で正規化。
barefoot は P1 の正規化により citation_tags 13 → 22 件に増加 (script-fact 偽 mismatch が削減され、LLM がより多くの引用を入れた)。

### Phase 1 A1 toggle 実験の発見 (postscript)

DGX cascade の原因切り分けで `STAGE1_STALE_YEAR_FILTER_ENABLED=False` 実験を実施したが、key_numbers=0 の挙動は変わらず → **A1 単独では DGX cascade の原因ではない**ことが確定。
真因は article fetch のランダム性 + 関連性フィルタの aggressive 除外と推定 (Stage III 候補)。

### 未 push 時の派生発見 (v1 → v2 拡張)

2026-05-13 exo 本運用の失敗カスケードを観測:
1. STAGE1 Gap-fill で LLM が自然文の拒否文言を返却 → query として通過
2. これが PubMed に送信され、偶然マッチで医学論文 (ICAMP) 4 件取得
3. PubMed 結果が内容判定なしで AAA tier 集計され、structured_facts を支配
4. Pass2 が ICAMP 数値を exo 文脈に強引に織り込み、Phase D matched_ratio = 0%

→ A8 (拒否文言フィルタ) / A9 (PubMed 内容判定経路化) / P1 (数値正規化) を v2 で追加。

### アーキテクト判断 (実施済)

- 同時 push (Step 8 + postscript Phase 9a を一括) を採用
- §15.1 (Step 9a) も併走 commit として完了 (詳細 §15)

### 詳細レポート

- `research_pipeline/.investigations/2026-05-13-step8-regression.md` (Step 8 v1 → v2 全体)
- `research_pipeline/.investigations/2026-05-13-step8-postscript.md` (Phase 1-4 後始末)

### Stage III / IV (将来検討)

調査レポート §5 の Stage III (`A2` AAA クエリのテーマ別判定 / `A5`
cross-lingual 関連性フィルタ / `B2` Pass2 post-validation) と Stage IV
(`A4` 内容関連性スコア、PDF/CV 判別) は Step 9 / Step 10 完了後に判断。

---

## 14. 派生課題: DGX Phase B 安定性 / VideoMetadata.references 反映

### 14.1 DGX brief で Phase B `thumbnail_title` 安定性問題

**対象:** radio_director (phase_b/planner.py)
**優先度:** 中 (運用で再走対応可)
**発覚:** Step 7 regression (2026-05-12) で再現

**現象:**
DGX brief の director 再走で Phase B planner が `thumbnail_title` を 15 字
制約超過で生成し、内部 retry (`max_attempts=2`) 両方で `ShowSpecParseError`
→ Phase B 全体が失敗。

```
ShowSpecParseError: ShowSpec validation failed:
thumbnail_title String should have at most 15 characters
[input='Mac Studioが爆速？DG...Sparkとの決定的差']
```

**原因推定:**
LLM 温度 + JSON モード起因の確率的失敗。同 brief は 2026-05-11 23:17 の
旧実行で 1 度成功している (`2026-05-11_23-17_dgxsparkmac-studiollm`)。

**対応候補:**
- `max_attempts` 2 → 3 への引き上げ (S 工数)
- 再生成プロンプトに「`thumbnail_title` は必ず 15 字以内」の強調を追加
- thumbnail_title 専用の fallback (元 title を 15 字に切り詰めて使う) を 3 回目以降に許容

Step 7 のスコープ外。本運用で同症状が頻発するなら独立 Step として対応。

**状態:** 2026-05-13 Step 9a (§15.1) で**解消**。Phase B planner に 3 層安定化
(max_attempts 2→3 / retry 時の失敗理由 inline / deterministic 末尾切り詰め
fallback) を導入。exo 本運用で「3 attempts すべて 18 字超過 → truncate fallback
で 15 字に短縮 → Phase B 通過」を実機実証。

### 14.2 VideoMetadata.references の反映 (§1 本丸未対応)

**対象:** radio_director (phase_d/metadata_generator.py + verifier.py 連携)
**優先度:** 中 (Step 8 と並行 or その後)
**発覚:** Step 7 完了後の再確認

**状況:**
Step 7 + citation_normalizer fixup により `metrics.citation_tags_total` は
機能 (barefoot/exo で 7-9/script 検出)。しかし `metadata.references`
(VideoMetadata.references = `list[SourceRef]`) は依然 0 件のまま。

**原因:**
citation_normalizer の出力 (`CitationFinding`) が VideoMetadata.references
に propagation する経路が未整備。metadata_generator は LLM 生成の references
を期待しているが、現状の LLM プロンプトでは references を構造化出力させて
いないため空配列のまま。

**対応:**
- `phase_d/metadata_generator.py` が citation_normalizer の findings を受け取り、
  source_idx をユニーク化して `SourceRef` リストとして構築する (decision 論理)
- LLM コール経由ではなく、Phase D 決定論側で組み立てる方が筋

これにより backlog §1 (references=0 件問題) の本丸が解消される。

**工数目安:** S (~半日)
**着手前提:** Step 8 着手判断時に併せて検討

### 14.3 DGX テーマの bimodal stochasticity 観察 (2026-05-13 追記)

**対象:** research_pipeline 全段 (Stage 1-4) + radio_director 全段
**優先度:** 低〜中 (production リスク評価には必要だが個別ブリーフ救済は別)
**発覚:** Step 8 v2 + postscript Phase 4 を通じた同テーマ複数回実行で軌跡を観察

**観測軌跡** (同一テーマ「DGXSparkとMac Studio、ローカルLLM適性が高いのはどちら？」):

| 実行タイミング | 結果 | matched_ratio |
|---|---|---|
| Step 7 regression (2026-05-12) | Phase B fail (thumbnail_title) | — |
| Step 8 v1 regression (2026-05-12) | Phase B 通過 / gate pass | **64%** |
| Step 8 v2 regression (2026-05-13) | Phase A reject (key_numbers=0) | — |
| Step 8 postscript Phase 4 (2026-05-13) | Phase A-D 完走 / gate pass | **93%** |

**分析:**
- 失敗モードと成功時の数値が大きく振れる
- article fetch の確率的揺らぎ (SearXNG の結果順序 / paywall response) + 関連性
  フィルタの境界線上の挙動が複合した結果と推定
- Phase 1 A1 toggle 実験で A1 単独原因は否定されており、cascade の根本は
  upstream の fetch / filter ロジック

**production リスク:**
1 回の高得点 (93%) を「実装済 = 安定」と判断するのは早計。同 brief を複数回
回した時に variance を測る QA 手法が必要 (§15.3 Step 10 候補で計画)。

**対応の方向性:**
- 短期: §15.3 で同 brief 3-5 回再走の variance 測定を計画
- 中期: 関連性フィルタの cross-lingual 強化 (Stage III A5) / arxiv PDF fallback
  (Stage III A4 / Q5) で article fetch の偽陰性を削減

**追記 (2026-05-14):** 安定性ベンチマークで DGX 以外のテーマ (mindfulness で
81% → 53% → 47%、sake で 71% → 37%) でも同様の variance を観察。bimodal
stochasticity は **DGX 固有でなく pipeline 全体の特性**であることが裏付けられた。
定量化は §16.3 (Step 10c 候補) で対応予定。

---

## 15. Step 9: 評価安定化と品質ガード補完 (進行中・部分完了)

**対象:** radio_director (+ research_pipeline の派生課題対応)
**優先度:** 中
**発覚:** Step 8 postscript Phase 4 + 既存派生課題 §14.1 / §14.2

### 15.1 Step 9a: Phase B planner thumbnail 安定化 (完了 2026-05-13)

**背景:** §14.1 派生課題。DGX (Step 7) / exo (Step 8 v1/v2) で
`thumbnail_title` 15 字制約が LLM の確率的失敗で破られ、内部 retry
(`max_attempts=2`) 両方で Phase B fail を起こしていた。

**スコープ:** Phase B planner に **3 層構造** を導入:

| 層 | 内容 | config |
|---|---|---|
| 1 | `max_attempts` を 2 → 3 に増加 | `PHASE_B_PLANNER_MAX_ATTEMPTS = 3` |
| 2 | retry 時に失敗理由を prompt に inline (LLM への明示的フィードバック、例: 「前回の試行で thumbnail_title が 'Mac/iPhoneでGPT-4並み' (18字) で 15字を超えています」) | `PHASE_B_RETRY_INCLUDE_FAILURE_REASON = True` |
| 3 | LLM 全 attempt 失敗時の deterministic な末尾切り詰め fallback (15 字保証) | `PHASE_B_THUMBNAIL_TITLE_TRUNCATE_ENABLED = True` |

実装支援:
- `parser.py` に `parse_show_spec_dict` 新規 (validation 前の dict 段階で planner
  が補正できるよう前段分離)
- planner.py に `_build_failure_reason` / `_is_thumbnail_too_long_error` ヘルパ

**コミット:** `7525910` feat(phase_b): planner の thumbnail_title 安定性を強化
(Step 9 partial) — radio_director main

**テスト:** 新規 9 ケース (`tests/phase_b/test_step9_planner_stability.py`)、
既存 1 件 (`test_two_consecutive_failures_raise`) は §11.4 Append-Only 例外で
`max_attempts=2 + truncate disabled` を明示する形に update。

**実証 (postscript Phase 4):**
exo brief で 3 attempts すべて 'Mac/iPhoneでGPT-4並み' (18 字) を生成 →
**truncate fallback 発火** → 'Mac/iPhoneでGPT-' (15 字に短縮) → Phase B 通過 →
Phase C/D 完走 → **matched_ratio 47%** で gate pass。
Step 7 → 8 v1 → 8 v2 → postscript で「42% → Phase B fail → Phase B fail →
**47%**」と、本 fix が exo を直接救った decisive な実証となった。

**詳細:** `.investigations/2026-05-13-step8-postscript.md` §3 / §4

### 15.2 Step 9 残課題 (未着手)

以下は Step 9 の本体スコープとして将来計画。着手前にアーキテクトレビュー予定。

- **deepseekv4 pydantic bug 解消**: `KeyNumber.unit: str` が None を拒絶
  (Pass1 が日付値で `unit=None` を返すケース)。schema を `str | None` に緩和。
  **interface_spec.md mirror が要るためアーキテクト判断後着手**。
  暫定回避案: research_pipeline 側で `unit=None` を空文字に正規化するか、
  日付値は別カテゴリ (must_cover type="date") にルーティング
- **VideoMetadata.references 反映** (backlog §14.2 / §1 本丸):
  citation_normalizer 出力 (`CitationFinding`) を VideoMetadata.references
  に propagation する経路整備。Phase D 決定論側で組み立てる方が筋
- **P1 単位リスト拡張**: 運用観測で頻出 unmatched があれば
  `PHASE_D_NUMBER_STRIP_UNITS` に追加 (現状 21 単位)

### 15.3 Step 10 候補: stochasticity reduction (計画)

**状態:** 2026-05-14 の STAGE1/2 信頼性調査により Step 10 のスコープが
「STAGE1/2 信頼性強化」に再定義された。本項目 (stochasticity QA) は
**§16.3 (Step 10c 候補) に再配置**。詳細は §16 を参照。

**背景:** §14.3 で観察した DGX bimodal 挙動など、pipeline の確率的揺らぎを
定量化・低減。1 回の高得点 (93%) を「実装済 = 安定」と判断するのは早計。

**スコープ案:**
- 同 brief を 3-5 回再走する benchmark スクリプト
- 各回の matched_ratio / gate triggered / 失敗モードの variance を測定
- variance の高いテーマ象限を特定 → 該当する upstream (関連性フィルタ /
  Pass2 / Stage 2 fetch / etc.) のチューニング候補を浮上させる

**着手前提:**
- Step 9 (§15.2) 完了後の判断
- variance 測定で「3 回中 N 回 gate pass」のような production-grade な評価軸を確立

**工数目安:** M (1-2 日)、計測回数次第で延伸

---

## 16. Step 10: STAGE1/STAGE2 信頼性強化 (進行中・部分完了)

**対象:** research_pipeline (主に stage1_plan / stage2_fetch)
**優先度:** 高 (production 信頼性の根幹)
**発覚:** 2026-05-14 安定性ベンチマーク + STAGE1/2 信頼性調査

### 経緯 (スコープ再定義)

- **2026-05-14 安定性ベンチマーク** (清いテーマ 5 件): 2/5 で Phase A
  InsufficientResearchError (sleep / blackhole)。「清いテーマ → 通る」と
  していた前提が否定され、真のボトルネックが research_pipeline 側の
  **STAGE1 (query 生成) / STAGE2 (fetch + 関連性フィルタ + scoring) の
  信頼性**であることが判明
- **STAGE1/2 信頼性調査** (`.investigations/2026-05-14-stage12-reliability.md`):
  真因確定 — 関連性フィルタ (`_is_relevant`) が失敗 2 ケースで **100% 除外**。
  `_build_relevance_keywords` が多語結合 strong keyword (「高める方法」「ブラック
  ホール観測」等) を生成し、記事 snippet と verbatim 一致しない構造的問題。
  A1 stale-year は副次要因 (H1 toggle 実験で確定)、A8 拒否文言フィルタに
  盲点 (H6: LLM メタ指示文「Output must be a JSON array...」が通過)
- **スコープ再定義**: 当初 §15.3 で「Step 10 = stochasticity QA」と
  していたが、本調査で **「Step 10 = STAGE1/2 信頼性強化」** に再定義。
  stochasticity QA は §16.3 (Step 10c 候補) に再配置

### マイルストーン (Step 7 → 10a の累積成果)

清いテーマで **4/5 (80%) gate pass**、捏造台本の無検査流通は解消、
通らない時も Phase A reject / gate fail で**安全停止**する状態に到達。
本運用再開が可能な水準。

### 16.1 Step 10a: 関連性フィルタ強化 (完了 2026-05-15)

**背景:** STAGE1/2 信頼性調査で特定した 4 系統の問題への対応:
1. 関連性フィルタの多語結合 strong keyword (主因、H2)
2. 全件除外時の救済機構なし (H2 症状緩和)
3. A1 stale-year filter が歴史テーマで誤動作 (副次要因、H1)
4. A8 拒否文言フィルタの盲点 (新規発見、H6)

**スコープ (4 項目):**

| ID | 内容 | 影響範囲 |
|---|---|---|
| **R4** | A8 拒否文言フィルタに LLM メタ指示文パターン追加 (「Output must」「JSON array」「以下のJSON」等 14 パターン) | stage1_plan (config) |
| **A1'** | stale-year filter で歴史年代マーカー (X年代 / X世紀 / 元号X年/時代/の) を除外 | stage1_plan |
| **R1** | `_build_relevance_keywords` を **janome 形態素分割**で強化 (連結句を解体、既存 split と UNION)。`PHASE_B_*` の影響を回避するため Stage2 側で完結 | stage2_fetch |
| **R3** | 関連性フィルタの緊急 fallback (level 2: weak 閾値 2→1 / level 3: domain_score 上位 N 強制採用)。フィルタ完全スキップはしない | stage2_fetch |

**コミット (4 本、research_pipeline main):**
- `6ec4aa3` fix(stage1_plan): A8 拒否文言フィルタに LLM メタ指示文パターン追加 (R4)
- `19c5ec8` fix(stage1_plan): stale-year filter で歴史年代表記を除外 (A1')
- `fd8a607` feat(stage2_fetch): _build_relevance_keywords を形態素分割で強化 (R1)
- `e50a529` feat(stage2_fetch): 関連性フィルタに緊急 fallback を追加 (R3)

**新規依存:** **janome 0.5.0** (pure-python morphological analyzer、pip 単独で
system 依存なくインストール可能)。本アーク (Step 7-10a) で初の新規依存だが、
foundational な関連性フィルタ修正のため正当と判断。heuristic fallback も
併設 (janome 実行時エラー時の保険)。

**Regression 結果 (5 brief、安定性ベンチマークと同テーマ):**

| label | matched_ratio (前回 → 今回) | 結果 |
|---|---|---|
| **sleep** | Phase A reject → **0.757** ★★ | ✅ **決定的救済** |
| **kojiki** | 0.641 → **0.867** (+23pt) ★ | ✅ 大幅改善 |
| mindfulness | 0.529 → 0.467 | ✅ pass 維持 (variance 範囲内) |
| sake | 0.706 → 0.366 | ✅ pass 維持 (variance、§16.3 で追跡) |
| **blackhole** | Phase A reject → Phase A reject | ❌ 部分的改善 → §16.2 へ |

→ **4/5 gate pass** (前回 3/5)。

**Content quality 検証 (sleep):**
script.title「眠れないのではなく『質』が悪い？睡眠の質を劇的に高める最新科…」
で citation 10 件全 normalized、source_attribution_mismatch 1 件のみ。
前回 Phase A reject → 76% で自然な台本生成、抽象退化なし。

**R1-R4 機能発火状況:**
- **R1 が主役**: sleep の関連性フィルタが 40/40 (100% 除外) → 64/17 (通過 17 件)
  に劇的改善。kojiki / mindfulness / sake でも benefit
- **R3 fallback は 0 件発火**: R1 単独で十分機能、dormant backstop として維持
- **A1'**: blackhole で queries 数 4 → 8 件改善 (歴史マーカー除外で復活)
- **R4**: 今回 LLM がメタ指示文を出さず dormant、防御ネットとして残存

**テスト:** research_pipeline 154 tests passed (+56 新規: R4 +15 / A1' +17 /
R1 +16 / R3 +8)、既存破壊なし。

**詳細レポート:** `.investigations/2026-05-15-step10a-regression.md`

### 16.2 Step 10b 候補: 数値希薄テーマの救済 (要調査)

**背景:** blackhole (「ブラックホール観測の歴史と最新成果」) が Step 10a 後も
Phase A reject。関連性フィルタは通過 (48 件除外 → 7 件残、R1 機能) するが、
**Pass1 が key_numbers=0** を返す。

**未確定事項:**
真因が以下のどれか、まだ切り分けできていない:
1. 概念中心テーマは数値が記事に乏しい (Pass1 honesty が正常動作)
2. 通過した 7 記事が topic からズレている (keyword は合うが歴史記事でない)
3. Pass1 が年号 (1916/1971/2019 等) を数値として拾えていない

「観測の歴史」テーマは本来年号が豊富なはずで、key_numbers=0 は不自然。
構造的問題の可能性が高い。

**方針:** **gate (Phase A の key_numbers>=1) を反射的に緩めるのではなく、
まず軽い調査で真因を切り分ける**。Pass1 prompt の改善 / 年号取り扱いの
修正 / 関連性フィルタの精度向上 のいずれが正解かは調査次第。

**着手前提:** 軽調査 (~1h) で真因を特定してから対応を決定

**工数目安:** 調査次第 (Pass1 prompt 調整なら S、構造的問題なら M)

### 16.3 Step 10c 候補: stochasticity QA (計画) — 旧 §15.3 から再配置

**背景:** §14.3 で観察した DGX bimodal stochasticity に加え、2026-05-14
安定性ベンチマークで mindfulness (81% → 53% → 47%) / sake (71% → 37%) でも
同様の variance を観測。同一テーマでも matched_ratio が大きく変動するのが
pipeline 全体の特性。1 回の高得点 (93%) を「実装済 = 安定」と判断するのは
早計。

**スコープ案:**
- 同 brief を 3-5 回再走する benchmark スクリプト
- 各回の matched_ratio / gate triggered / 失敗モードの variance を測定
- variance の高いテーマ象限を特定 → 該当する upstream (関連性フィルタ /
  Pass2 / Stage2 fetch / etc.) のチューニング候補を浮上させる
- 「3 回中 N 回 gate pass」のような production-grade な評価軸を確立

**着手前提:**
- Step 10b (§16.2) の判断後
- 評価軸の整理 (matched_ratio 平均 / 最小 / 完走率 のどれを主指標にするか)

**工数目安:** M (1-2 日)、計測回数次第で延伸