import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_assets.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'root_shell.dart';

/// First-run screen — mirrors the Joytify reference's name-capture intro:
/// big bold wordmark, a name field, a "Get Started" CTA, and a privacy
/// disclaimer. The name just personalizes the Home greeting; everything
/// else about the app (server, library, queue) works identically with or
/// without it, so "Skip" is always available.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = TextEditingController();

  void _continue([String? name]) {
    final app = context.read<AppState>();
    app.setUsername(name ?? _controller.text);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const RootShell()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: () => _continue(''),
                  child: const Text('Skip', style: TextStyle(color: TaarColors.creamDim, fontSize: 15)),
                ),
              ),
              const Spacer(flex: 3),
              Image.asset(AppAssets.logoWhite, width: 54, height: 54),
              const SizedBox(height: 18),
              Text('Taar', style: TaarTheme.display(context, size: 56, weight: FontWeight.w800).copyWith(
                    color: TaarColors.marigold,
                    height: 1.0,
                  )),
              Text('Hear Everything.', style: TaarTheme.display(context, size: 40, weight: FontWeight.w800).copyWith(
                    color: Colors.white,
                    height: 1.05,
                  )),
              const Spacer(flex: 3),
              TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: const InputDecoration(
                  hintText: 'Enter Your Name',
                  prefixIcon: Icon(Icons.person_outline, color: TaarColors.marigold),
                ),
                onSubmitted: (v) => _continue(v),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: TaarColors.marigold,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => _continue(),
                  child: const Text('Get Started', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Disclaimer: We respect your privacy. Your name, settings and liked '
                'songs are stored locally on this device only.',
                style: TextStyle(color: TaarColors.creamDim, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }
}
