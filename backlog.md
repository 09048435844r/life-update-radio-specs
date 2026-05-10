# プロジェクトバックログ

複数リポジトリにまたがる課題、もしくはプロジェクト全体の改善要望を集約。
単一リポジトリ内で完結する課題は当該リポジトリの docs/ 配下で管理する。

各項目は **対象リポジトリ** を明示。Step 4 以降の計画立案時の参照用。

最終更新: 2026-05-10 (運用方針メモ追加 / Step 4 ゲート緩和)

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

**Step 4 / 5 と一緒に対応想定。**

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

## 6. (将来追加項目はここに)

(本運用中に発覚した課題があれば順次追加)

---

## 7. 運用方針メモ (2026-05-10 追記)

### 7.1 レビューサイクルの軽量化

小改善 (単一リポジトリ完結 / append-only / 互換性破壊なし):
  調査 → Plan (1〜2 行) → 実装着手

大きな構造変更 (複数リポジトリ影響 / 互換性破壊リスク / 新規モジュール):
  調査 → Plan (フル) → アーキテクトレビュー → 実装着手

### 7.2 ゼロリライト検討シグナル

将来、以下のうち 2 つ以上が同時に観測されたら、リライトを選択肢として
真剣に検討する。今すぐの判断材料ではなく観測アンテナとして記録:

- 1 つの改善を入れるのに、無関係な 3 箇所以上を触る必要が出始めた
- backlog 項目が「同じ根本原因」を別角度で記述したものばかりになった
- 新しい本運用課題が「既知の構造的制約」に毎回ぶつかる
- SSOT (interface_spec.md) が現実とズレ始め、修正が追いつかない

### 7.3 改善の取り込み方針

本運用で発覚した小改善は append-only で随時取り込む (待たない)。
backlog.md への記録は最小限でよい (1 項目 = 数行)。
肥大化したら Step 4 のような「やめる選択肢」を実行する経験は既にある。
