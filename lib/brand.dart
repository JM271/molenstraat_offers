import 'package:flutter/material.dart';

const logoAsset = 'assets/brand/logo.png';
const logoWhiteAsset = 'assets/brand/logo_white.png';

/// The Molenstraat Fatbikes wordmark, black on light and white on dark
/// backgrounds.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.height = 28});

  final double height;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Image.asset(
      dark ? logoWhiteAsset : logoAsset,
      height: height,
      fit: BoxFit.contain,
      semanticLabel: 'Molenstraat Fatbikes',
      // Keeps the layout intact if the asset is missing.
      errorBuilder: (_, _, _) => const Text('Molenstraat Fatbikes'),
    );
  }
}
