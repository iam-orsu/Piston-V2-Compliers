#!/usr/bin/env bash
# Test all languages across all three Piston servers and compare results.

SERVERS=(
    "178.162.205.144  (old/reference)"
    "78.159.100.10    (new server 1)"
    "46.165.225.12    (new server 2)"
)
URLS=(
    "http://178.162.205.144"
    "http://78.159.100.10"
    "http://46.165.225.12"
)

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

run_test() {
    local url="$1"
    local body="$2"
    curl -s --max-time 30 -X POST "${url}/api/v2/execute" \
        -H 'Content-Type: application/json' \
        -d "$body"
}

check_result() {
    local raw="$1"
    local expected="$2"
    local stdout code signal msg

    stdout=$(echo "$raw" | jq -r '(.run // .compile).stdout // ""' 2>/dev/null | tr -d '\n')
    code=$(echo "$raw"   | jq -r '(.run // .compile).code    // "?"' 2>/dev/null)
    signal=$(echo "$raw" | jq -r '(.run // .compile).signal  // "null"' 2>/dev/null)
    msg=$(echo "$raw"    | jq -r '.message // ""' 2>/dev/null)

    if [[ -n "$msg" ]]; then
        echo -e "  ${RED}✗  ERROR: $msg${NC}"
    elif [[ "$code" == "0" && "$stdout" == "$expected" ]]; then
        echo -e "  ${GREEN}✓  stdout=\"$stdout\"  code=0${NC}"
    elif [[ "$code" == "0" ]]; then
        echo -e "  ${YELLOW}?  stdout=\"$stdout\" (expected \"$expected\")  code=0${NC}"
    else
        echo -e "  ${RED}✗  stdout=\"$stdout\"  code=$code  signal=$signal${NC}"
    fi
}

# ── Test definitions ──────────────────────────────────────────────────────────
# Format: "label|expected_stdout|json_body"
TESTS=(
"Python 3.12|1|{\"language\":\"python\",\"version\":\"3.12.0\",\"files\":[{\"name\":\"main.py\",\"content\":\"print(int(input()))\"}],\"stdin\":\"1\",\"args\":[\"1\",\"2\",\"3\"],\"compile_timeout\":10000,\"run_timeout\":3000,\"compile_cpu_time\":10000,\"run_cpu_time\":3000,\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"Python 3.10|1|{\"language\":\"python\",\"version\":\"3.10.0\",\"files\":[{\"name\":\"main.py\",\"content\":\"print(int(input()))\"}],\"stdin\":\"1\",\"args\":[\"1\",\"2\",\"3\"],\"compile_timeout\":10000,\"run_timeout\":3000,\"compile_cpu_time\":10000,\"run_cpu_time\":3000,\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"Node.js 20|14|{\"language\":\"javascript\",\"version\":\"20.11.1\",\"files\":[{\"name\":\"main.js\",\"content\":\"let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>console.log(parseInt(d.trim())*2));\"}],\"stdin\":\"7\",\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"TypeScript 5|14|{\"language\":\"typescript\",\"version\":\"5.0.3\",\"files\":[{\"name\":\"main.ts\",\"content\":\"const x: number = 7;\\nconsole.log(x * 2);\"}],\"stdin\":\"\",\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"Java 15|14|{\"language\":\"java\",\"version\":\"15.0.2\",\"files\":[{\"name\":\"Main.java\",\"content\":\"import java.util.Scanner;\npublic class Main{\npublic static void main(String[] a){\nScanner s=new Scanner(System.in);\nSystem.out.println(s.nextInt()*2);}}\"}],\"stdin\":\"7\",\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"C (gcc 10)|14|{\"language\":\"c\",\"version\":\"10.2.0\",\"files\":[{\"name\":\"main.c\",\"content\":\"#include<stdio.h>\nint main(){int x;scanf(\\\"%d\\\",&x);printf(\\\"%d\\\\n\\\",x*2);}\"}],\"stdin\":\"7\",\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"Go 1.16|14|{\"language\":\"go\",\"version\":\"1.16.2\",\"files\":[{\"name\":\"main.go\",\"content\":\"package main\nimport(\\\"fmt\\\")\nfunc main(){var x int;fmt.Scan(&x);fmt.Println(x*2)}\"}],\"stdin\":\"7\",\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"Rust 1.68|14|{\"language\":\"rust\",\"version\":\"1.68.2\",\"files\":[{\"name\":\"main.rs\",\"content\":\"use std::io::{self,BufRead};\nfn main(){let s=io::stdin();let l=s.lock().lines().next().unwrap().unwrap();let x:i32=l.trim().parse().unwrap();println!(\\\"{}\\\",x*2);}\"}],\"stdin\":\"7\",\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"Bash 5.2|14|{\"language\":\"bash\",\"version\":\"5.2.0\",\"files\":[{\"name\":\"main.sh\",\"content\":\"read x; echo \$((x*2))\"}],\"stdin\":\"7\",\"compile_memory_limit\":-1,\"run_memory_limit\":-1}"

"SQLite3 3.36|42|{\"language\":\"sqlite3\",\"version\":\"3.36.0\",\"files\":[{\"name\":\"db.sql\",\"content\":\"CREATE TABLE t(x INT);\nINSERT INTO t VALUES(42);\nSELECT x FROM t;\"}],\"stdin\":\"\"}"

"Python DS (NumPy)|3.0|{\"language\":\"python-datascience\",\"version\":\"3.12.7\",\"files\":[{\"name\":\"main.py\",\"content\":\"import numpy as np\narr=np.array([1,2,3,4,5])\nprint(arr.mean())\"}],\"stdin\":\"\",\"run_memory_limit\":-1}"
)

# ── Run ───────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           PISTON — MULTI-SERVER LANGUAGE TEST               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

for test_entry in "${TESTS[@]}"; do
    label="${test_entry%%|*}"
    rest="${test_entry#*|}"
    expected="${rest%%|*}"
    body="${rest#*|}"

    echo -e "${BOLD}── $label ──────────────────────────────────────────${NC}"

    for i in 0 1 2; do
        url="${URLS[$i]}"
        server="${SERVERS[$i]}"
        raw=$(run_test "$url" "$body")
        printf "  %-35s" "$server"
        check_result "$raw" "$expected"
    done
    echo ""
done

echo -e "${GREEN}${BOLD}Done.${NC}"
