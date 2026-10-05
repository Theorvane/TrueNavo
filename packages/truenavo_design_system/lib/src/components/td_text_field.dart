import 'package:flutter/material.dart';

import '../foundations/sizing_tokens.dart';
import '../foundations/spacing_tokens.dart';
import '../foundations/typography_tokens.dart';
import '../theme/truenavo_theme_extension.dart';

class TdTextField extends StatelessWidget {
  const TdTextField({
    required this.label,
    required this.controller,
    this.fieldKey,
    this.hintText,
    this.helperText,
    this.errorText,
    this.prefixIcon,
    this.keyboardType,
    this.enabled = true,
    this.secret = false,
    this.obscureText = false,
    this.onToggleSecret,
    super.key,
  });
  final String label;
  final TextEditingController controller;
  final Key? fieldKey;
  final String? hintText;
  final String? helperText;
  final String? errorText;
  final IconData? prefixIcon;
  final TextInputType? keyboardType;
  final bool enabled;
  final bool secret;
  final bool obscureText;
  final VoidCallback? onToggleSecret;

  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final hasMessage = errorText != null || helperText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TdTypography.label.copyWith(color: td.textPrimary)),
        const SizedBox(height: TdSpacing.inline),
        TextField(
          key: fieldKey,
          controller: controller,
          keyboardType: keyboardType,
          enabled: enabled,
          obscureText: secret && obscureText,
          enableSuggestions: !secret,
          enableIMEPersonalizedLearning: !secret,
          autocorrect: !secret,
          style: TdTypography.body.copyWith(color: td.textPrimary),
          decoration: InputDecoration(
            hintText: hintText,
            prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
            suffixIcon: secret
                ? SizedBox(
                    width: TdSizing.minimumTouchTarget,
                    height: TdSizing.minimumTouchTarget,
                    child: IconButton(
                      tooltip: obscureText ? 'Show $label' : 'Hide $label',
                      onPressed: enabled ? onToggleSecret : null,
                      icon: Icon(
                        obscureText
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  )
                : null,
            errorText: errorText,
            helperText: helperText,
            helperMaxLines: 2,
            errorMaxLines: 2,
          ),
        ),
        if (!hasMessage) const SizedBox(height: 0),
      ],
    );
  }
}
