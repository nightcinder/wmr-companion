import 'package:flutter/material.dart';
import 'package:wmr_companion/wmr_companion.dart';

/// Link parameters and stream state from a [WmrLinkSnapshot].
///
/// Values the platform does not expose (MTU, RSSI, interval, PHY) stay out of
/// the line instead of pretending to be zero.
class LinkStatusView extends StatelessWidget {
  const LinkStatusView(this.link, {super.key, this.style});

  final WmrLinkSnapshot link;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      'link ${link.state.name}',
      if (link.deviceId != null) 'device ${link.deviceId}',
      if (link.mtu != null) 'MTU ${link.mtu}',
      if (link.rssi != null) 'RSSI ${link.rssi} dBm',
      if (link.connectionIntervalUs != null)
        '${(link.connectionIntervalUs! / 1000).toStringAsFixed(1)} ms',
      if (link.phy != null) 'PHY ${link.phy}',
    ];
    final fault = link.fault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(parts.join('  '), style: style),
        Text(
          'mode ${link.mode?.name ?? '-'}'
          '${fault == null ? '' : '  fault ${fault.kind.name}: ${fault.message}'}',
          style: style,
        ),
      ],
    );
  }
}
