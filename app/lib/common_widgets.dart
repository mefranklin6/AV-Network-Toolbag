import 'package:flutter/material.dart';

import 'models.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final compact = Theme.of(context).visualDensity.vertical < 0;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: compact ? 8 : 12,
              runSpacing: compact ? 8 : 12,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                ?trailing,
              ],
            ),
            SizedBox(height: compact ? 12 : 18),
            child,
          ],
        ),
      ),
    );
  }
}

class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.label,
    required this.value,
    required this.kind,
    this.tooltip,
  });

  final String label;
  final String value;
  final StatusKind kind;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    final brightness = Theme.of(context).brightness;
    final (icon, color) = switch (kind) {
      StatusKind.success => (
        Icons.check_circle_rounded,
        brightness == Brightness.dark
            ? const Color(0xFF5EE0B3)
            : const Color(0xFF087F5B),
      ),
      StatusKind.warning => (
        Icons.warning_amber_rounded,
        brightness == Brightness.dark
            ? const Color(0xFFFFD166)
            : const Color(0xFF8A4B00),
      ),
      StatusKind.error => (Icons.error_rounded, scheme.error),
      StatusKind.pending => (Icons.hourglass_top_rounded, scheme.primary),
      StatusKind.neutral => (
        Icons.remove_circle_outline_rounded,
        scheme.onSurfaceVariant,
      ),
    };
    final content = Semantics(
      container: true,
      excludeSemantics: true,
      label: '$label status: $value${tooltip == null ? '' : '. $tooltip'}',
      child: Card(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 16,
            vertical: compact ? 11 : 18,
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: compact ? 22 : 28),
              SizedBox(width: compact ? 8 : 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null
        ? content
        : Tooltip(message: tooltip!, child: content);
  }
}

class DetailRow extends StatelessWidget {
  const DetailRow({
    super.key,
    required this.label,
    required this.value,
    this.monospace = true,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 6 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: compact ? 112 : 132,
            child: Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          SizedBox(width: compact ? 8 : 12),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'Consolas', height: 1.35)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class InlineNotice extends StatelessWidget {
  const InlineNotice({super.key, required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    final color = error ? scheme.error : scheme.tertiary;
    return Semantics(
      liveRegion: true,
      label: error ? 'Error: $message' : 'Notice: $message',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          border: Border.all(color: color.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.error_outline : Icons.info_outline,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}
