package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDefaults(t *testing.T) {
	t.Setenv("BARK_URL", "")
	t.Setenv("PERM_TIMEOUT_SECONDS", "")
	t.Setenv("PERM_AUTO_PASS_NONCRITICAL", "")
	path := filepath.Join(t.TempDir(), "nonexistent.toml")

	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Bark.URL != "" {
		t.Errorf("默认 Bark.URL = %q，期望空", c.Bark.URL)
	}
	if c.Permission.TimeoutSeconds != DefaultTimeoutSeconds {
		t.Errorf("默认 TimeoutSeconds = %d，期望 %d", c.Permission.TimeoutSeconds, DefaultTimeoutSeconds)
	}
	if c.Permission.AutoPassNonCritical {
		t.Errorf("默认 AutoPassNonCritical = true，期望 false")
	}
}

func TestLoadEnvFallback(t *testing.T) {
	t.Setenv("BARK_URL", "https://api.day.app/envkey")
	t.Setenv("PERM_TIMEOUT_SECONDS", "42")
	t.Setenv("PERM_AUTO_PASS_NONCRITICAL", "1")
	path := filepath.Join(t.TempDir(), "nonexistent.toml")

	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Bark.URL != "https://api.day.app/envkey" {
		t.Errorf("env 未回退 Bark.URL = %q", c.Bark.URL)
	}
	if c.Permission.TimeoutSeconds != 42 {
		t.Errorf("env 未回退 TimeoutSeconds = %d", c.Permission.TimeoutSeconds)
	}
	if !c.Permission.AutoPassNonCritical {
		t.Errorf("env 未回退 AutoPassNonCritical")
	}
}

func TestFileOverridesEnv(t *testing.T) {
	t.Setenv("BARK_URL", "https://api.day.app/envkey")
	t.Setenv("PERM_TIMEOUT_SECONDS", "42")
	t.Setenv("PERM_AUTO_PASS_NONCRITICAL", "1")
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.toml")
	// 文件显式写了 bark.url 和 timeout，但没写 auto_pass → 后两者保持 env/默认。
	content := "[bark]\nurl = \"https://api.day.app/filekey\"\n\n[permission]\ntimeout_seconds = 120\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Bark.URL != "https://api.day.app/filekey" {
		t.Errorf("文件未覆盖 Bark.URL = %q", c.Bark.URL)
	}
	if c.Permission.TimeoutSeconds != 120 {
		t.Errorf("文件未覆盖 TimeoutSeconds = %d", c.Permission.TimeoutSeconds)
	}
	if !c.Permission.AutoPassNonCritical {
		t.Errorf("文件未写 auto_pass 时应保留 env 值，却为 false")
	}
}

func TestSaveRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "relay.toml")
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	c.Bark.URL = "https://api.day.app/key"
	c.Permission.TimeoutSeconds = 90
	c.Permission.AutoPassNonCritical = true

	if err := Save(path, c); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatalf("Load after Save: %v", err)
	}
	if got.Bark.URL != c.Bark.URL || got.Permission.TimeoutSeconds != 90 || !got.Permission.AutoPassNonCritical {
		t.Errorf("往返不一致: got %+v, want %+v", got, c)
	}
}
