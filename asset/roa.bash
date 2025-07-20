#!/bin/bash

# 输出文件路径
OUT_FILE="/etc/bird/asset/members_perfix.conf"
TMP_FILE="$(mktemp)"
TMP_DIR="$(mktemp -d)"
PROGRESS_FILE="${TMP_DIR}/progress"
LOG_PREFIX="[DEBUG]"
MAX_CONCURRENT=20  # 最大并发数

# 初始化进度文件
echo "0" > "$PROGRESS_FILE"

# DEBUG日志函数
log_debug() {
    echo "$LOG_PREFIX $1"
}

# 显示进度百分比
show_progress() {
    local completed=$1
    local total=$2
    local percent=$((completed * 100 / total))
    log_debug "进度: $completed/$total ($percent%)"
}

# 更新进度计数器
update_progress() {
    local lock_file="${PROGRESS_FILE}.lock"
    
    # 简单的文件锁实现
    while ! mkdir "$lock_file" 2>/dev/null; do
        sleep 0.1
    done
    
    # 读取当前进度，增加1，并写回
    local current=$(cat "$PROGRESS_FILE")
    local new_count=$((current + 1))
    echo "$new_count" > "$PROGRESS_FILE"
    
    # 显示进度
    show_progress "$new_count" "$TOTAL_PREFIXES"
    
    # 释放锁
    rmdir "$lock_file"
}

# 处理单个前缀的函数
process_prefix() {
    local prefix=$1
    local output_file=$2
    local job_id=$3
    
    log_debug "[$job_id] 查询 whois: $prefix"
    whois_out=$(whois "$prefix")
    route6=$(echo "$whois_out" | grep -i '^route6:' | awk '{print $2}' | head -n1)
    origin=$(echo "$whois_out" | grep -i '^origin:' | awk '{print $2}' | head -n1)
    
    if [[ -n "$route6" && -n "$origin" ]]; then
        origin_num=$(echo "$origin" | sed 's/^AS//I')
        log_debug "[$job_id] 获取到 route6: $route6, origin: $origin_num"
        echo "route $route6 max 48 as $origin_num;" >> "$output_file"
    else
        log_debug "[$job_id] 未获取到有效的 route6/origin，跳过。"
    fi
    
    # 更新进度
    update_progress
}

log_debug "开始执行 bgpq4 获取前缀列表..."
bgpq4 -6 -l AS_AKIX_MEMBERS AS210440:AS-AKIX-MEMBER > "$TMP_FILE"
if [ $? -ne 0 ]; then
    log_debug "bgpq4 执行失败，退出。"
    exit 1
fi
log_debug "bgpq4 输出已保存到 $TMP_FILE"

# 解析所有前缀
log_debug "解析所有前缀..."
prefixes=$(grep -E "^ipv6 prefix-list AS_AKIX_MEMBERS permit" "$TMP_FILE" | awk '{print $5}')
if [ -z "$prefixes" ]; then
    log_debug "未解析到任何前缀，退出。"
    exit 2
fi
TOTAL_PREFIXES=$(echo "$prefixes" | wc -l)
log_debug "共解析到 $TOTAL_PREFIXES 个前缀。"

# 清空输出文件
> "$OUT_FILE"
log_debug "已清空输出文件 $OUT_FILE"

# 多线程处理前缀
log_debug "开始多线程处理前缀，最大并发数: $MAX_CONCURRENT"
log_debug "进度: 0/$TOTAL_PREFIXES (0%)"
job_count=0
job_id=0

for prefix in $prefixes; do
    # 为每个作业创建临时输出文件
    job_output="$TMP_DIR/job_${job_id}.txt"
    
    # 启动后台任务处理当前前缀
    process_prefix "$prefix" "$job_output" "$job_id" &
    
    # 增加作业计数和ID
    ((job_count++))
    ((job_id++))
    
    # 如果达到最大并发数，等待一个作业完成
    if [ $job_count -ge $MAX_CONCURRENT ]; then
        wait -n  # 等待任意一个子进程完成
        ((job_count--))
    fi
done

# 等待所有剩余的后台任务完成
log_debug "等待所有任务完成..."
wait

# 显示最终进度
final_count=$(cat "$PROGRESS_FILE")
show_progress "$final_count" "$TOTAL_PREFIXES"

# 合并所有临时输出文件到最终输出文件
log_debug "合并所有任务输出..."
for job_output in "$TMP_DIR"/job_*.txt; do
    if [ -f "$job_output" ]; then
        cat "$job_output" >> "$OUT_FILE"
    fi
done

log_debug "ROA 配置已生成到 $OUT_FILE"

# 删除临时文件
rm -f "$TMP_FILE"
rm -rf "$TMP_DIR"
log_debug "临时文件已删除，脚本结束。"
