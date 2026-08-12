package acp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 图片附件应内联为 base64 的 ContentBlockImage。
func TestPromptAttachment_ImageToContentBlock(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "shot.png")
	if err := os.WriteFile(p, []byte("fake-png-bytes"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	a := PromptAttachment{Name: "shot.png", MimeType: "image/png", Path: p}
	block, ok := a.toContentBlock()
	if !ok {
		t.Fatal("图片附件应成功转换")
	}
	if block.Image == nil {
		t.Fatalf("期望 Image block，实际 %+v", block)
	}
	if block.Image.MimeType != "image/png" {
		t.Errorf("mimeType = %q", block.Image.MimeType)
	}
	// base64("fake-png-bytes") = ZmFrZS1wbmctYnl0ZXM=
	if block.Image.Data != "ZmFrZS1wbmctYnl0ZXM=" {
		t.Errorf("data base64 = %q", block.Image.Data)
	}
}

// 非图片文件应转为 file:// 资源链接（无需实际读取内容）。
func TestPromptAttachment_FileToResourceLink(t *testing.T) {
	a := PromptAttachment{Name: "notes.txt", MimeType: "text/plain", Path: `C:\Users\me\notes.txt`}
	block, ok := a.toContentBlock()
	if !ok {
		t.Fatal("文件附件应成功转换")
	}
	if block.ResourceLink == nil {
		t.Fatalf("期望 ResourceLink block，实际 %+v", block)
	}
	if !strings.HasPrefix(block.ResourceLink.Uri, "file://") {
		t.Errorf("uri 应以 file:// 开头: %q", block.ResourceLink.Uri)
	}
	if block.ResourceLink.Name != "notes.txt" {
		t.Errorf("name = %q", block.ResourceLink.Name)
	}
}

// 读取失败（文件不存在）应返回 ok=false，便于调用方跳过该附件。
func TestPromptAttachment_MissingImageFails(t *testing.T) {
	a := PromptAttachment{Name: "x.png", MimeType: "image/png", Path: `C:\no\such\file.png`}
	if _, ok := a.toContentBlock(); ok {
		t.Fatal("缺失图片不应转换成功")
	}
}
