import 'package:flutter/material.dart';
import 'package:wmr_companion/wmr_companion.dart';

/// Per-hand counters from the facade, in the units of the active stream.
///
/// The same widget serves raw (frames) and decoded (records) sessions; fields
/// the stream does not fill are shown as `-` rather than zero.
class HandStatsView extends StatelessWidget {
  const HandStatsView({
    super.key,
    required this.hand,
    required this.stats,
    this.style,
  });

  final Hand hand;
  final WmrHandStats stats;
  final TextStyle? style;

  static String _ms(double s) => (s * 1000).toStringAsFixed(2);
  static String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final name = hand == Hand.left ? 'LEFT' : 'RIGHT';
    final dt = stats.dt;
    final loss = stats.windowLoss;
    // Raw FF11 has no decoded rate/loss counters; show '-' rather than 0.
    final decoded = stats.records > 0 || stats.missingFromTicks > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$name  frames ${stats.frames}  records ${stats.records}  '
          'rate ${decoded ? '${stats.rateHz.toStringAsFixed(1)} Hz' : '-'}  '
          'seq ${stats.lastSequence ?? '-'}',
          style: style,
        ),
        Text(
          '  gaps ${stats.sequenceGaps}  out of order ${stats.outOfOrder}  '
          'missing (ticks) ${decoded ? stats.missingFromTicks : '-'}',
          style: style,
        ),
        Text(
          '  loss ${decoded ? _pct(stats.cumulativeLoss) : '-'} cumulative  '
          '${loss == null ? '-' : _pct(loss.loss)} last 5 s',
          style: style,
        ),
        if (dt != null)
          Text(
            '  dt p50 ${_ms(dt.p50)} ms  p95 ${_ms(dt.p95)} ms  '
            'max ${_ms(dt.max)} ms',
            style: style,
          ),
        if (stats.periodTicks != null)
          Text(
            '  nominal period '
            '${(stats.periodTicks! * 1e-4).toStringAsFixed(2)} ms',
            style: style,
          ),
      ],
    );
  }
}
