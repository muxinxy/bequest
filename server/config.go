package main

import (
	"encoding/json"
	"log"
	"os"
	"strconv"
)

// smtpServer is one SMTP endpoint; used both for system servers (config.json
// or env SMTP_*) and for per-user custom servers.
type smtpServer struct {
	Host     string
	Port     int
	User     string
	Password string
	FromAddr string
}

// provider is a reserved SMS/phone provider entry from config.json. Sending is
// not implemented yet — the count is logged at startup so the channel is visible.
type provider struct {
	Name      string
	APIKey    string
	APISecret string
}

type appConfig struct {
	SMTPServers    []smtpServer `json:"smtp_servers"`
	SMSProviders   []provider   `json:"sms_providers"`
	PhoneProviders []provider   `json:"phone_providers"`
}

var (
	systemServers  []smtpServer
	rrIndex        int // round-robin cursor over systemServers
	smsProviders   []provider
	phoneProviders []provider
)

// loadConfig reads server/config.json once at startup. Absent or unparseable
// -> fall back to the legacy env SMTP_* single server (or none).
func loadConfig() {
	data, err := os.ReadFile("config.json")
	if err != nil {
		log.Printf("no config.json, using env SMTP")
		if host := os.Getenv("SMTP_HOST"); host != "" {
			port := 587
			if p := os.Getenv("SMTP_PORT"); p != "" {
				if n, perr := strconv.Atoi(p); perr == nil && n > 0 {
					port = n
				}
			}
			user := os.Getenv("SMTP_USER")
			from := os.Getenv("SMTP_FROM")
			if from == "" {
				from = user
			}
			systemServers = []smtpServer{{Host: host, Port: port, User: user, Password: os.Getenv("SMTP_PASS"), FromAddr: from}}
		}
		return
	}
	var cfg appConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Printf("config.json parse error: %v", err)
		return
	}
	systemServers = cfg.SMTPServers
	smsProviders = cfg.SMSProviders
	phoneProviders = cfg.PhoneProviders
	log.Printf("sms provider configured: %d, not implemented yet", len(smsProviders))
	log.Printf("phone provider configured: %d, not implemented yet", len(phoneProviders))
}
