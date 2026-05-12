# プロジェクトバックログ

複数リポジトリにまたがる課題、もしくはプロジェクト全体の改善要望を集約。
単一リポジトリ内で完結する課題は当該リポジトリの docs/ 配下で管理する。

各項目は **対象リポジトリ** を明示。Step 4 以降の計画立案時の参照用。

最終更新: 2026-05-12 (Step 7「パイプライン品質改善」完了記録 + Step 8 計画 + 派生課題)

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

## 13. Step 8: Stage II — 研究側 fact 品質強化 (計画)

**対象:** research_pipeline + radio_director (C3)
**優先度:** 中〜高 (Step 7 push 後に着手判断)
**発覚:** Step 7 regression で qwen36 (17.6%) / deepseekv4 (3.7%) が gate fail

### 背景

Step 7 regression で確認した通り、研究テーマによっては Phase D gate
(matched_ratio ≥ 0.30) を超えるための **structured_facts そのものへの
anchor が不足** している。
- deepseekv4 brief: 公式ソース (`deepseek.com` / `github.com/deepseek-ai` /
  `developer.nvidia.com`) は SearXNG に取得されているが、DOMAIN_SCORES 未登録で
  全 B tier 50 に沈下 → Wikipedia 等と同列、structured_facts に量的 anchor なし
- qwen36 brief: `qwenlm.github.io` (公式) は到達せず、`arxiv.org` の Qwen3 Technical
  Report は arxiv.org が DOMAIN_SCORES 未登録のため B tier 50

Step 7 単独では研究側出力の構造的問題 (Pass2 で発明された数値が research_content
に紛れ、structured_facts に存在しない) を救済できない。

### スコープ案

| ID | 内容 | 影響範囲 |
|---|---|---|
| **A3** | DOMAIN_SCORES にベンダー公式を追加。最低限以下を AAA 級 (88-92) に登録: AI モデル系 (`deepseek.com`, `github.com/deepseek-ai`, `qwenlm.github.io`, `api-docs.deepseek.com`, `huggingface.co`, `mistral.ai`, `x.ai`, `openai.com`, `anthropic.com`)、HW 系 (`nvidia.com`, `developer.nvidia.com`, `build.nvidia.com`)、OSS 系 (`github.com` の organization 単位 boost ロジック検討) | research_pipeline (config.py) |
| **B1** | Pass2 プロンプトに「出典記載値以外の数値を生成するな」「サマリー外の機関名・人名を新規に出すな」ハード制約を追加。structured_facts を Pass2 プロンプトに直接注入 (現状は Pass1 結果のみ参照) | research_pipeline (stages/stage3_synthesize.py) |
| **C3** | Phase B post-validation: 出力 ShowSpec の key_claims について、数値が structured_facts に存在し、かつ source_idx が**該当キーワードを含むソース**に整合するかを deterministic check。不整合は warning + Step 7 の gate retry でやり直し | radio_director (phase_b/post_validator.py 新規) |

### 期待効果

- qwen36 / deepseekv4 が gate (matched_ratio ≥ 0.30) を超えるよう底上げ
- A3 でベンダー公式が AAA 計上 → 結果として Pass2 で anchor 可能な数値が増え、
  研究側 fabrication rate が現状の 50-94% → 15-50% に削減見込み
- C3 で Phase B の捏造ソース帰属 (ZICO Trust に医学統計を帰属したような事象) を
  decisive に検出

### 工数目安

1-2 日 (S × 2 案 + M × 1 案)

### 着手前提

- Step 7 (12) の push 完了
- `feature/topic_exclusivity` マージ戦略 (§12 アーキテクト判断保留事項) 確定
- 既存 5 brief regression baseline (`.investigations/2026-05-12-step7-regression.md`)
  が Step 8 完了後の再 regression 比較基準として有効であることを確認

### 受け入れ基準

- regression で qwen36 / deepseekv4 が gate pass (matched_ratio ≥ 0.30)
- barefoot / exo が引き続き gate pass を維持 (回帰なし)
- content quality 検証で抽象退化なし (具体的数値・固有名詞の出現頻度が
  Step 7 と同等以上を維持)

### Stage III / IV (将来検討)

調査レポート §5 の Stage III (`A2` AAA クエリのテーマ別判定 / `A5`
cross-lingual 関連性フィルタ / `B2` Pass2 post-validation) と Stage IV
(`A4` 内容関連性スコア、PDF/CV 判別) は Stage II の効果評価後に判断。

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