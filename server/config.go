package main

import (
	"encoding/json"
	"log"
	"os"
	"strconv"
)

// smtpServer is one SMTP endpoint; used both for system servers (config.json
// or env SMTP_*) and for per-user custom servers. json tags fix from_addr
// unmarshal (Go's case-insensitive match can't cross the underscore).
type smtpServer struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"`
	FromAddr string `json:"from_addr"`
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
	FreeAssetQuota int          `json:"free_asset_quota"`
}

var (
	systemServers  []smtpServer
	rrIndex        int // round-robin cursor over systemServers
	smsProviders   []provider
	phoneProviders []provider
	// freeAssetQuota is the asset cap for free-tier users; members are
	// unlimited. Default 50, overridable via config.json free_asset_quota.
	freeAssetQuota = 50

	// configFile is overridable in tests to avoid touching the repo.
	configFile = "config.json"
)

// readConfigFile parses config.json into an appConfig; absent or unparseable
// file yields the zero value (never fails).
func readConfigFile() appConfig {
	var cfg appConfig
	data, err := os.ReadFile(configFile)
	if err != nil {
		return cfg
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Printf("config.json parse error: %v", err)
	}
	return cfg
}

// writeConfigFile persists cfg to config.json (admin UI updates it live).
func writeConfigFile(cfg appConfig) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(configFile, data, 0o644)
}

// loadConfig reads server/config.json once at startup. Absent file -> fall
// back to the legacy env SMTP_* single server (or none). Called again after
// admin config saves to reload the in-memory providers.
func loadConfig() {
	cfg := readConfigFile()
	systemServers = cfg.SMTPServers
	smsProviders = cfg.SMSProviders
	phoneProviders = cfg.PhoneProviders
	if cfg.FreeAssetQuota > 0 {
		freeAssetQuota = cfg.FreeAssetQuota
	}
	if _, err := os.Stat(configFile); err == nil {
		log.Printf("smtp server configured: %d", len(systemServers))
		log.Printf("sms provider configured: %d, not implemented yet", len(smsProviders))
		log.Printf("phone provider configured: %d, not implemented yet", len(phoneProviders))
		return
	}
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
}
