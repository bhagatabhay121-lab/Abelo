# Security Policy

## ⚠️ Important — Session Cookie

`lib/api/saavn_api.dart` contains a `_sessionCookie` constant that was populated
with a **real browser session cookie** during development. This cookie includes
geolocation, session tokens, and ad-tracking identifiers tied to a personal account.

**Before making the repository public:**
1. Replace the value of `_sessionCookie` with an empty string or a placeholder:
   ```dart
   static const String _sessionCookie = ''; // Add your own session cookie
   ```
2. Rotate your JioSaavn session by logging out and back in on the web.
3. Ensure `android/key.properties` (signing keystore credentials) is listed in `.gitignore` and never committed.

## 🔒 Reporting a Vulnerability

If you discover a security issue, **do not open a public issue**. Instead, email
the maintainer directly. You will receive a response within 72 hours.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | ✅        |
| < 1.0   | ❌        |
