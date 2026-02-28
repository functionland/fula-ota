package main

import (
	"encoding/json"
	"log"
	"os"
	"time"
)

type Config struct {
	PinningToken    string
	PinningEndpoint string
	PairingSecret   string
	KuboAPI         string
	AutoPinPort     string
	SyncInterval    time.Duration
	PropsFile       string
	RegistryCIDPath string
}

func LoadConfig() *Config {
	cfg := &Config{
		KuboAPI:         getEnv("KUBO_API", "http://127.0.0.1:5001"),
		AutoPinPort:     getEnv("AUTO_PIN_PORT", "3501"),
		PropsFile:       getEnv("PROPS_FILE", "/internal/box_props.json"),
		SyncInterval:    parseDuration(getEnv("SYNC_INTERVAL", "3m")),
		RegistryCIDPath: getEnv("REGISTRY_CID_PATH", "/internal/fula-gateway/registry.cid"),
	}
	cfg.loadProps()
	return cfg
}

func (c *Config) loadProps() {
	data, err := os.ReadFile(c.PropsFile)
	if err != nil {
		log.Printf("config: cannot read %s: %v", c.PropsFile, err)
		c.PinningToken = ""
		c.PinningEndpoint = ""
		c.PairingSecret = ""
		return
	}

	var props map[string]interface{}
	if err := json.Unmarshal(data, &props); err != nil {
		log.Printf("config: cannot parse %s: %v", c.PropsFile, err)
		return
	}

	c.PinningToken = stringVal(props, "auto_pin_token")
	c.PinningEndpoint = stringVal(props, "auto_pin_endpoint")
	c.PairingSecret = stringVal(props, "auto_pin_pairing_secret")
}

func (c *Config) IsPaired() bool {
	return c.PinningToken != "" && c.PinningEndpoint != ""
}

func stringVal(m map[string]interface{}, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return s
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func parseDuration(s string) time.Duration {
	d, err := time.ParseDuration(s)
	if err != nil {
		return 3 * time.Minute
	}
	return d
}
