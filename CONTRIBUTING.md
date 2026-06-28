# Contributing to Abelo 🎵

Thank you for your interest in contributing! Here's everything you need to know.

## 🛠 Development Setup

1. **Fork & clone**
   ```bash
   git clone https://github.com/<your-username>/Abelo.git
   cd Abelo
   ```

2. **Install Flutter 3.x** — follow the [official guide](https://docs.flutter.dev/get-started/install)

3. **Install dependencies**
   ```bash
   flutter pub get
   ```

4. **Run the app**
   ```bash
   flutter run
   ```

## 📐 Code Style

- Follow Dart's official [style guide](https://dart.dev/guides/language/effective-dart/style)
- Run `dart format .` before committing
- Run `flutter analyze` and fix all issues before opening a PR

## 📝 Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add sleep timer feature
fix: resolve crash on Android 14 lock screen
refactor: extract song tile into reusable widget
docs: update README installation steps
style: format lib/screens/home_screen.dart
test: add unit tests for saavn_api decrypt
```

## 🌿 Branching Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Stable, production-ready code |
| `develop` | Integration branch for features |
| `feature/<name>` | Individual feature development |
| `fix/<name>` | Bug fixes |

## 🐛 Reporting Bugs

Use the [Bug Report template](.github/ISSUE_TEMPLATE/bug_report.yml) and include:
- Abelo version
- Android version & device model
- Steps to reproduce
- Logcat output if available (`adb logcat`)

## 🚀 Suggesting Features

Use the [Feature Request template](.github/ISSUE_TEMPLATE/feature_request.yml).

## 📜 License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
