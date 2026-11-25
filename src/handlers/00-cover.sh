# shellcheck shell=bash
#
# ── 封面与页脚 ─────────────────────────────────────────────────────────
#
# 这里就是报告最上面和最下面的几行文字，改字符串即可自定义；
# 把某一行的 mr_cover_line / mr_footer_line 注释掉，那一行就不显示。
# 想加一行，照抄一行再改文字即可（可以加任意多行，都会自动居中）。
#
# 三个 *_TITLE / *_SUBTITLE / *_ENVIRONMENT 变量也支持用环境变量覆盖，
# 例如：REPORT_TITLE='我的机器' ./machine_report.sh

# 用 ${VAR-default} 而不是 ${VAR:-default}：显式传空串也能把这一行关掉。
REPORT_TITLE=${REPORT_TITLE-'服务器运行报告'}
REPORT_SUBTITLE=${REPORT_SUBTITLE-'PVE Platform'}
REPORT_ENVIRONMENT=${REPORT_ENVIRONMENT-'PRODUCTION'}

[ -n "${REPORT_TITLE:-}" ] &&
    mr_cover_line "${C_TITLE}${REPORT_TITLE}${C_RESET}"
[ -n "${REPORT_SUBTITLE:-}" ] &&
    mr_cover_line "${C_ACCENT}${REPORT_SUBTITLE}${C_RESET}"

# 页脚：ENVIRONMENT 固定在前，SERVER/CLIENT 由 20-network.sh 追加。
[ -n "${REPORT_ENVIRONMENT:-}" ] &&
    mr_footer_line "${C_ENV}ENVIRONMENT · ${REPORT_ENVIRONMENT}${C_RESET}"
