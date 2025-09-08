#!/usr/bin/env bash
set -euo pipefail

# === 설정 ===
DB_NAME="company"
BASE_DIR="$HOME/03.sh/03-1.mysql_dump_pjt"
BACKUP_DIR="$BASE_DIR/backups"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# 파일명: 날짜-시간(분까지)
TS="$(date +%Y%m%d-%H%M)"
SQL_FILE="${BACKUP_DIR}/company_${TS}.sql"
TAR_FILE="${BACKUP_DIR}/company_${TS}.tar.gz"
LOG_FILE="${LOG_DIR}/backup.log"

# === 덤프 ===
# MySQL 8 권한 에러 회피 + 일관성 보장 + 전체 객체 포함 + 복제 설정 배제
mysqldump \
  --no-tablespaces \
  --single-transaction \
  --quick \
  --routines \
  --events \
  --triggers \
  --set-gtid-purged=OFF \
  "${DB_NAME}" > "${SQL_FILE}"

# === 압축 ===
tar -czf "${TAR_FILE}" -C "${BACKUP_DIR}" "$(basename "${SQL_FILE}")"

# 원본 SQL은 보관 정책에 따라 삭제(선택)
rm -f "${SQL_FILE}"

# === 로그 ===
echo "[$(date '+%F %T')] backup OK -> ${TAR_FILE}" >> "${LOG_FILE}"

# (선택) 7일 이상 파일 삭제
find "${BACKUP_DIR}" -type f -name 'company_*.tar.gz' -mtime +7 -delete
