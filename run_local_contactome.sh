#!/usr/bin/env bash
# Run Cloudome's complete local contactome pipeline with one command:
#   1. describe the segmentation as cuboid tasks in a temporary file queue;
#   2. drain that queue with the configured number of local workers into
#      contactome.raw.db; and
#   3. sum per-cuboid edges into contactome.db (one row per pre/post pair).
#
# Requirements: bash, uv, and a sibling ./cloudome checkout. Cloudome's locked
# Python environment is installed by uv on the first run. Credentials (for
# example AWS_PROFILE) stay in the process environment and are not copied.
#
# Usage:
#   ./run_local_contactome.sh [CONFIG_PATH]
#
# Example (small public Pinky100 trial):
#   cp config.json.example config.json
#   # Set mip, workers, and enqueue_limit in config.json, then:
#   AWS_PROFILE=bossdb ./run_local_contactome.sh
#
# config.json fields:
#   output_directory  Output directory; default: contactome-output/<graph_id>.
#   graph_id          Run label; default is a UTC timestamp.
#   mip               MIP index or xyz resolution; default: 72,72,84.
#   block_size        Worker cuboid size x,y,z; default: 64,64,32. Each dimension
#                     should be a multiple of the source's chunk size.
#   z_start / z_end   Optional relative Z-voxel bounds; null means full Z extent.
#   enqueue_limit     Optional maximum cuboids; useful for a smoke test.
#   workers           Number of local worker processes; default: 1.
#
# Credentials (for example AWS_PROFILE) remain environment variables and must
# not be written to config.json.
#
# Progress and errors are written to contactome.log in the output directory as
# well as displayed in the terminal.
#
# The output directory and database files must be new. This prevents accidental
# mixing of graphs or partial reruns. Temporary queue and worker databases are
# removed on exit.
set -Eeuo pipefail

usage() { sed -n '2,/^set -Eeuo pipefail/p' "$0" | sed '$d;s/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ ${1:-} != -h && ${1:-} != --help ]] || { usage; exit; }
[[ $# -le 1 ]] || { usage >&2; exit 2; }
command -v uv >/dev/null || die "uv is required (https://docs.astral.sh/uv/)"
command -v python3 >/dev/null || die "python3 is required to read config.json"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cloudome="$root/cloudome"
[[ -f "$cloudome/uv.lock" && -f "$cloudome/local_manage.py" ]] || \
  die "expected the Cloudome checkout at $cloudome"

config_path=${1:-config.json}
[[ -f $config_path ]] || die "configuration file not found: $config_path"
default_graph_id="contactome-$(date -u +%Y%m%dT%H%M%SZ)"
mapfile -t config_values < <(
  python3 "$root/read_contactome_config.py" "$config_path" "$default_graph_id"
)
[[ ${#config_values[@]} -eq 9 ]] || die "could not read configuration from $config_path"
segmentation_channel=${config_values[0]}
graph_id=${config_values[1]}
out_dir=${config_values[2]}
mip=${config_values[3]}
IFS=, read -r block_x block_y block_z <<<"${config_values[4]}"
z_start=${config_values[5]}
z_end=${config_values[6]}
enqueue_limit=${config_values[7]}
worker_count=${config_values[8]}

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd -P)"
raw_db="$out_dir/contactome.raw.db"
final_db="$out_dir/contactome.db"
log_file="$out_dir/contactome.log"
exec > >(tee -a "$log_file") 2>&1
[[ ! -e $raw_db && ! -e $final_db ]] || \
  die "refusing to overwrite existing databases in $out_dir"

printf 'Contactome log: %s\n' "$log_file"

queue_dir="$(mktemp -d "$out_dir/.cloudome-queue.XXXXXX")"
shard_dir="$(mktemp -d "$out_dir/.cloudome-shards.XXXXXX")"
trap 'rm -rf -- "$queue_dir" "$shard_dir"' EXIT
queue_url="fq://$queue_dir"
shard_db="$shard_dir/contactome.raw.db"

generate=(uv run --frozen python local_manage.py
  --sqlite-db-path "$shard_db" --mip "$mip" --queue-url "$queue_url"
  contactome generate --graph-id "$graph_id"
  --segmentation-channel "$segmentation_channel"
  --block-size-x "$block_x" --block-size-y "$block_y" --block-size-z "$block_z")
[[ -z $z_start ]] || generate+=(--z-start "$z_start")
[[ -z $z_end ]] || generate+=(--z-end "$z_end")
[[ -z $enqueue_limit ]] || generate+=(--enqueue-limit "$enqueue_limit")

cd "$cloudome"
printf 'Enqueueing graph %s...\n' "$graph_id"
"${generate[@]}"
task_count="$(uv run --frozen python - "$queue_url" <<'PY'
import sys
from taskqueue import TaskQueue
q = TaskQueue(sys.argv[1])
print(q.inserted - q.completed)
PY
)"
[[ $task_count =~ ^[0-9]+$ ]] || die "could not determine the queued task count"
if (( task_count > 0 )); then
  (( worker_count > task_count )) && worker_count=$task_count
  printf 'Processing %s queued cuboid(s) with %s worker(s)...\n' \
    "$task_count" "$worker_count"

  # Give workers dequeue limits that sum to the queue depth.  This lets all
  # workers exit once the queue is drained instead of polling an empty queue.
  remaining_tasks=$task_count
  worker_pids=()
  for (( worker_index = 1; worker_index <= worker_count; worker_index++ )); do
    worker_tasks=$(( remaining_tasks / (worker_count - worker_index + 1) ))
    remaining_tasks=$(( remaining_tasks - worker_tasks ))
    uv run --frozen python local_manage.py \
      --queue-url "$queue_url" --shard-sqlite \
      worker --tally --dequeue-limit "$worker_tasks" &
    worker_pids+=("$!")
  done

  worker_failed=0
  for worker_pid in "${worker_pids[@]}"; do
    wait "$worker_pid" || worker_failed=1
  done
  (( worker_failed == 0 )) || die "one or more local workers failed"
  printf 'Merging worker databases...\n'
  uv run --frozen python scripts/merge_sqlite_dbs.py \
    --out "$raw_db" --dir "$shard_dir"
else
  printf 'Processing 0 queued cuboid(s)...\n'
  # Generation provisioned the base worker database; use it as the raw output
  # when there were no cuboids to process.
  mv "$shard_db" "$raw_db"
fi
printf 'Aggregating edges...\n'
uv run --frozen python scripts/simplify_contactome_sqlite_db.py \
  "$raw_db" --output-db "$final_db"
printf 'Done: %s\nRaw per-cuboid data: %s\nLog: %s\n' \
  "$final_db" "$raw_db" "$log_file"
