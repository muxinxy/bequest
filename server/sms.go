package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	openapi "github.com/alibabacloud-go/darabonba-openapi/v2/client"
	dysmsapi "github.com/alibabacloud-go/dysmsapi-20170525/v5/client"
	dara "github.com/alibabacloud-go/tea/dara"
	"github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common"
	"github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common/profile"
	tcSms "github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/sms/v20210111"
)

// ---------- 短信发送 ----------

// SmsSender 发送一条短信;失败返回 error(调用方轮询下一个 provider)。
type SmsSender interface {
	Send(phone, body string) error
}

// tencentSender:腾讯云短信(参考 geekai 真实项目)。
type tencentSender struct {
	secretID, secretKey, sdkAppID, signName, templateID, region string
}

func (s *tencentSender) Send(phone, body string) error {
	credential := common.NewCredential(s.secretID, s.secretKey)
	cpf := profile.NewClientProfile()
	cpf.HttpProfile.Endpoint = "sms.tencentcloudapi.com"
	region := s.region
	if region == "" {
		region = "ap-guangzhou"
	}
	client, err := tcSms.NewClient(credential, region, cpf)
	if err != nil {
		return err
	}
	req := tcSms.NewSendSmsRequest()
	req.SmsSdkAppId = common.StringPtr(s.sdkAppID)
	req.SignName = common.StringPtr(s.signName)
	req.TemplateId = common.StringPtr(s.templateID)
	req.PhoneNumberSet = common.StringPtrs([]string{phone})
	req.TemplateParamSet = common.StringPtrs([]string{body})
	resp, err := client.SendSms(req)
	if err != nil {
		return err
	}
	if resp.Response.SendStatusSet == nil || len(resp.Response.SendStatusSet) == 0 {
		return errors.New("sms: empty send status")
	}
	if *resp.Response.SendStatusSet[0].Code != "Ok" {
		return fmt.Errorf("sms: %s %s", *resp.Response.SendStatusSet[0].Code, *resp.Response.SendStatusSet[0].Message)
	}
	return nil
}

// aliyunSender:阿里云短信(dysmsapi v5)。
type aliyunSender struct {
	ak, sk, signName, templateCode, endpoint string
}

func (s *aliyunSender) Send(phone, body string) error {
	config := &openapi.Config{
		AccessKeyId:     dara.String(s.ak),
		AccessKeySecret: dara.String(s.sk),
		Endpoint:        dara.String(s.endpoint),
	}
	client, err := dysmsapi.NewClient(config)
	if err != nil {
		return err
	}
	params, _ := json.Marshal(map[string]string{"body": body})
	req := &dysmsapi.SendSmsRequest{
		PhoneNumbers:  dara.String(phone),
		SignName:      dara.String(s.signName),
		TemplateCode:  dara.String(s.templateCode),
		TemplateParam: dara.String(string(params)),
	}
	resp, err := client.SendSms(req)
	if err != nil {
		return err
	}
	if resp.Body == nil || resp.Body.Code == nil || *resp.Body.Code != "OK" {
		msg := ""
		if resp.Body != nil && resp.Body.Message != nil {
			msg = *resp.Body.Message
		}
		return fmt.Errorf("sms: %s", msg)
	}
	return nil
}

// smsProviderRow 是 sms_providers 表的一行。
type smsProviderRow struct {
	id        int64
	provider  string
	name      string
	accessKey string
	secretKey string
	extra     string
}

// newSender 按 provider 类型构造发送器(extra 为 JSON 配置)。
func newSender(p smsProviderRow) (SmsSender, error) {
	switch p.provider {
	case "tencent":
		var e struct {
			SDKAppID   string `json:"sdk_app_id"`
			SignName   string `json:"sign_name"`
			TemplateID string `json:"template_id"`
			Region     string `json:"region"`
		}
		if p.extra != "" {
			json.Unmarshal([]byte(p.extra), &e)
		}
		return &tencentSender{secretID: p.accessKey, secretKey: p.secretKey,
			sdkAppID: e.SDKAppID, signName: e.SignName, templateID: e.TemplateID, region: e.Region}, nil
	case "aliyun":
		var e struct {
			SignName     string `json:"sign_name"`
			TemplateCode string `json:"template_code"`
			Endpoint     string `json:"endpoint"`
		}
		if p.extra != "" {
			json.Unmarshal([]byte(p.extra), &e)
		}
		if e.Endpoint == "" {
			e.Endpoint = "dysmsapi.aliyuncs.com"
		}
		return &aliyunSender{ak: p.accessKey, sk: p.secretKey,
			signName: e.SignName, templateCode: e.TemplateCode, endpoint: e.Endpoint}, nil
	}
	return nil, fmt.Errorf("unknown provider %q", p.provider)
}

// enabledSMSProviders 读取 enabled=1 的短信提供商配置。
func enabledSMSProviders(db *sql.DB) []smsProviderRow {
	rows, err := db.Query(`SELECT id, provider, name, access_key, secret_key, COALESCE(extra, '')
		FROM sms_providers WHERE enabled = 1 ORDER BY id`)
	if err != nil {
		log.Printf("query sms providers: %v", err)
		return nil
	}
	defer rows.Close()
	var list []smsProviderRow
	for rows.Next() {
		var p smsProviderRow
		if err := rows.Scan(&p.id, &p.provider, &p.name, &p.accessKey, &p.secretKey, &p.extra); err != nil {
			log.Printf("scan sms provider: %v", err)
			return nil
		}
		list = append(list, p)
	}
	return list
}

var smsRR int // round-robin cursor over enabled sms providers

// sendSMS 轮询所有 enabled 提供商逐个尝试,成功即返回;无配置则打日志跳过。
func sendSMS(db *sql.DB, phone, body string) {
	providers := enabledSMSProviders(db)
	if len(providers) == 0 {
		log.Printf("sms skipped (no provider): phone=%s", phone)
		return
	}
	n := len(providers)
	start := smsRR % n
	for i := 0; i < n; i++ {
		p := providers[(start+i)%n]
		sender, err := newSender(p)
		if err != nil {
			log.Printf("sms provider %s: %v", p.name, err)
			continue
		}
		if err := sender.Send(phone, body); err != nil {
			log.Printf("sms via %s: %v", p.name, err)
			continue
		}
		smsRR = (start + i + 1) % n
		log.Printf("sms sent via %s to=%s", p.name, phone)
		return
	}
	log.Printf("sms failed via all %d providers: phone=%s", n, phone)
}

// ---------- 短信提供商 admin 管理 ----------

type smsProviderJSON struct {
	ID        int64  `json:"id"`
	Provider  string `json:"provider"`
	Name      string `json:"name"`
	AccessKey string `json:"access_key"`
	SecretKey string `json:"secret_key"`
	Extra     string `json:"extra"`
	Enabled   int    `json:"enabled"`
	CreatedAt string `json:"created_at"`
}

type smsProviderRequest struct {
	Provider  string `json:"provider"`
	Name      string `json:"name"`
	AccessKey string `json:"access_key"`
	SecretKey string `json:"secret_key"`
	Extra     string `json:"extra"`
	Enabled   *int   `json:"enabled"` // 指针:PUT 缺省不改
}

func scanSMSProvider(row *sql.Row) (*smsProviderJSON, error) {
	var p smsProviderJSON
	var extra sql.NullString
	if err := row.Scan(&p.ID, &p.Provider, &p.Name, &p.AccessKey, &p.SecretKey, &extra, &p.Enabled, &p.CreatedAt); err != nil {
		return nil, err
	}
	if extra.Valid {
		p.Extra = extra.String
	}
	return &p, nil
}

func validateSMSProvider(req smsProviderRequest) string {
	if req.Provider != "tencent" && req.Provider != "aliyun" {
		return "provider 仅支持 tencent/aliyun"
	}
	if strings.TrimSpace(req.Name) == "" {
		return "配置名称必填"
	}
	if strings.TrimSpace(req.AccessKey) == "" || strings.TrimSpace(req.SecretKey) == "" {
		return "access_key 和 secret_key 必填"
	}
	return ""
}

// handleAdminListSMSProviders: GET /api/v1/admin/sms-providers -> 200 []
func handleAdminListSMSProviders(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, provider, name, access_key, secret_key, COALESCE(extra, ''), enabled, created_at
			FROM sms_providers ORDER BY id`)
		if err != nil {
			log.Printf("list sms providers: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []smsProviderJSON{}
		for rows.Next() {
			var p smsProviderJSON
			var extra sql.NullString
			if err := rows.Scan(&p.ID, &p.Provider, &p.Name, &p.AccessKey, &p.SecretKey, &extra, &p.Enabled, &p.CreatedAt); err != nil {
				log.Printf("scan sms provider: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if extra.Valid {
				p.Extra = extra.String
			}
			list = append(list, p)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleAdminCreateSMSProvider: POST /api/v1/admin/sms-providers -> 201
func handleAdminCreateSMSProvider(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req smsProviderRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if msg := validateSMSProvider(req); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		enabled := 1
		if req.Enabled != nil {
			enabled = *req.Enabled
		}
		res, err := db.Exec(`INSERT INTO sms_providers (provider, name, access_key, secret_key, extra, enabled)
			VALUES (?, ?, ?, ?, ?, ?)`, req.Provider, strings.TrimSpace(req.Name),
			strings.TrimSpace(req.AccessKey), strings.TrimSpace(req.SecretKey), req.Extra, enabled)
		if err != nil {
			log.Printf("insert sms provider: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		id, _ := res.LastInsertId()
		auditAdmin(db, userID(r), "sms_provider_create", fmt.Sprintf("id=%d name=%s", id, req.Name))
		p, err := scanSMSProvider(db.QueryRow(`SELECT id, provider, name, access_key, secret_key, COALESCE(extra, ''), enabled, created_at
			FROM sms_providers WHERE id = ?`, id))
		if err != nil {
			log.Printf("fetch sms provider: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusCreated, p)
	}
}

// handleAdminUpdateSMSProvider: PUT /api/v1/admin/sms-providers/{id} -> 200
// 缺省字段不改。
func handleAdminUpdateSMSProvider(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		var req smsProviderRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if req.Provider != "" && req.Provider != "tencent" && req.Provider != "aliyun" {
			writeError(w, http.StatusBadRequest, "provider 仅支持 tencent/aliyun")
			return
		}
		sets, args := []string{}, []any{}
		if req.Provider != "" {
			sets, args = append(sets, "provider = ?"), append(args, req.Provider)
		}
		if req.Name != "" {
			sets, args = append(sets, "name = ?"), append(args, strings.TrimSpace(req.Name))
		}
		if req.AccessKey != "" {
			sets, args = append(sets, "access_key = ?"), append(args, strings.TrimSpace(req.AccessKey))
		}
		if req.SecretKey != "" {
			sets, args = append(sets, "secret_key = ?"), append(args, strings.TrimSpace(req.SecretKey))
		}
		if req.Extra != "" {
			sets, args = append(sets, "extra = ?"), append(args, req.Extra)
		}
		if req.Enabled != nil {
			sets, args = append(sets, "enabled = ?"), append(args, *req.Enabled)
		}
		if len(sets) == 0 {
			writeError(w, http.StatusBadRequest, "没有可更新的字段")
			return
		}
		args = append(args, id)
		res, err := db.Exec(`UPDATE sms_providers SET `+strings.Join(sets, ", ")+` WHERE id = ?`, args...)
		if err != nil {
			log.Printf("update sms provider: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "短信提供商不存在")
			return
		}
		auditAdmin(db, userID(r), "sms_provider_update", fmt.Sprintf("id=%d", id))
		p, err := scanSMSProvider(db.QueryRow(`SELECT id, provider, name, access_key, secret_key, COALESCE(extra, ''), enabled, created_at
			FROM sms_providers WHERE id = ?`, id))
		if err != nil {
			log.Printf("fetch sms provider: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, p)
	}
}

// handleAdminDeleteSMSProvider: DELETE /api/v1/admin/sms-providers/{id} -> 204
func handleAdminDeleteSMSProvider(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		res, err := db.Exec(`DELETE FROM sms_providers WHERE id = ?`, id)
		if err != nil {
			log.Printf("delete sms provider: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "短信提供商不存在")
			return
		}
		auditAdmin(db, userID(r), "sms_provider_delete", fmt.Sprintf("id=%d", id))
		w.WriteHeader(http.StatusNoContent)
	}
}