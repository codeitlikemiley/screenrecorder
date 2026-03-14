# ScreenRecorder — Publishing Guide

## Prerequisites

- [ ] Apple Developer Program membership ($99/yr) — [developer.apple.com/programs](https://developer.apple.com/programs/)
- [ ] Developer ID Application certificate (see [Step 1](#step-1-create-a-developer-id-certificate))
- [ ] App-Specific Password (see [Step 2](#step-2-create-an-app-specific-password))
- [ ] `create-dmg` installed — `brew install create-dmg`

---

## Step 1: Create a Developer ID Certificate

1. Go to [developer.apple.com/account/resources/certificates/list](https://developer.apple.com/account/resources/certificates/list)
2. Click **+** → Select **"Developer ID Application"** → Continue
3. If asked for a CSR:
   - Open **Keychain Access** → Certificate Assistant → **Request a Certificate From a Certificate Authority**
   - Select **"Saved to disk"** → Upload the `.certSigningRequest` file
4. Download the certificate (`.cer`) and **double-click** to install

**Verify:**
```bash
security find-identity -v -p codesigning | grep "Developer ID"
# Output: "Developer ID Application: Your Name (TEAM_ID)"
```

---

## Step 2: Create an App-Specific Password

1. Go to [account.apple.com](https://account.apple.com) → **Sign-In and Security** → **App-Specific Passwords**
2. Click **+** → Name it `ScreenRecorder Notarization`
3. Copy the password (format: `xxxx-xxxx-xxxx-xxxx`)

---

## Step 3: Configure `.env`

```bash
cp .env.example .env
```

Fill in your values:
```env
APPLE_ID="your-apple-id@example.com"
APPLE_TEAM_ID="YOUR_TEAM_ID"
SIGNING_IDENTITY="Apple Development: Your Name (TEAM_ID)"
RELEASE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAM_ID)"
APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
APP_VERSION="1.0.0"
```

---

## Step 4: Release

```bash
# Bump version in .env, then:
./release.sh
```

The script handles everything automatically:

| Step | Action |
|------|--------|
| 1 | Stamps `APP_VERSION` into `Info.plist` |
| 2 | Builds release binary |
| 3 | Signs with Developer ID (hardened runtime) |
| 4 | Submits to Apple for notarization (~2-5 min) |
| 5 | Staples notarization ticket |
| 6 | Creates DMG |
| 7 | Git tags `v{VERSION}` and force-pushes to trigger GitHub Actions |

The DMG at `.build/ScreenRecorder-{VERSION}.dmg` is ready to distribute.

---

## GitHub Actions (Automated Releases)

The workflow at `.github/workflows/release.yml` is triggered automatically by `release.sh` when it pushes the version tag.

### One-time setup: Repository Secrets

Go to **[github.com/codeitlikemiley/screenrecorder/settings/secrets/actions](https://github.com/codeitlikemiley/screenrecorder/settings/secrets/actions)** and click **"New repository secret"** for each:

| Secret | Value |
|--------|-------|
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Your Team ID |
| `APP_PASSWORD` | App-specific password from Step 2 |
| `SIGNING_IDENTITY` | `Developer ID Application: Your Name (TEAM_ID)` |
| `CERTIFICATE_P12` | Base64-encoded .p12 (see below) |
| `CERTIFICATE_PASSWORD` | Password set when exporting .p12 |
| `KEYCHAIN_PASSWORD` | Any random string (e.g. `gh-actions-2026`) |

### Export certificate as .p12

1. Open **Keychain Access** → **My Certificates** (left sidebar)
2. Find and right-click **"Developer ID Application: …"** → **Export…**
3. Save as `certificate.p12`, set a password when prompted
4. Base64-encode and copy to clipboard:
   ```bash
   base64 -i certificate.p12 | pbcopy
   ```
5. Paste that as the `CERTIFICATE_P12` secret value

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `No identity found` | Developer ID cert not installed — redo Step 1 |
| `The signature is invalid` | Using wrong identity — check `RELEASE_SIGNING_IDENTITY` in `.env` |
| Notarization rejected | Run: `xcrun notarytool log <id> --apple-id ... --team-id ... --password ...` |
| Gatekeeper blocks app | Notarization or stapling failed — re-run `./release.sh` |
