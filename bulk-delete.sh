#!/bin/bash
# =========================================================
#  CPANEL BULK DELETE DOMAINS (v11.0 — GitHub CSV + Dry-run)
#  ดึงรายชื่อโดเมนจาก CSV บน GitHub + ยืนยันก่อนลบ
#
#  รูปแบบ CSV (คอลัมน์: domain,parent):
#     domain,parent
#     bbb.com,gonext02.com
#     amba98.net,gonext02.com
#  (parent = โดเมนหลักของบัญชี cPanel ใช้ตามลบ subdomain artifact ที่ค้าง)
#
#  วิธีใช้:
#     LIST='https://raw.githubusercontent.com/ufavisionseoteam19/bulk-delete-domains/main/delete-list.csv'
#     bash <(curl -s "https://raw.githubusercontent.com/ufavisionseoteam19/bulk-delete-domains/main/bulk-delete.sh") --list="$LIST?v=$(date +%s)"
#
#  Flags:
#     --list=URL    ดึง CSV จาก URL (บังคับ ถ้าไม่ใช้ --file)
#     --file=PATH   อ่าน CSV จากไฟล์ในเครื่องแทน
#     --yes         ข้ามการถาม YES (ใช้เมื่อมั่นใจ/รันใน automation — ระวัง!)
#     --max-load=N  ปรับ CPU load limit (ค่าเริ่มต้น = 10)
# =========================================================

# --- CONFIG ---
WORK_DIR="/usr/local/scripts/bulk_delete"
LOG_DIR="$WORK_DIR/log"
LOG_FILE="$LOG_DIR/delete_log_$(date +%Y-%m-%d_%H%M).txt"
MAX_LOAD=10.0
MIN_SLEEP=3
COOL_TIMEOUT=300   # รอ cooling down สูงสุด 5 นาที แล้วไปต่อ (กันค้าง)

# --- COLORS ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- ARGS ---
LIST_URL=""; LIST_FILE=""; ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --list=*)     LIST_URL="${a#--list=}" ;;
        --file=*)     LIST_FILE="${a#--file=}" ;;
        --yes)        ASSUME_YES=1 ;;
        --max-load=*) MAX_LOAD="${a#--max-load=}" ;;
    esac
done

mkdir -p "$WORK_DIR" "$LOG_DIR"

if ! command -v bc &>/dev/null; then
    echo -e "${RED}Error: ไม่พบ 'bc' ติดตั้ง: yum install bc -y${NC}"; exit 1
fi

log_only() { echo "[$1] $2" >> "$LOG_FILE"; }

check_load() {
    local load waited=0
    load=$(awk '{print $1}' /proc/loadavg)
    if [ "$(echo "$load > $MAX_LOAD" | bc)" -eq 1 ]; then
        while [ "$(echo "$load > $MAX_LOAD" | bc)" -eq 1 ]; do
            echo -ne "${YELLOW}   ⚠️  High Load ($load > $MAX_LOAD). Cooling... ${waited}s${NC}\r"
            sleep 5; waited=$((waited+5))
            if [ "$waited" -ge "$COOL_TIMEOUT" ]; then
                echo -e "\n${YELLOW}   ⏱️  รอเกิน ${COOL_TIMEOUT}s — ไปต่อ${NC}"; break
            fi
            load=$(awk '{print $1}' /proc/loadavg)
        done
        echo -ne "                                                            \r"
    fi
}

# --- LOAD CSV ---
RAW=""
if [ -n "$LIST_URL" ]; then
    echo -e "${CYAN}กำลังดึงรายชื่อจาก: $LIST_URL${NC}"
    RAW=$(curl -s --fail "$LIST_URL")
    if [ $? -ne 0 ] || [ -z "$RAW" ]; then
        echo -e "${RED}Error: ดึง CSV ไม่สำเร็จ — ตรวจ URL/เน็ต${NC}"; exit 1
    fi
elif [ -n "$LIST_FILE" ]; then
    [ ! -f "$LIST_FILE" ] && { echo -e "${RED}Error: ไม่พบไฟล์ $LIST_FILE${NC}"; exit 1; }
    RAW=$(cat "$LIST_FILE")
else
    echo -e "${RED}Error: ต้องระบุ --list=URL หรือ --file=PATH${NC}"; exit 1
fi

# --- PARSE CSV (domain,parent) ---
declare -a DOMAINS PARENTS
first=1
while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | tr -d '\r')
    [ -z "$(echo "$line" | xargs)" ] && continue
    dom=$(echo "$line" | cut -d',' -f1 | tr '[:upper:]' '[:lower:]' | xargs)
    par=$(echo "$line" | cut -d',' -f2 | tr '[:upper:]' '[:lower:]' | xargs)
    # ข้าม header
    if [ "$first" -eq 1 ]; then
        first=0
        if [ "$dom" = "domain" ]; then continue; fi
    fi
    [ -z "$dom" ] && continue
    DOMAINS+=("$dom"); PARENTS+=("$par")
done <<< "$RAW"

TOTAL=${#DOMAINS[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo -e "${RED}Error: ไม่พบโดเมนใน CSV${NC}"; exit 1
fi

# --- DRY-RUN: แสดงรายชื่อ + เช็คว่ามีจริงไหม ---
clear
echo "========================================================"
echo -e "   ${CYAN}🔍 DRY-RUN — ตรวจรายชื่อก่อนลบ (ยังไม่ลบ)${NC}"
echo "========================================================"
echo -e "   จำนวนโดเมนใน CSV : $TOTAL"
echo -e "   Load Limit       : $MAX_LOAD"
echo "--------------------------------------------------------"
printf "   %-4s %-28s %-12s %s\n" "#" "โดเมน" "สถานะ" "บัญชี(parent)"
exist_count=0; notfound_count=0
for i in "${!DOMAINS[@]}"; do
    d="${DOMAINS[$i]}"; p="${PARENTS[$i]}"
    if grep -qP "^$d: " /etc/userdomains 2>/dev/null; then
        printf "   %-4s %-28s ${GREEN}%-12s${NC} %s\n" "$((i+1))" "$d" "มีอยู่" "$p"
        ((exist_count++))
    else
        printf "   %-4s %-28s ${YELLOW}%-12s${NC} %s\n" "$((i+1))" "$d" "ไม่พบ" "$p"
        ((notfound_count++))
    fi
done
echo "--------------------------------------------------------"
echo -e "   ${GREEN}มีอยู่จริง (จะถูกลบ): $exist_count${NC}"
echo -e "   ${YELLOW}ไม่พบ (จะข้าม)     : $notfound_count${NC}"
echo "========================================================"

if [ "$exist_count" -eq 0 ]; then
    echo -e "${YELLOW}ไม่มีโดเมนให้ลบ — จบการทำงาน${NC}"; exit 0
fi

# --- CONFIRM ---
if [ "$ASSUME_YES" -ne 1 ]; then
    echo -e "${RED}⚠️  การลบเป็นการถาวร กู้คืนไม่ได้!${NC}"
    echo -ne "${RED}พิมพ์ ${NC}${CYAN}YES${NC}${RED} (ตัวใหญ่) เพื่อยืนยันลบ $exist_count โดเมน: ${NC}"
    read -r ans
    if [ "$ans" != "YES" ]; then
        echo -e "${YELLOW}ยกเลิก — ไม่มีการลบใด ๆ${NC}"; exit 0
    fi
fi

# --- EXECUTE ---
echo "" ; echo "========================================================"
echo -e "   🚀 เริ่มลบ — Log: $LOG_FILE"
echo "========================================================"
C_OK=0; C_SKIP=0; C_FAIL=0; CUR=0
for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"; PARENT="${PARENTS[$i]}"
    ((CUR++)); TIME=$(date '+%H:%M:%S')
    check_load

    if grep -qP "^$domain: " /etc/userdomains 2>/dev/null; then
        echo -ne "[$CUR/$TOTAL] Deleting: $domain ... "
        out=$(whmapi1 delete_domain domain="$domain" 2>&1)
        if echo "$out" | grep -q "result: 1"; then
            echo -e "${GREEN}✅ Success${NC}"
            log_only "$TIME" "SUCCESS: $domain"; ((C_OK++)); sleep $MIN_SLEEP
        else
            reason=$(echo "$out" | grep "reason:" | sed 's/reason: //g' | xargs)
            echo -e "${RED}❌ Failed (${reason})${NC}"
            log_only "$TIME" "FAILED: $domain | $reason"; ((C_FAIL++))
        fi
    else
        echo -e "[$CUR/$TOTAL] ${YELLOW}⏭️  Skipped (ไม่พบ): $domain${NC}"
        log_only "$TIME" "SKIPPED: $domain"; ((C_SKIP++))
    fi

    # ลบ subdomain artifact (domain.parent) ที่ค้าง
    if [ -n "$PARENT" ] && [[ "$domain" != *"$PARENT"* ]]; then
        sub="$domain.$PARENT"
        if grep -qP "^$sub: " /etc/userdomains 2>/dev/null; then
            whmapi1 delete_domain domain="$sub" >/dev/null 2>&1
            log_only "$TIME" "CLEANUP artifact: $sub"
            echo -e "        ${CYAN}↳ ลบ artifact: $sub${NC}"
        fi
    fi
done

# --- SUMMARY ---
echo "" ; echo "========================================================"
echo -e "   🏁 เสร็จสิ้น  ($(date '+%H:%M:%S'))"
echo -e "   ✅ ลบสำเร็จ : ${GREEN}$C_OK${NC}"
echo -e "   ⏭️  ข้าม     : ${YELLOW}$C_SKIP${NC}"
echo -e "   ❌ ล้มเหลว  : ${RED}$C_FAIL${NC}"
echo -e "   📄 Log: $LOG_FILE"
echo "========================================================"
