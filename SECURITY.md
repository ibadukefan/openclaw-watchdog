# Security Policy

## Security Design Principles

OpenClaw Watchdog is designed with security as a primary concern. Since it monitors and can restart your OpenClaw gateway, it needs to be hardened against attacks.

### 1. No Dynamic Code Execution

The watchdog script **never** uses:
- `eval`
- `source` with untrusted input
- Backticks with user data
- `$()` with unsanitized input

All paths are hardcoded or validated against allowed prefixes.

### 2. Input Sanitization

All external data is sanitized before use:

```bash
sanitize() {
    local input="$1"
    # Remove dangerous characters: ; | & ` $ ( ) { } [ ] < > \ " '
    echo "$input" | tr -d ';|&`$(){}[]<>\\"'"'"
}
```

This prevents:
- Command injection
- Path traversal (combined with path validation)
- Shell metacharacter attacks

### 3. File Permission Model

| Path | Mode | Purpose |
|------|------|---------|
| `~/.openclaw/watchdog/` | 700 | Watchdog directory |
| `~/.openclaw/watchdog/state.json` | 600 | State file |
| `~/.openclaw/watchdog/metrics.json` | 644 | Metrics (read by menu bar app) |
| `~/.openclaw/watchdog/snapshots/` | 700 | Session snapshots |
| Config files | 600 | Sensitive configuration |

### 4. Secure File Operations

Files are written atomically to prevent corruption:

```bash
secure_write() {
    local file="$1"
    local content="$2"
    local mode="${3:-600}"
    
    local tmp=$(mktemp)
    echo "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$file"  # Atomic rename
}
```

### 5. Ownership Verification

Before reading sensitive files, ownership is verified:

```bash
verify_ownership() {
    local file="$1"
    local owner=$(stat -f %Su "$file" 2>/dev/null)
    [[ "$owner" == "$(whoami)" ]]
}
```

This prevents attacks where a malicious user could plant files.

### 6. Network Timeouts

All network operations have timeouts to prevent hanging:

```bash
timeout 10 curl -s "$GATEWAY_URL/health" 2>/dev/null
```

### 7. No Secrets in Code

The watchdog script contains no secrets. It relies on:
- OpenClaw's configured credentials for Slack
- System permissions for file access

### 8. Process Isolation

The watchdog runs as a LaunchAgent under the user's account, not as root. It has no elevated privileges.

## Threat Model

### Protected Against

| Threat | Mitigation |
|--------|------------|
| Command injection via logs | Input sanitization |
| Path traversal | Path validation |
| Config tampering | Ownership verification |
| Network attacks | Timeouts, HTTPS |
| Privilege escalation | Runs as user, not root |
| File races | Atomic writes |
| Resource exhaustion | Log rotation, cooldowns |

### Not Protected Against

| Threat | Reason |
|--------|--------|
| Root compromise | If attacker has root, game over |
| Physical access | Beyond scope |
| Memory inspection | Would require root |

## Reporting Vulnerabilities

If you find a security issue:

1. **Do not** open a public issue
2. Email security concerns to the maintainer
3. Include steps to reproduce
4. Allow 90 days for a fix before disclosure

## Code Audit Checklist

When reviewing PRs, check for:

- [ ] No `eval` or dynamic execution
- [ ] All inputs sanitized
- [ ] Paths validated
- [ ] Network calls have timeouts
- [ ] File permissions set correctly
- [ ] No hardcoded secrets
- [ ] Ownership verified for sensitive reads

## Version History

| Version | Security Changes |
|---------|-----------------|
| 3.0 | Complete security rewrite |
| 2.0 | Added basic sanitization |
| 1.0 | Initial release |
