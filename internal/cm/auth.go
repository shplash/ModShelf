package cm

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/BirknerAlex/go-steam/internal/proto"
)

const (
	// LoginProtocolVersion sent in CMsgClientLogon.protocol_version.
	// Must match MsgClientLogon.CurrentProtocol from SteamKit2/SteamLanguageInternal.cs.
	LoginProtocolVersion = 65581

	// obfuscationMask is XOR'd with the local IP before sending.
	// Matches MsgClientLogon.ObfuscationMask in SteamKit2.
	obfuscationMask = uint32(0xBAADF00D)

	// obfuscatedIP = 0.0.0.0 ^ obfuscationMask (we don't know/care about the real IP).
	obfuscatedIP = obfuscationMask
)

// prepareCredentials verifies that an access token is available before the
// CM WebSocket is opened.  Token acquisition (SteamAuthViaCM) must happen
// BEFORE NewSession is called, so by the time this runs the token is either
// already in s.cfg.AccessToken or the caller forgot to authenticate first.
func (s *Session) prepareCredentials(_ context.Context) error {
	if s.cfg.Anonymous || s.cfg.AccessToken != "" {
		return nil
	}
	return &permanentError{fmt.Errorf("cm: no access token — call SteamAuthViaCM before NewSession")}
}

// authenticate performs the CM logon.  By the time this is called,
// prepareCredentials has already obtained a valid access token.
func (s *Session) authenticate(ctx context.Context) error {
	s.setState(StateAuthenticating)

	if s.cfg.Anonymous {
		return s.loginAnonymous(ctx)
	}
	return s.loginWithToken(ctx, s.cfg.AccessToken)
}

// anonSteamID is the SteamID used in the proto header for anonymous logon.
// SteamKit2 LogOnAnonymous() uses EAccountType.AnonUser = 10 (NOT AnonGameServer=4).
// Universe=1 (Public), AccountType=10, Instance=0, AccountID=0
// → (1<<56) | (10<<52) = 0x01A0000000000000
const anonSteamID = uint64(0x01A0000000000000)

// individualSteamID is a placeholder Individual SteamID used in the proto header
// for token-based logon.  SteamKit2 LogOnWithToken() sets EAccountType.Individual
// (not AnonUser) so the CM processes the logon as a user session and validates
// the token.  The server replaces this with the real SteamID in its response.
// Universe=1 (Public), AccountType=1 (Individual), Instance=1 (Desktop), AccountID=0
// → (1<<56) | (1<<52) | (1<<32) = 0x0110000100000000
const individualSteamID = uint64(0x0110000100000000)

// loginAnonymous sends a CMsgClientLogon for an anonymous session.
// Matches SteamKit2 SteamUser.LogOnAnonymous() — see SteamMsgClientServerLogin.cs for field numbers.
func (s *Session) loginAnonymous(ctx context.Context) error {
	// Set anonymous SteamID in header before sending (matches SteamKit2).
	s.mu.Lock()
	s.steamID = anonSteamID
	s.mu.Unlock()

	logon := proto.CMsgClientLogon{
		ProtocolVersion:               LoginProtocolVersion,
		DeprecatedObfuscatedPrivateIP: obfuscatedIP, // 0.0.0.0 ^ 0xBAADF00D
		ClientOsType:                  clientOsLinux,
		ClientLanguage:                clientLang,
	}
	return s.sendLogon(ctx, logon.Marshal())
}

// loginWithToken sends CMsgClientLogon using a refresh token in proto field 108.
// The proto header steamid must be set to an Individual SteamID before logon —
// the CM uses the AccountType in the header to determine logon mode and will
// treat an AnonUser SteamID as an anonymous session, silently ignoring the token.
// SteamKit2 LogOnWithToken() sets EAccountType.Individual with AccountID=0;
// the server replaces it with the real SteamID in the response header.
func (s *Session) loginWithToken(ctx context.Context, token string) error {
	s.mu.Lock()
	s.steamID = individualSteamID
	s.mu.Unlock()

	logon := proto.CMsgClientLogon{
		ProtocolVersion: LoginProtocolVersion,
		AccountName:     s.cfg.AccountName,
		AccessToken:     token,
		ClientOsType:    clientOsLinux,
		ClientLanguage:  clientLang,
		MachineName:     "steam-go",
	}
	return s.sendLogon(ctx, logon.Marshal())
}

// sendLogon registers the logon-response handler, captures the connLost
// channel, and then sends the body — all before blocking on the response.
// This ordering prevents two races:
//  1. Server responds before handler is registered (very unlikely but real).
//  2. Connection drops after send but before ConnLost is captured (real).
func (s *Session) sendLogon(ctx context.Context, body []byte) error {
	ch := make(chan *proto.Packet, 1)
	deregister := s.dispatch.RegisterHandler(proto.EMsgClientLogOnResponse, func(pkt *proto.Packet) {
		select {
		case ch <- pkt:
		default:
		}
	})
	defer deregister()

	// Capture connLost BEFORE sending so a fast disconnect is never missed.
	connLost := s.dispatch.ConnLost()

	if err := s.dispatch.SendNoReply(proto.EMsgClientLogon, body); err != nil {
		return fmt.Errorf("cm: logon send: %w", err)
	}

	logonCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	select {
	case <-logonCtx.Done():
		return fmt.Errorf("cm: logon timeout")
	case <-connLost:
		return fmt.Errorf("cm: connection lost during logon")
	case pkt := <-ch:
		return s.parseLogonResponse(pkt)
	}
}

func (s *Session) parseLogonResponse(pkt *proto.Packet) error {
	var resp proto.CMsgClientLogonResponse
	if err := resp.Unmarshal(pkt.Body); err != nil {
		return fmt.Errorf("cm: parse logon response: %w", err)
	}

	// SteamID is in the proto header (not the body) — matches SteamKit2 CMClient.HandleLogOnResponse.
	s.log.Debug("CM logon response", "eresult", resp.Eresult, "steamid", pkt.Header.Steamid, "session", pkt.Header.ClientSessionid)

	if proto.EResult(resp.Eresult) != proto.EResultOK {
		er := proto.EResult(resp.Eresult)
		switch er {
		case proto.EResultAccountLogonDenied, proto.EResultAccountLogonDeniedNoMail:
			return &permanentError{errSteamGuard}
		case proto.EResultInvalidPassword:
			return &permanentError{errInvalidCreds}
		default:
			return fmt.Errorf("cm: logon failed: EResult %d", er)
		}
	}

	// heartbeat_seconds is field 3 in CMsgClientLogonResponse (matches SteamKit2).
	heartbeatInterval := time.Duration(resp.HeartbeatSeconds) * time.Second
	if heartbeatInterval <= 0 {
		heartbeatInterval = 30 * time.Second
	}

	s.mu.Lock()
	// Server assigns the SteamID in the response proto header.
	if pkt.Header.Steamid != 0 {
		s.steamID = pkt.Header.Steamid
	}
	s.sessionID = pkt.Header.ClientSessionid
	s.mu.Unlock()

	s.setState(StateReady)
	s.startHeartbeat(heartbeatInterval)
	return nil
}

// Sentinel errors for auth failures (exposed via package-level vars in session.go).
var (
	errSteamGuard   = fmt.Errorf("steam guard required")
	errInvalidCreds = fmt.Errorf("invalid credentials")
)

// permanentError wraps an auth error that must not be retried.
// connectLoop checks for this and aborts the retry loop immediately.
type permanentError struct{ err error }

func (e *permanentError) Error() string { return e.err.Error() }
func (e *permanentError) Unwrap() error { return e.err }

// ---- Steam Authentication via CM Unified Messages ----------------------------
//
// Steam's authentication API (IAuthenticationService) is called via the CM
// so that the resulting tokens carry aud:["client"] and are accepted by the CM
// for CMsgClientLogon field 108 (access_token).
// The HTTP path issues aud:["web"] tokens that the CM rejects.

// AuthTokenPair holds the tokens returned by a successful Steam auth flow.
type AuthTokenPair struct {
	// AccessToken is the short-lived token (aud: ["client"]) passed directly
	// to CMsgClientLogon.access_token.
	AccessToken string
	// RefreshToken is the long-lived token for caching.
	RefreshToken string
}

type rsaKeyResponse struct {
	Response struct {
		PublickeyMod string `json:"publickey_mod"`
		PublickeyExp string `json:"publickey_exp"`
		Timestamp    string `json:"timestamp"`
	} `json:"response"`
}

// fetchRSAKey fetches Steam's per-account RSA public key via HTTP.
// Returns the key and the timestamp string used in BeginAuthSessionViaCredentials.
func fetchRSAKey(ctx context.Context, username string) (pubKey *rsa.PublicKey, timestamp string, err error) {
	const rsaURL = "https://api.steampowered.com/IAuthenticationService/GetPasswordRSAPublicKey/v1/"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		rsaURL+"?account_name="+url.QueryEscape(username), nil)
	if err != nil {
		return nil, "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("auth rsa key: %w", err)
	}
	defer resp.Body.Close()

	var r rsaKeyResponse
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nil, "", fmt.Errorf("auth rsa key decode: %w", err)
	}

	modBytes, ok1 := new(big.Int).SetString(r.Response.PublickeyMod, 16)
	expBytes, ok2 := new(big.Int).SetString(r.Response.PublickeyExp, 16)
	if !ok1 || !ok2 {
		return nil, "", fmt.Errorf("auth rsa key: invalid key hex")
	}
	pub := &rsa.PublicKey{N: modBytes, E: int(expBytes.Int64())}
	return pub, r.Response.Timestamp, nil
}

// SteamAuthViaCM performs the full Steam Authentication v2 flow through an
// existing CM session (typically the anonymous session).  Using the CM path
// with platform_type=SteamClient causes the server to issue tokens with
// aud:["client"] that CMsgClientLogon accepts.
//
// guardCallback is called when Steam requires a Guard code.
func SteamAuthViaCM(ctx context.Context, sess *Session, username, password string, guardCallback func() (string, error)) (*AuthTokenPair, error) {
	// Step 1 — RSA key (HTTP; it's account-public and safe to fetch over the web).
	rsaPub, rsaTimestampStr, err := fetchRSAKey(ctx, username)
	if err != nil {
		return nil, fmt.Errorf("auth: get rsa key: %w", err)
	}
	encryptedPw, err := rsa.EncryptPKCS1v15(rand.Reader, rsaPub, []byte(password)) //nolint:staticcheck // Steam mandates PKCS#1 v1.5
	if err != nil {
		return nil, fmt.Errorf("auth: encrypt password: %w", err)
	}
	rsaTimestamp, err := strconv.ParseUint(rsaTimestampStr, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("auth: parse rsa timestamp %q: %w", rsaTimestampStr, err)
	}

	// Step 2 — BeginAuthSessionViaCredentials via CM unified message.
	// platform_type=1 (SteamClient) inside device_details issues aud:["client"]
	// tokens; the HTTP auth path produces aud:["web"] tokens the CM rejects.
	beginReq := proto.CAuthentication_BeginAuthSessionViaCredentials_Request{
		AccountName:         username,
		EncryptedPassword:   base64.StdEncoding.EncodeToString(encryptedPw),
		EncryptionTimestamp: rsaTimestamp,
		Persistence:         1, // k_ESessionPersistence_Persistent
		WebsiteID:           "Client",
		DeviceDetails: proto.CAuthentication_DeviceDetails{
			DeviceFriendlyName: "steam-go",
			PlatformType:       1, // k_EAuthTokenPlatformType_SteamClient
		},
	}
	jobID, err := sess.SendServiceMethod(ctx, "Authentication.BeginAuthSessionViaCredentials#1", beginReq.Marshal())
	if err != nil {
		return nil, fmt.Errorf("auth begin: %w", err)
	}
	pkt, err := sess.Await(ctx, jobID)
	if err != nil {
		return nil, fmt.Errorf("auth begin await: %w", err)
	}
	if proto.EResult(pkt.Header.Eresult) != proto.EResultOK && pkt.Header.Eresult != 0 {
		er := proto.EResult(pkt.Header.Eresult)
		if er == proto.EResultInvalidPassword {
			return nil, fmt.Errorf("auth begin: invalid credentials or account temporarily locked (too many failed attempts)")
		}
		return nil, fmt.Errorf("auth begin: EResult %d", pkt.Header.Eresult)
	}
	var beginResp proto.CAuthentication_BeginAuthSessionViaCredentials_Response
	if err := beginResp.Unmarshal(pkt.Body); err != nil {
		return nil, fmt.Errorf("auth begin unmarshal: %w", err)
	}

	clientID := beginResp.ClientID
	requestID := beginResp.RequestID
	steamID := beginResp.SteamID
	interval := float64(beginResp.Interval)
	if interval <= 0 {
		interval = 5
	}

	
	// Step 3 — handle Steam Guard if required.
	const (
		guardTypeNone              = 1
		guardTypeEmail              = 2
		guardTypeDevice             = 3
		guardTypeDeviceConfirmation = 4
		guardTypeEmailConfirmation  = 5
	)
	guardType := 0
	for _, c := range beginResp.AllowedConfirmations {
		t := int(c.ConfirmationType)
		if t == guardTypeDeviceConfirmation ||
			t == guardTypeEmailConfirmation {
			guardType = t
			break
		}
		if guardType == 0 && t != guardTypeNone {
			guardType = t
		}
	}

	// Mobile/email approval happens in the Steam app; wait for
	// Steam to issue tokens rather than requesting a one-time code.
	if guardType != 0 &&
		guardType != guardTypeDeviceConfirmation &&
		guardType != guardTypeEmailConfirmation {
		if guardType != guardTypeEmail && guardType != guardTypeDevice {
			return nil, fmt.Errorf("auth: unsupported Steam Guard type %d", guardType)
		}
		if guardCallback == nil {
			return nil, fmt.Errorf("auth: Steam Guard required but no callback provided")
		}
		code, err := guardCallback()
		if err != nil {
			return nil, fmt.Errorf("auth: Steam Guard: %w", err)
		}
		updateReq := proto.CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request{
			ClientID: clientID,
			SteamID:  steamID,
			Code:     code,
			CodeType: int32(guardType),
		}
		jobID, err = sess.SendServiceMethod(ctx, "Authentication.UpdateAuthSessionWithSteamGuardCode#1", updateReq.Marshal())
		if err != nil {
			return nil, fmt.Errorf("auth guard: %w", err)
		}
		pkt, err = sess.Await(ctx, jobID)
		if err != nil {
			return nil, fmt.Errorf("auth guard await: %w", err)
		}
		if proto.EResult(pkt.Header.Eresult) != proto.EResultOK && pkt.Header.Eresult != 0 {
			return nil, fmt.Errorf("auth: Steam Guard rejected: EResult %d (wrong code?)", pkt.Header.Eresult)
		}
	}

	// Step 4 — poll until auth is complete.
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Duration(interval * float64(time.Second))):
		}

		pollReq := proto.CAuthentication_PollAuthSessionStatus_Request{
			ClientID:  clientID,
			RequestID: requestID,
		}
		jobID, err = sess.SendServiceMethod(ctx, "Authentication.PollAuthSessionStatus#1", pollReq.Marshal())
		if err != nil {
			return nil, fmt.Errorf("auth poll: %w", err)
		}
		pkt, err = sess.Await(ctx, jobID)
		if err != nil {
			return nil, fmt.Errorf("auth poll await: %w", err)
		}
		if proto.EResult(pkt.Header.Eresult) != proto.EResultOK && pkt.Header.Eresult != 0 {
			return nil, fmt.Errorf("auth poll: EResult %d", pkt.Header.Eresult)
		}
		var pollResp proto.CAuthentication_PollAuthSessionStatus_Response
		if err := pollResp.Unmarshal(pkt.Body); err != nil {
			return nil, fmt.Errorf("auth poll unmarshal: %w", err)
		}
		if pollResp.AccessToken != "" && pollResp.RefreshToken != "" {
			return &AuthTokenPair{
				AccessToken:  pollResp.RefreshToken, // used in CMsgClientLogon field 108
				RefreshToken: pollResp.RefreshToken, // same, stored for cache expiry tracking
			}, nil
		}
	}
}
