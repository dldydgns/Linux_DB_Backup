# [Linux Server] MySQL Dump & Scheduled Backup

> Ubuntu 환경에서 **mysqldump + cron + tar**로 DB를 주기적으로 백업하고, 디렉토리 구조/권한/옵션/오류 대응까지 정리한 자동화 구성을 구축했습니다.

### 주요 특징

- **3분마다** `company` DB 자동 백업 (덤프 + tar 보관)

- MySQL 8 권한 이슈(Process) 없이 동작하도록 `--no-tablespaces` 등 **안전 옵션 적용**

- 백업 파일명에 **날짜·시간(분까지)** 반영, 보관 경로 일원화

- 인증정보는 `~/.my.cnf`로 **보안 분리**, 스크립트는 **읽기 전용 권한**

---

## 팀원 소개

| 팀원                                      | 프로필                                                                              | 회고                                                                                                                                                      |
| --------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [임유진](https://github.com/imewuzin)      | <img width="120px" src="https://avatars.githubusercontent.com/u/156065214?v=4"/> | `mysqldump` 권한 문제와 cron 실행 이슈를 직접 해결하면서 단순 스크립트 작성 이상의 경험을 쌓았습니다. <br>이를 통해 DB 보안과 자동화 관리가 운영 안정성에 얼마나 중요한지 체감했습니다. 앞으로는 더 확장 가능한 데이터 운영 방안을 고민하고자 합니다. |
| [이용훈](https://github.com/dldydgns)      | <img width="120px" src="https://avatars.githubusercontent.com/u/56614731?v=4"/>  | DB 계정 생성, 권한 부여, 그리고 mysqldump 실행 과정에서의 오류를 직접 트러블슈팅하며 MySQL 보안과 운영 경험을 쌓았습니다. <br>향후에는 안정적인 데이터 백업 정책 수립과 로그 관리까지 신경쓰고자 합니다.                           |
| [홍윤기](https://github.com/yunkihong-dev) | <img width="120px" src="https://avatars.githubusercontent.com/u/81303136?v=4"/>  | MySQL 8의 권한 정책과 `mysqldump` 옵션 조합을 이해하고, cron 주기 설정과 보관 정책을 체계화했습니다. <br>실무에 가까운 문제 해결 과정을 통해 운영 자동화 감각을 키웠습니다.                                         |

---

## 시스템 구성

**OS:** Ubuntu 24.04 (VirtualBox VM)

| 구성 요소         | 역할                                |
| ------------- | --------------------------------- |
| **MySQL 8**   | `company` DB (테이블: `dept`, `emp`) |
| **mysqldump** | 논리 백업 생성                          |
| **cron**      | 3분마다 자동 실행                        |
| **tar**       | 덤프 파일 압축 보관                       |
| **~/.my.cnf** | DB 인증정보 분리(보안)                    |

**작업 디렉토리:** `~/03.sh/03-1.mysql_dump_pjt`

---

## 설치 및 준비

### ① MySQL 설치 & 기본 보안 설정

```bash
sudo apt update
sudo apt install -y mysql-server
sudo systemctl enable --now mysql
sudo mysql_secure_installation   # (선택) root 보안
```

### ② DB/계정/샘플 데이터

```sql
-- root로 접속: sudo mysql
CREATE DATABASE IF NOT EXISTS company
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS 'ubuntu'@'localhost' IDENTIFIED BY 'ubuntu';
GRANT ALL PRIVILEGES ON company.* TO 'ubuntu'@'localhost';
FLUSH PRIVILEGES;

USE company;

CREATE TABLE IF NOT EXISTS dept (
  deptno INT PRIMARY KEY,
  dname  VARCHAR(50),
  loc    VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS emp (
  empno   INT PRIMARY KEY,
  ename   VARCHAR(50),
  job     VARCHAR(50),
  mgr     INT NULL,
  hiredate DATE,
  sal     DECIMAL(10,2),
  comm    DECIMAL(10,2) NULL,
  deptno  INT,
  CONSTRAINT fk_emp_dept FOREIGN KEY (deptno) REFERENCES dept(deptno)
);

INSERT INTO dept (deptno, dname, loc) VALUES
  (10, 'ACCOUNTING', 'NEW YORK'),
  (20, 'RESEARCH',   'DALLAS'),
  (30, 'SALES',      'CHICAGO')
ON DUPLICATE KEY UPDATE dname=VALUES(dname), loc=VALUES(loc);

INSERT INTO emp (empno, ename, job, mgr, hiredate, sal, comm, deptno) VALUES
  (7369, 'SMITH', 'CLERK',   7902, '1980-12-17',  800,  NULL, 20),
  (7499, 'ALLEN', 'SALESMAN',7698, '1981-02-20', 1600,  300,  30),
  (7521, 'WARD',  'SALESMAN',7698, '1981-02-22', 1250,  500,  30),
  (7566, 'JONES', 'MANAGER', 7839, '1981-04-02', 2975,  NULL, 20)
ON DUPLICATE KEY UPDATE
  ename=VALUES(ename), job=VALUES(job), mgr=VALUES(mgr),
  hiredate=VALUES(hiredate), sal=VALUES(sal),
  comm=VALUES(comm), deptno=VALUES(deptno);
```

### ③ 인증 정보(보안) — `~/.my.cnf`

```ini
# /home/ubuntu/.my.cnf
[client]
user=ubuntu
password=ubuntu
```

```bash
chmod 600 ~/.my.cnf
```

---

## 백업 스크립트

**경로:** `~/03.sh/03-1.mysql_dump_pjt/backup_company.sh`

```bash
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
```

```bash
chmod 750 ~/03.sh/03-1.mysql_dump_pjt/backup_company.sh
```

---

## 스케줄링(cron)

**주기:** 3분마다 실행

```bash
crontab -e
```

아래 줄 추가:

```
*/3 * * * * /home/ubuntu/03.sh/03-1.mysql_dump_pjt/backup_company.sh
```

> **참고**: cron은 제한된 PATH로 실행됩니다. **절대경로**를 쓰고, `~` 대신 `/home/ubuntu`를 명시하세요.

---

## 결과

- 예시 백업 파일:
  
  ```
  ~/03.sh/03-1.mysql_dump_pjt/backups/company_20250908-1536.tar.gz
  ```

- 로그:
  
  ```
  ~/03.sh/03-1.mysql_dump_pjt/logs/backup.log
  [2025-09-08 15:36:03] backup OK -> /home/ubuntu/03.sh/03-1.mysql_dump_pjt/backups/company_20250908-1536.tar.gz
  ```

- tar 확인(압축 해제 없이 목록만):
  
  ```bash
  tar -tzf ~/03.sh/03-1.mysql_dump_pjt/backups/company_20250908-1536.tar.gz | head
  ```

---

## 트러블슈팅

### 1) `Access denied; PROCESS privilege` 에러

- **원인:** MySQL 8에서 `mysqldump`가 tablespaces 메타데이터를 덤프하려다 `PROCESS` 권한 부족

- **해결:** 스크립트에 `--no-tablespaces` 추가  
  (대안: 관리자가 `GRANT PROCESS ON *.*` 부여하되 보안상 비추천)

- **예방:** MySQL 8 환경 백업 스크립트에는 **항상** `--no-tablespaces` 고려

### 2) cron에서 실행 안 됨

- **원인:** PATH/권한/절대경로 문제

- **점검:** `chmod +x backup_company.sh`, 절대경로 사용, `mail`/`/var/log/syslog`에서 CRON 로그 확인
  
  ```bash
  grep CRON /var/log/syslog | tail
  ```

### 3) 인증 오류

- **원인:** `~/.my.cnf` 권한/소유자 문제 또는 루트로 실행

- **조치:** `chmod 600 ~/.my.cnf`, 루트가 아니라 **ubuntu** 사용자로 실행하거나 루트의 `/root/.my.cnf`도 별도 구성

### 4) 보관 용량 증가

- **대응:** 스크립트 말미의 `find ... -mtime +7 -delete`로 보관주기 관리(원하는 기간으로 조정)

---

## 한 줄 요약

**3분마다 안전하게 동작하는 MySQL 자동 백업**을 구현했습니다.  
MySQL 8 권한 이슈를 우회하는 옵션 세트를 적용하고, 보관·로그·보안까지 운영 관점에서 정리했습니다.
