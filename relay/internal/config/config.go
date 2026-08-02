// Package config 是 SENTINEL 中继的配置文件：TOML 单文件，支持人工编辑与 App 热更新。
//
// 优先级：配置文件 > 环境变量（兼容旧部署）> 默认值。
// 配置文件路径：$RELAY_CONFIG 指定，否则 $KIMI_CODE_HOME/relay.toml，否则 ./relay.toml。
// 首次启动自动生成默认模板；App 设置页保存时写回同一文件。
package config

import (
	"os"
	"path/filepath"
	"strconv"

	"github.com/BurntSushi/toml"
)

// DefaultTimeoutSeconds 许可超时默认阈值（秒）。
const DefaultTimeoutSeconds = 300

// Config 中继运行配置（TOML 序列化）。
type Config struct {
	Bark struct {
		// URL 形如 https://api.day.app/{key}；空 = 禁用门铃。
		URL string `toml:"url"`
	} `toml:"bark"`
	Permission struct {
		// TimeoutSeconds 许可超时阈值（秒），manual 模式到期未决时按策略代答。
		TimeoutSeconds int `toml:"timeout_seconds"`
		// AutoPassNonCritical 非关键命令超时自动放行开关。
		AutoPassNonCritical bool `toml:"auto_pass_non_critical"`
	} `toml:"permission"`
}

// Path 返回配置文件路径：RELAY_CONFIG 优先，否则 KIMI_CODE_HOME/relay.toml，
// 否则 ~/.kimi-code/relay.toml（目录存在时），最终兜底 ./relay.toml。
func Path() string {
	if v := os.Getenv("RELAY_CONFIG"); v != "" {
		return v
	}
	if v := os.Getenv("KIMI_CODE_HOME"); v != "" {
		return filepath.Join(v, "relay.toml")
	}
	if h, err := os.UserHomeDir(); err == nil {
		cand := filepath.Join(h, ".kimi-code", "relay.toml")
		if _, err := os.Stat(filepath.Dir(cand)); err == nil {
			return cand
		}
	}
	return "relay.toml"
}

// Load 读取配置：先填默认值与环境变量（兼容旧部署），再被文件中的显式字段覆盖。
// 文件不存在不算错误（返回默认配置，由调用方决定是否生成模板）。
func Load(path string) (*Config, error) {
	c := &Config{}

	// 环境变量回退（字段级：文件里没写的字段才用 env）。
	c.Bark.URL = os.Getenv("BARK_URL")
	if v := os.Getenv("PERM_TIMEOUT_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			c.Permission.TimeoutSeconds = n
		}
	}
	c.Permission.AutoPassNonCritical = os.Getenv("PERM_AUTO_PASS_NONCRITICAL") == "1"

	// 默认值
	if c.Permission.TimeoutSeconds <= 0 {
		c.Permission.TimeoutSeconds = DefaultTimeoutSeconds
	}

	// 文件覆盖：显式按 key 是否出现合并（md.IsDefined 对嵌套 key 不可靠，手动匹配 Keys）。
	// 文件里没写的字段不覆盖 env/默认；文件不存在则直接返回。
	tmp := &Config{}
	md, err := toml.DecodeFile(path, tmp)
	if err != nil {
		if os.IsNotExist(err) {
			return c, nil
		}
		return c, err
	}
	if hasTOMLKey(md, "bark", "url") {
		c.Bark.URL = tmp.Bark.URL
	}
	if hasTOMLKey(md, "permission", "timeout_seconds") && tmp.Permission.TimeoutSeconds > 0 {
		c.Permission.TimeoutSeconds = tmp.Permission.TimeoutSeconds
	}
	if hasTOMLKey(md, "permission", "auto_pass_non_critical") {
		c.Permission.AutoPassNonCritical = tmp.Permission.AutoPassNonCritical
	}
	return c, nil
}

// hasTOMLKey 判断 TOML 元数据里是否存在给定层级路径的 key。
func hasTOMLKey(md toml.MetaData, path ...string) bool {
	for _, k := range md.Keys() {
		if len(k) != len(path) {
			continue
		}
		match := true
		for i := range k {
			if k[i] != path[i] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

// Save 把当前生效配置写回文件（自动创建父目录）。
func Save(path string, c *Config) error {
	if dir := filepath.Dir(path); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	b, err := toml.Marshal(c)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}
