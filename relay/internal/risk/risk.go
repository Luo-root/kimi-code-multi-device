// Package risk 是 §10 3.4 的二元风险启发式：内置关键命令清单，命中=红、要确认；其余中性。
// 不维护白名单——维护痛 ＞ 误判痛。与 app 端 isCriticalCommand 保持同一份清单。
package risk

import (
	"regexp"
	"strings"
)

var patterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)rm\s+-rf`),
	regexp.MustCompile(`(?i)sudo\b`),
	regexp.MustCompile(`(?i)git\s+push\s+(-f|--force)`),
	regexp.MustCompile(`(?i)git\s+reset\s+--hard`),
	regexp.MustCompile(`(?i)git\s+clean\s+-fd`),
	regexp.MustCompile(`(?i)curl\s+.*\|\s*(sh|bash)`),
	regexp.MustCompile(`(?i)wget\s+.*\|\s*(sh|bash)`),
	regexp.MustCompile(`(?i)\bdeploy\b`),
	regexp.MustCompile(`(?i)drop\s+(database|table)`),
	regexp.MustCompile(`(?i)truncate\s+table`),
	regexp.MustCompile(`(?i)>\s*~?/?\.ssh`),
	regexp.MustCompile(`(?i)chmod\s+-R`),
	regexp.MustCompile(`(?i)\bmkfs\b`),
	regexp.MustCompile(`(?i)\bdd\s+if=`),
	regexp.MustCompile(`(?i)\btruncate\b`),
}

// IsCritical 命中任一关键模式即判红。
func IsCritical(command string) bool {
	if command == "" {
		return false
	}
	// 多行命令逐行判，命中任一行即红。
	for _, line := range strings.Split(command, "\n") {
		for _, p := range patterns {
			if p.MatchString(line) {
				return true
			}
		}
	}
	return false
}
