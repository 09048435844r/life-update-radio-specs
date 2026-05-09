#!/usr/bin/env bash
# 本運用フロー: research_pipeline → radio_director を一気通貫実行
#
# Usage:
#   ./run_full.sh --theme "テーマ" --mode lecture --angle "切り口"
#   ./run_full.sh --theme "テーマ"                                # mode=lecture / angle 自動生成
#
# 出力:
#   ~/research_pipeline/output/research_brief_<TS>.json    (リサーチ成果)
#   ~/radio_director/output/<run_id>/verified_script.json  (台本 SSOT)
#
# 失敗時挙動:
#   research_pipeline 失敗 → set -e で即時停止 (radio_director は実行されない)
#   radio_director 失敗   → research_brief は残る (手動で再実行可能)
#
# 注意:
#   依存サービス (Mac Studio Proxy port 11435 / GX10 vLLM port 8000) の
#   起動チェックは未実装 (backlog.md §4 参照)。事前に起動確認すること。

set -euo pipefail

RESEARCH_DIR="$HOME/research_pipeline"
DIRECTOR_DIR="$HOME/radio_director"

MODE="lecture"
ANGLE=""
THEME=""

# 引数パース
while [[ $# -gt 0 ]]; do
    case "$1" in
        --theme) THEME="$2"; shift 2;;
        --mode)  MODE="$2"; shift 2;;
        --angle) ANGLE="$2"; shift 2;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

if [[ -z "$THEME" ]]; then
    echo "Usage: $0 --theme <テーマ> [--mode lecture|debate|voices|trivia|weekly_digest] [--angle <切り口>]" >&2
    exit 1
fi

# 新規 research_brief 検出用タイムスタンプ参照ファイル
TSMARK="$(mktemp)"
trap 'rm -f "$TSMARK"' EXIT

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔬 STAGE 1: research_pipeline"
echo "   theme: $THEME"
echo "   mode:  $MODE"
echo "   angle: ${ANGLE:-(自動生成)}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cd "$RESEARCH_DIR"
RP_ARGS=(--theme "$THEME" --mode "$MODE")
if [[ -n "$ANGLE" ]]; then
    RP_ARGS+=(--angle "$ANGLE")
fi
venv/bin/python main.py "${RP_ARGS[@]}"

# 開始時刻 ($TSMARK) 以降に作成された research_brief を特定
BRIEF="$(find "$RESEARCH_DIR/output" -maxdepth 1 -name 'research_brief_*.json' -newer "$TSMARK" -print 2>/dev/null | sort | tail -1)"

if [[ -z "$BRIEF" ]] || [[ ! -f "$BRIEF" ]]; then
    echo "❌ research_brief が見つかりません。research_pipeline が失敗した可能性。" >&2
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎙️  STAGE 2: radio_director"
echo "   brief: $BRIEF"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cd "$DIRECTOR_DIR"
RUN_DIR="$(.venv/bin/python -c '
import sys
from pathlib import Path
from radio_director.runner import run_pipeline
print(run_pipeline(Path(sys.argv[1])))
' "$BRIEF")"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 完了"
echo "   research_brief:  $BRIEF"
echo "   run_dir:         $RUN_DIR"
echo "   verified_script: $RUN_DIR/verified_script.json"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
