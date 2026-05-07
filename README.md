# life-update-radio-specs

Life Update Radio プロジェクトの仕様書を一元管理するリポジトリ。

## 概要

Life Update Radio は、リサーチパイプラインと台本生成パイプラインを連携させて YouTube 向けラジオ動画を自動生成するプロジェクト。本リポジトリは両パイプラインの間の契約仕様と各パイプラインの設計仕様を管理する。

## システム構成

```
[research_pipeline] (Mac Studio)
   ↓ research_brief.json (interface_spec.md 準拠)
[台本生成パイプライン] (2系統)
   ├── auto_radio_generator (Windows、既存・フォールバック)
   └── radio_director (Mac Studio、新規構築中)
   ↓ script.json
[メディア生成]
   ↓ 音声合成・動画生成・サムネイル
[YouTube 配信]
```

## 仕様書一覧

| ファイル | バージョン | 役割 |
|---|---|---|
| [`interface_spec.md`](./interface_spec.md) | v1.6.0 | research_pipeline ⇔ 台本生成側の契約仕様 |
| [`radio_director_design.md`](./radio_director_design.md) | v1.1.0 | 新台本生成パイプライン radio_director の設計仕様 |

### interface_spec.md

research_pipeline と台本生成パイプライン（auto_radio_generator / radio_director）の間で交換される `research_brief.json` のスキーマ定義と品質基準を規定する。両チームが本仕様を参照して実装を進める。

主要トピック:
- `research_brief.json` のフィールド仕様
- `structured_facts` の構造（key_numbers / key_entities / surprising_claims / controversies）
- 信頼度メタデータ（confidence / cross_validated_sources / flags）
- ベンチマーク基準値と品質判定基準
- 推論インフラ構成（vLLM / Ollama / Mac Studio Proxy）

### radio_director_design.md

Mac Studio で新規構築する台本生成パイプライン `radio_director` の設計仕様。既存 `auto_radio_generator` の課題分析と廃止・統合判断の記録、および新パイプラインのフェーズ設計を含む。

主要トピック:
- 既存 `auto_radio_generator` のアーキテクチャ分析
- ゼロベース再設計（Phase A〜D）
- Windows 機フォールバック + Mac Studio 新規構築の移行戦略
- v1.6 実機データを反映した Phase B/D 設計
- 将来拡張（fill_gaps API、再リサーチ自動化）

## 仕様変更時のルール

`interface_spec.md` §4 に詳細を記載。要約:

1. 仕様変更を行う場合は本リポジトリを先に更新する
2. 両チームに共有してから実装を進める
3. 互換性破壊を避ける（フィールド追加は Optional、削除は非推奨期間を設ける）
4. バージョン番号を上げる

## バージョニング

セマンティックバージョニングに準拠（MAJOR.MINOR.PATCH）。

- MAJOR: 互換性破壊を伴う変更
- MINOR: 後方互換を保ちつつ機能追加
- PATCH: バグ修正・誤記訂正

## 関連リポジトリ

- `research_pipeline` - リサーチパイプライン本体（Mac Studio 上で稼働）
- `auto_radio_generator` - 既存台本生成パイプライン（Windows、フォールバック）
- `radio_director` - 新台本生成パイプライン（Mac Studio、構築中）
