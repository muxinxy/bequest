package main

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"time"
)

// ---------- IM webhook 发送(企业微信/钉钉/飞书) ----------

// imClient:webhook 失败不阻塞主流程,超时 10s 后放弃。
var imClient = &http.Client{Timeout: 10 * time.Second}

// sendIMWebhook 向指定平台 webhook POST 一条消息;发送失败重试 2 次(共 3 次
// 尝试,间隔 1 秒),仍失败只 log 不返回。签名/加签参数由用户在配置 webhook URL
// 时自行拼好,这里按原样发送。
func sendIMWebhook(url, platform, title, body string) {
	var payload []byte
	switch platform {
	case "wecom": // 企业微信 markdown
		payload, _ = json.Marshal(map[string]any{
			"msgtype":  "markdown",
			"markdown": map[string]string{"content": "**" + title + "**\n" + body},
		})
	case "dingtalk": // 钉钉 markdown
		payload, _ = json.Marshal(map[string]any{
			"msgtype":  "markdown",
			"markdown": map[string]string{"title": title, "text": "### " + title + "\n" + body},
		})
	default: // 飞书 text
		payload, _ = json.Marshal(map[string]any{
			"msg_type": "text",
			"content":  map[string]string{"text": title + "\n" + body},
		})
	}
	for attempt := 0; attempt < 3; attempt++ {
		resp, err := imClient.Post(url, "application/json", bytes.NewReader(payload))
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode < 300 {
				return
			}
			log.Printf("im webhook (%s): status=%d", platform, resp.StatusCode)
		} else {
			log.Printf("im webhook (%s): %v", platform, err)
		}
		if attempt < 2 {
			time.Sleep(time.Second)
		}
	}
}
