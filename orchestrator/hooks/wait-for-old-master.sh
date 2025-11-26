#!/usr/bin/env bash
set -u

FAILURE_TYPE="$1"          # DeadMaster
CLUSTER_ALIAS="$2"         # channel_cluster, core_cluster 등
FAILED_HOST="$3"           # mysql1
FAILED_PORT="$4"           # 3306
SUCCESSOR_HOST="$5"        # mysql2
SUCCESSOR_PORT="$6"        # 3306
IS_SUCCESSFUL="$7"         # true / false

LOG_FILE="/var/lib/orchestrator/rejoin-watcher.log"
LOCK_FILE="/var/lib/orchestrator/rejoin-${CLUSTER_ALIAS}-${FAILED_HOST}-${FAILED_PORT}.lock"

# === 환경 설정 (네 환경에 맞게 수정) ===

# 관리용 계정 (root 대신 orc_topology_user 사용)
ADMIN_USER="${ADMIN_USER:-orc_topology_user}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-orc1234!}"

# 복제용 계정 (02-replica-*.sql과 맞춰서)
REPL_USER="${REPL_USER:-repl_user}"
REPL_PASSWORD="${REPL_PASSWORD:-repl1234!}"

# 클러스터 별 애플리케이션 DB 이름
APP_DB=""
case "$CLUSTER_ALIAS" in
  channel_cluster)
    APP_DB="teeny_channel"
    ;;
  core_cluster)
    APP_DB="teeny_core"
    ;;
  *)
    # 혹시 모르는 디폴트
    APP_DB="teeny_channel"
    ;;
esac

log() {
  local msg="$1"
  # 시간 + 공통 prefix
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [wait-for-old-master] $msg"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [wait-for-old-master] $msg" >> "$LOG_FILE"
}

log "========== rejoin-watcher invoked =========="
log "args: FAILURE_TYPE=$FAILURE_TYPE CLUSTER_ALIAS=$CLUSTER_ALIAS FAILED=${FAILED_HOST}:${FAILED_PORT} SUCCESSOR=${SUCCESSOR_HOST}:${SUCCESSOR_PORT} IS_SUCCESSFUL=$IS_SUCCESSFUL"
log "env: ADMIN_USER=${ADMIN_USER} ADMIN_PASSWORD=**** REPL_USER=${REPL_USER} REPL_PASSWORD=**** APP_DB=${APP_DB}"
log "log file: $LOG_FILE"
log "lock file: $LOCK_FILE"

# 실패한 failover면 감시할 필요 없음
if [ "$IS_SUCCESSFUL" != "true" ]; then
  log "skip watcher: failover not successful (isSuccessful=$IS_SUCCESSFUL, failureType=$FAILURE_TYPE, cluster=$CLUSTER_ALIAS)"
  exit 0
fi

# 같은 old master에 대한 watcher 중복 실행 방지
if [ -f "$LOCK_FILE" ]; then
  log "watcher already running for ${FAILED_HOST}:${FAILED_PORT} (cluster=${CLUSTER_ALIAS}), exit"
  exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "start watcher: failureType=$FAILURE_TYPE cluster=$CLUSTER_ALIAS oldMaster=${FAILED_HOST}:${FAILED_PORT} newMaster=${SUCCESSOR_HOST}:${SUCCESSOR_PORT}"

# -------------------------
# 1. 옛 마스터가 다시 떠올 때까지 감시
# -------------------------
COUNTER=0
INTERVAL=5          # 헬스체크 간격(초)
MAX_SECONDS=120     # 2분
MAX_ATTEMPTS=$((MAX_SECONDS / INTERVAL))

while true; do
  COUNTER=$((COUNTER + 1))

  log "healthcheck #${COUNTER}: try connect ${FAILED_HOST}:${FAILED_PORT} as ${ADMIN_USER}"

  # mysql 클라이언트로 실제 접속 시도
  if OUTPUT=$(mysql \
      -h "$FAILED_HOST" -P "$FAILED_PORT" \
      -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" \
      -e "SELECT 1;" 2>&1); then
    log "healthcheck #${COUNTER}: SUCCESS (${FAILED_HOST}:${FAILED_PORT} reachable). mysql output: ${OUTPUT}"
    log "old master is BACK UP: ${FAILED_HOST}:${FAILED_PORT}, start rejoin flow"
    break
  else
    SANITIZED_OUTPUT=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/  */ /g')
    log "healthcheck #${COUNTER}: FAIL (${FAILED_HOST}:${FAILED_PORT} unreachable). mysql error: ${SANITIZED_OUTPUT}"
  fi

  if [ "$COUNTER" -ge "$MAX_ATTEMPTS" ]; then
    log "healthcheck FAILED: ${FAILED_HOST}:${FAILED_PORT} unreachable for ${MAX_SECONDS}s (>= ${MAX_ATTEMPTS} attempts). stop watcher."
    exit 1
  fi

  sleep "$INTERVAL"
done


# -------------------------
# 2. 새 마스터에서 덤프 떠오기
# -------------------------

TMP_DIR="$(mktemp -d /tmp/rejoin-${CLUSTER_ALIAS}-${FAILED_HOST}-${FAILED_PORT}-XXXXXXXX)" || {
  log "failed to create temp dir (mktemp failed)"
  exit 1
}
DUMP_FILE="${TMP_DIR}/${APP_DB}.sql"
DUMP_ERR="${TMP_DIR}/${APP_DB}.err"

log "tmp dir created: ${TMP_DIR}"
log "dump file path: ${DUMP_FILE}"
log "tmp dir created: ${TMP_DIR}"
log "dump file path: ${DUMP_FILE}"

log "take logical dump from new master ${SUCCESSOR_HOST}:${SUCCESSOR_PORT}, db=${APP_DB} as ${ADMIN_USER}"

# --- mysqldump가 --set-gtid-purged 옵션을 지원하는지 확인 ---
GTID_OPTION="--set-gtid-purged=ON"
if ! mysqldump --help 2>&1 | grep -q "set-gtid-purged"; then
  log "mysqldump in this container does NOT support --set-gtid-purged, dumping WITHOUT GTID metadata"
  GTID_OPTION=""
else
  log "mysqldump supports --set-gtid-purged, using ${GTID_OPTION}"
fi

DUMP_ERR="${TMP_DIR}/${APP_DB}.err"

if ! mysqldump \
  -h "$SUCCESSOR_HOST" -P "$SUCCESSOR_PORT" \
  -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" \
  --single-transaction \
  --routines --events --triggers \
  ${GTID_OPTION} \
  --databases "$APP_DB" > "$DUMP_FILE" 2> "$DUMP_ERR"; then

  if [ -s "$DUMP_ERR" ]; then
    SANITIZED_DUMP_ERR=$(tr '\n' ' ' < "$DUMP_ERR" | sed 's/  */ /g')
    log "mysqldump from new master FAILED. error: ${SANITIZED_DUMP_ERR}"
  else
    log "mysqldump from new master FAILED. (no stderr captured)"
  fi
  exit 1
fi

log "dump completed: $DUMP_FILE (size=$(stat -c%s "$DUMP_FILE" 2>/dev/null || echo unknown) bytes)"


# -------------------------
# 3. 옛 마스터 초기화 (데이터 날리고 GTID 세팅 준비)
# -------------------------

log "prepare old master ${FAILED_HOST}:${FAILED_PORT} as fresh replica target (RESET REPLICA/MASTER + DROP DB ${APP_DB})"

if OUTPUT=$(mysql \
  -h "$FAILED_HOST" -P "$FAILED_PORT" \
  -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" <<SQL 2>&1
SET GLOBAL super_read_only = 0;
SET GLOBAL read_only = 0;

STOP REPLICA FOR CHANNEL '';
RESET REPLICA ALL;

RESET MASTER;

DROP DATABASE IF EXISTS \`${APP_DB}\`;
SQL
); then
  SANITIZED_OUTPUT=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/  */ /g')
  log "prepare old master COMPLETED. mysql output: ${SANITIZED_OUTPUT}"
else
  SANITIZED_OUTPUT=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/  */ /g')
  log "failed to prepare old master (RESET MASTER / DROP DATABASE). mysql error: ${SANITIZED_OUTPUT}"
  exit 1
fi

# -------------------------
# 4. 덤프를 옛 마스터에 적용 (binary log는 끈 세션으로)
# -------------------------

log "restore dump into old master ${FAILED_HOST}:${FAILED_PORT} from ${DUMP_FILE} (with SQL_LOG_BIN=0 session)"

if OUTPUT=$(mysql \
  --init-command="SET SESSION SQL_LOG_BIN=0;" \
  -h "$FAILED_HOST" -P "$FAILED_PORT" \
  -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" < "$DUMP_FILE" 2>&1); then
  SANITIZED_OUTPUT=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/  */ /g')
  log "restore to old master COMPLETED. mysql output: ${SANITIZED_OUTPUT}"
else
  SANITIZED_OUTPUT=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/  */ /g')
  log "restore to old master FAILED. mysql error: ${SANITIZED_OUTPUT}"
  exit 1
fi

log "restore completed on old master"

# -------------------------
# 5. 옛 마스터를 새 마스터의 replica 로 붙이기
# -------------------------

log "configure old master as replica of new master with GTID auto-position"
log "CHANGE REPLICATION SOURCE TO SOURCE_HOST='${SUCCESSOR_HOST}', SOURCE_PORT=${SUCCESSOR_PORT}, SOURCE_USER='${REPL_USER}', SOURCE_AUTO_POSITION=1"

if OUTPUT=$(mysql \
  -h "$FAILED_HOST" -P "$FAILED_PORT" \
  -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" <<SQL 2>&1
STOP REPLICA;

CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${SUCCESSOR_HOST}',
  SOURCE_PORT=${SUCCESSOR_PORT},
  SOURCE_USER='${ADMIN_USER}',
  SOURCE_PASSWORD='${ADMIN_PASSWORD}',
  SOURCE_AUTO_POSITION = 1;

SET GLOBAL read_only = 1;
SET GLOBAL super_read_only = 1;

START REPLICA;
SQL
); then
  SANITIZED_OUTPUT=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/  */ /g')
  log "replication reconfiguration COMPLETED on old master. mysql output: ${SANITIZED_OUTPUT}"
else
  SANITIZED_OUTPUT=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/  */ /g')
  log "failed to configure replication on old master. mysql error: ${SANITIZED_OUTPUT}"
  exit 1
fi

log "old master ${FAILED_HOST}:${FAILED_PORT} is now a GTID replica of ${SUCCESSOR_HOST}:${SUCCESSOR_PORT} (cluster=${CLUSTER_ALIAS})"
log "========== rejoin-watcher finished successfully =========="

exit 0
