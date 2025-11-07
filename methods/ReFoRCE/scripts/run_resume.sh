#!/usr/bin/env bash
set -euo pipefail

# A resumable end-to-end runner for ReFoRCE with per-step control and log-based skipping.
# Supports:
#   - Resume with an existing timestamp (reuse output/log directories)
#   - Run an arbitrary step range (--from-step/--to-step)
#   - Force re-run specific steps (--force-steps) or all (--force-all)
#   - Azure mode passthrough
#   - Concurrency knobs and safer resume flags
#
# Usage examples:
#   ./scripts/run_resume.sh --task snow --model doubao-seed-1.6-250615
#   ./scripts/run_resume.sh --task snow --model doubao-seed-1.6-250615 --timestamp 20251027-143504 --from-step 6 --to-step 7
#   ./scripts/run_resume.sh --task snow --model doubao-seed-1.6-250615 --from-step 4 --resume-mode --num_votes 4 --num_workers 4

# --- cd to repo/methods/ReFoRCE
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

# --- defaults
TASK="snow"                    # snow|lite|BIRD|spider
API="gpt-4o"
AZURE=false
TIMESTAMP=""
NUM_VOTES=8
NUM_WORKERS=8
MAX_ITER=5
TEMPERATURE=1
THRESHOLD=100000
FROM_STEP=1
TO_STEP=14
FORCE_ALL=false
FORCE_STEPS=""
RESUME_MODE=false               # if true: step 4/6 will add --overwrite_unfinished for safe resume
OUTPUT_PATH_OVERRIDE=""
LOG_DIR_OVERRIDE=""
AUTO_CONTINUE_STEP2=false       # if true: auto-detect start step from 6..14 based on logs and run to the end
REVOTE=false                    # pass --revote to run.py to execute existing SQL to CSV when needed

# --- args
while [[ $# -gt 0 ]]; do
  k="$1"; v="${2-}"
  case "$k" in
    --task) TASK="$v"; shift 2;;
    --model|--api) API="$v"; shift 2;;
    --azure) AZURE=true; shift;;
    --timestamp) TIMESTAMP="$v"; shift 2;;
    --num_votes) NUM_VOTES="$v"; shift 2;;
    --num_workers) NUM_WORKERS="$v"; shift 2;;
    --max_iter) MAX_ITER="$v"; shift 2;;
    --temperature) TEMPERATURE="$v"; shift 2;;
    --threshold) THRESHOLD="$v"; shift 2;;
    --from-step) FROM_STEP="$v"; shift 2;;
    --to-step) TO_STEP="$v"; shift 2;;
    --force-all) FORCE_ALL=true; shift;;
    --force-steps) FORCE_STEPS="$v"; shift 2;;
    --resume-mode) RESUME_MODE=true; shift;;
    --continue-from-step2|--auto-continue-step2) AUTO_CONTINUE_STEP2=true; shift;;
    --revote) REVOTE=true; shift;;
    --output_path) OUTPUT_PATH_OVERRIDE="$v"; shift 2;;
    --log_dir) LOG_DIR_OVERRIDE="$v"; shift 2;;
    --help|-h)
      echo "See script header for usage examples."; exit 0;;
    *) echo "Unknown arg: $k"; exit 1;;
  esac
done

# --- derive timestamp, output and log dirs
if [[ -z "$TIMESTAMP" ]]; then
  TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
fi

if [[ -z "$OUTPUT_PATH_OVERRIDE" ]]; then
  OUTPUT_PATH="output/${API}-${TASK}-log-${TIMESTAMP}"
else
  OUTPUT_PATH="$OUTPUT_PATH_OVERRIDE"
fi

if [[ -z "$LOG_DIR_OVERRIDE" ]]; then
  LOG_DIR="output/${API}-${TASK}-logs-${TIMESTAMP}"
else
  LOG_DIR="$LOG_DIR_OVERRIDE"
fi

mkdir -p "$LOG_DIR"

# --- helper: run command with START/END and log file, capture exit code
run_cmd() {
  local log_file="$1"; shift
  echo "===== START $(date '+%F %T') : $* =====" | tee -a "$log_file"
  set +e
  ("$@") 2>&1 | tee -a "$log_file"
  local status=${PIPESTATUS[0]}
  set -e
  echo "===== END   $(date '+%F %T') : exit=$status =====" | tee -a "$log_file"
  return $status
}

# --- helper: check if step is already successful by log tail
already_done() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  # success line must contain 'exit=0'
  tail -n 2 "$log_file" | grep -q "exit=0" || return 1
  return 0
}

forced_step() {
  $FORCE_ALL && return 0
  [[ -z "$FORCE_STEPS" ]] && return 1
  IFS=',' read -r -a arr <<< "$FORCE_STEPS"
  local needle="$1"
  for s in "${arr[@]}"; do
    if [[ "$s" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

within_range() {
  local n="$1"
  (( n >= FROM_STEP && n <= TO_STEP ))
}

# map step number to log file name
step_log_path() {
  local step="$1"
  case "$step" in
    1) echo "$LOG_DIR/01_spider_agent_setup.log";;
    2) echo "$LOG_DIR/02_reconstruct_data.log";;
    3) echo "$LOG_DIR/03_schema_linking.log";;
    4) echo "$LOG_DIR/04_step1_run.log";;
    5) echo "$LOG_DIR/05_step1_eval.log";;
    6) echo "$LOG_DIR/06_step2_run.log";;
    7) echo "$LOG_DIR/07_step2_eval.log";;
    8) echo "$LOG_DIR/08_step3_run.log";;
    9) echo "$LOG_DIR/09_step3_eval.log";;
    10) echo "$LOG_DIR/10_step4_run.log";;
    11) echo "$LOG_DIR/11_step4_eval.log";;
    12) echo "$LOG_DIR/12_get_metadata_csv.log";;
    13) echo "$LOG_DIR/13_get_metadata_sql.log";;
    14) echo "$LOG_DIR/14_official_evaluate.log";;
    *) return 1;;
  esac
}

# Determine the first step >=6 that is not completed; if all done, returns 15
compute_start_from_step2() {
  local s
  for s in 6 7 8 9 10 11 12 13 14; do
    local lf
    lf=$(step_log_path "$s")
    if ! already_done "$lf"; then
      echo "$s"
      return 0
    fi
  done
  echo 15
  return 0
}

# --- echo configuration
cat <<CFG
Config:
  TASK:             $TASK
  MODEL:            $API
  AZURE:            $AZURE
  TIMESTAMP:        $TIMESTAMP
  OUTPUT_PATH:      $OUTPUT_PATH
  LOG_DIR:          $LOG_DIR
  FROM_STEP ~ TO:   $FROM_STEP ~ $TO_STEP
  NUM_VOTES:        $NUM_VOTES
  NUM_WORKERS:      $NUM_WORKERS
  MAX_ITER:         $MAX_ITER
  TEMPERATURE:      $TEMPERATURE
  THRESHOLD:        $THRESHOLD
  RESUME_MODE:      $RESUME_MODE
  REVOTE:           $REVOTE
  FORCE_ALL:        $FORCE_ALL
  FORCE_STEPS:      ${FORCE_STEPS:-""}
CFG

# --- azure flag passthrough
AZURE_FLAG=()
$AZURE && AZURE_FLAG+=("--azure")

# --- auto-continue from Step 2 run (step >= 6)
if $AUTO_CONTINUE_STEP2; then
  if [[ ! -d "$LOG_DIR" ]]; then
    echo "[auto-continue] Log dir not found: $LOG_DIR" >&2
    exit 1
  fi
  START_S=$(compute_start_from_step2)
  if [[ "$START_S" -le 14 ]]; then
    FROM_STEP="$START_S"
    TO_STEP=14
    echo "[auto-continue] Continue from step $FROM_STEP to $TO_STEP based on logs in: $LOG_DIR"
  else
    echo "[auto-continue] All steps (6..14) already completed. Nothing to do."
    exit 0
  fi
fi

# --- Step 01: spider_agent_setup
STEP=1; LOG="$LOG_DIR/01_spider_agent_setup.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    run_cmd "$LOG" python spider_agent_setup_${TASK}.py --example_folder examples_${TASK}
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 02: reconstruct_data
STEP=2; LOG="$LOG_DIR/02_reconstruct_data.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    run_cmd "$LOG" python reconstruct_data.py \
      --example_folder examples_${TASK} \
      --add_description \
      --add_sample_rows \
      --rm_digits \
      --make_folder \
      --clear_long_eg_des
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 03: schema_linking
STEP=3; LOG="$LOG_DIR/03_schema_linking.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    # pick linked json by task
    LINKED_JSON="../../data/linked_${TASK}_tmp0.json"
    run_cmd "$LOG" python schema_linking.py \
      --task $TASK \
      --db_path examples_${TASK} \
      --linked_json_pth "$LINKED_JSON" \
      --reduce_col \
      --threshold "$THRESHOLD"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- build common run.py flags
build_common_flags() {
  local extra=("--task" "$TASK" "--db_path" "examples_${TASK}" "--output_path" "$OUTPUT_PATH" "--temperature" "$TEMPERATURE")
  echo "${extra[@]}"
}

# --- Step 04: Self-refinement + Majority Voting
STEP=4; LOG="$LOG_DIR/04_step1_run.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    FLAGS=( $(build_common_flags) --do_self_refinement --generation_model "$API" --max_iter "$MAX_ITER" --early_stop --do_vote --num_votes "$NUM_VOTES" --num_workers "$NUM_WORKERS" )
    # safer resume for partially written vote logs
    $RESUME_MODE && FLAGS+=(--overwrite_unfinished)
    $REVOTE && FLAGS+=(--revote)
    FLAGS+=("${AZURE_FLAG[@]}")
    run_cmd "$LOG" bash -lc "python run.py ${FLAGS[*]}"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 05: Eval step1
STEP=5; LOG="$LOG_DIR/05_step1_eval.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    run_cmd "$LOG" python eval.py --log_folder "$OUTPUT_PATH" --task "$TASK"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 06: Self-refinement + Voting + Column Exploration + Rerun
STEP=6; LOG="$LOG_DIR/06_step2_run.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    FLAGS=( $(build_common_flags) --do_self_refinement --generation_model "$API" --do_column_exploration --column_exploration_model "$API" --max_iter "$MAX_ITER" --early_stop --do_vote --num_votes "$NUM_VOTES" --num_workers "$NUM_WORKERS" --rerun )
    # Only add overwrite_unfinished in RESUME_MODE (clean restart for unfinished samples)
    $RESUME_MODE && FLAGS+=(--overwrite_unfinished)
    $REVOTE && FLAGS+=(--revote)
    FLAGS+=("${AZURE_FLAG[@]}")
    run_cmd "$LOG" bash -lc "python run.py ${FLAGS[*]}"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 07: Eval step2
STEP=7; LOG="$LOG_DIR/07_step2_eval.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    run_cmd "$LOG" python eval.py --log_folder "$OUTPUT_PATH" --task "$TASK"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 08: Random vote for tie
STEP=8; LOG="$LOG_DIR/08_step3_run.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    FLAGS=( $(build_common_flags) --do_vote --random_vote_for_tie --num_votes "$NUM_VOTES" --num_workers "$NUM_WORKERS" )
    FLAGS+=("${AZURE_FLAG[@]}")
    run_cmd "$LOG" python run.py "${FLAGS[@]}"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 09: Eval step3
STEP=9; LOG="$LOG_DIR/09_step3_eval.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    run_cmd "$LOG" python eval.py --log_folder "$OUTPUT_PATH" --task "$TASK"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 10: Random vote final_choose
STEP=10; LOG="$LOG_DIR/10_step4_run.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    FLAGS=( $(build_common_flags) --do_vote --random_vote_for_tie --final_choose --num_votes "$NUM_VOTES" --num_workers "$NUM_WORKERS" )
    FLAGS+=("${AZURE_FLAG[@]}")
    run_cmd "$LOG" python run.py "${FLAGS[@]}"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 11: Eval step4
STEP=11; LOG="$LOG_DIR/11_step4_eval.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    run_cmd "$LOG" python eval.py --log_folder "$OUTPUT_PATH" --task "$TASK"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 12: get_metadata CSV
STEP=12; LOG="$LOG_DIR/12_get_metadata_csv.log"
CSV_DIR="output/${API}-${TASK}-csv-${TIMESTAMP}"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    run_cmd "$LOG" python get_metadata.py --result_path "$OUTPUT_PATH" --output_path "$CSV_DIR"
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 13: get_metadata SQL
STEP=13; LOG="$LOG_DIR/13_get_metadata_sql.log"
SQL_DIR="output/${API}-${TASK}-sql-${TIMESTAMP}"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    run_cmd "$LOG" python get_metadata.py --result_path "$OUTPUT_PATH" --output_path "$SQL_DIR" --file_type sql
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

# --- Step 14: official evaluate
STEP=14; LOG="$LOG_DIR/14_official_evaluate.log"
if within_range $STEP; then
  if ! already_done "$LOG" || forced_step $STEP; then
    pushd ../../spider2-${TASK}/evaluation_suite >/dev/null
    run_cmd "$LOG" python evaluate.py --mode exec_result --result_dir ../../methods/ReFoRCE/${CSV_DIR}
    popd >/dev/null
  else
    echo "[skip] step $STEP already done: $LOG"
  fi
fi

echo "All done."
