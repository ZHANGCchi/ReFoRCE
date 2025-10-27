#!/bin/bash
set -e
set -o pipefail
export API_KEY="${API_KEY}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
AZURE=false
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --azure)
      AZURE=true
      shift # past argument
      ;;
    --task)
      TASK="$2"
      shift
      shift
      ;;
    --model)
      API="$2"
      shift
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# logging helper (per-step log files, keep terminal output)
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

# # Set up
if [ "$TASK" = "lite" ]; then
    gdown 'https://drive.google.com/uc?id=1coEVsCZq-Xvj9p2TnhBFoFTsY-UoYGmG' -O ../../spider2-lite/resource/
    rm -rf ../../spider2-lite/resource/databases/spider2-localdb
    mkdir -p ../../spider2-lite/resource/databases/spider2-localdb
    unzip ../../spider2-lite/resource/local_sqlite.zip -d ../../spider2-lite/resource/databases/spider2-localdb
fi

# Init log dir after args known
LOG_DIR="output/${API}-${TASK}-logs-${TIMESTAMP}"
mkdir -p "$LOG_DIR"

run_cmd "$LOG_DIR/01_spider_agent_setup.log" \
  python spider_agent_setup_${TASK}.py --example_folder examples_${TASK}

# Reconstruct data
run_cmd "$LOG_DIR/02_reconstruct_data.log" \
  python reconstruct_data.py \
    --example_folder examples_${TASK} \
    --add_description \
    --add_sample_rows \
    --rm_digits \
    --make_folder \
    --clear_long_eg_des

# echo "Number of prompts.txt files in examples_${TASK} larger than 200KB before reducing: $(find examples_${TASK} -type f -name "prompts.txt" -exec du -b {} + | awk '$1 > 200000' | wc -l)" | tee -a "$LOG_DIR/02_reconstruct_data.log"

# Run Schema linking and voting
run_cmd "$LOG_DIR/03_schema_linking.log" \
  python schema_linking.py \
    --task $TASK \
    --db_path examples_${TASK} \
    --linked_json_pth ../../data/linked_${TASK}_tmp0.json \
    --reduce_col \
    --threshold 100000

# echo "Number of prompts.txt files in examples_${TASK} larger than 200KB before reducing: $(find examples_${TASK} -type f -name "prompts.txt" -exec du -b {} + | awk '$1 > 200000' | wc -l)" | tee -a "$LOG_DIR/03_schema_linking.log"

OUTPUT_PATH="output/${API}-${TASK}-log-${TIMESTAMP}"
# OUTPUT_PATH="output/${API}-${TASK}-log"
NUM_VOTES=8
NUM_WORKERS=4
echo "AZURE mode: $AZURE"
echo "Model: $API"
echo "Task: $TASK"
echo "Output Path: $OUTPUT_PATH"

# Step 1: Self-refinement + Majority Voting
CMD1="python run.py \
    --task $TASK \
    --db_path examples_${TASK} \
    --output_path $OUTPUT_PATH \
    --do_self_refinement \
    --generation_model ${API} \
    --max_iter 5 \
    --temperature 1 \
    --early_stop \
    --do_vote \
    --num_votes $NUM_VOTES \
    --num_workers $NUM_WORKERS"

# Step 2: Self-refinement + Majority Voting + Column Exploration + Rerun
CMD2="python run.py \
    --task $TASK \
    --db_path examples_${TASK} \
    --output_path $OUTPUT_PATH \
    --do_self_refinement \
    --generation_model ${API} \
    --do_column_exploration \
    --column_exploration_model ${API} \
    --max_iter 5 \
    --temperature 1 \
    --early_stop \
    --do_vote \
    --num_votes $NUM_VOTES \
    --num_workers $NUM_WORKERS \
    --rerun \
    --overwrite_unfinished"

if [ "$AZURE" = true ]; then
  CMD1="$CMD1 --azure"
  CMD2="$CMD2 --azure"
fi

run_cmd "$LOG_DIR/04_step1_run.log" bash -lc "$CMD1"
echo "Evaluation for Step 1"
run_cmd "$LOG_DIR/05_step1_eval.log" \
  python eval.py --log_folder $OUTPUT_PATH --task $TASK

run_cmd "$LOG_DIR/06_step2_run.log" bash -lc "$CMD2"
echo "Evaluation for Step 2"
run_cmd "$LOG_DIR/07_step2_eval.log" \
  python eval.py --log_folder $OUTPUT_PATH --task $TASK

# Step 3: Random vote for tie
run_cmd "$LOG_DIR/08_step3_run.log" \
  python run.py \
    --task $TASK \
    --db_path examples_${TASK} \
    --output_path $OUTPUT_PATH \
    --do_vote \
    --random_vote_for_tie \
    --num_votes $NUM_VOTES \
    --num_workers $NUM_WORKERS
echo "Evaluation for Step 3"
run_cmd "$LOG_DIR/09_step3_eval.log" \
  python eval.py --log_folder $OUTPUT_PATH --task $TASK

# Step 4: Random vote final_choose
run_cmd "$LOG_DIR/10_step4_run.log" \
  python run.py \
    --task $TASK \
    --db_path examples_${TASK} \
    --output_path $OUTPUT_PATH \
    --do_vote \
    --random_vote_for_tie \
    --final_choose \
    --num_votes $NUM_VOTES \
    --num_workers $NUM_WORKERS
echo "Evaluation for Step 4"
run_cmd "$LOG_DIR/11_step4_eval.log" \
  python eval.py --log_folder $OUTPUT_PATH --task $TASK

# Final evaluation and get files for submission
run_cmd "$LOG_DIR/12_get_metadata_csv.log" \
  python get_metadata.py --result_path $OUTPUT_PATH --output_path output/${API}-${TASK}-csv-${TIMESTAMP}
run_cmd "$LOG_DIR/13_get_metadata_sql.log" \
  python get_metadata.py --result_path $OUTPUT_PATH --output_path output/${API}-${TASK}-sql-${TIMESTAMP} --file_type sql
pushd ../../spider2-${TASK}/evaluation_suite >/dev/null
run_cmd "$LOG_DIR/14_official_evaluate.log" \
  python evaluate.py --mode exec_result --result_dir ../../methods/ReFoRCE/output/${API}-${TASK}-csv-${TIMESTAMP}
popd >/dev/null