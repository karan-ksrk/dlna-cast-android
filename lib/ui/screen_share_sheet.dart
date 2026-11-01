import 'package:flutter/material.dart';

import '../cast_controller.dart';
import '../native.dart';
import 'theme.dart';

Future<void> showScreenShareSheet(BuildContext context, CastController controller) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ScreenShareSheet(controller: controller),
);

class _ScreenShareSheet extends StatefulWidget {
  const _ScreenShareSheet({required this.controller});
  final CastController controller;

  @override
  State<_ScreenShareSheet> createState() => _ScreenShareSheetState();
}

class _ScreenShareSheetState extends State<_ScreenShareSheet> {
  var _quality = Quality.balanced;
  var _audio = ScreenAudio.device;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Share screen to ${widget.controller.selected?.friendlyName ?? 'renderer'}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          const Text('Quality', style: TextStyle(color: Palette.inkDim)),
          RadioGroup<Quality>(
            groupValue: _quality,
            onChanged: (value) => setState(() => _quality = value!),
            child: Column(
              children: [
                for (final quality in Quality.values)
                  RadioListTile<Quality>(
                    value: quality,
                    contentPadding: EdgeInsets.zero,
                    title: Text(quality.label),
                    subtitle: Text(quality.description, style: const TextStyle(color: Palette.inkFaint)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text('Sound', style: TextStyle(color: Palette.inkDim)),
          const SizedBox(height: 8),
          SegmentedButton<ScreenAudio>(
            segments: const [
              ButtonSegment(value: ScreenAudio.device, label: Text('Phone'), icon: Icon(Icons.speaker_phone)),
              ButtonSegment(value: ScreenAudio.mic, label: Text('Mic'), icon: Icon(Icons.mic_none)),
              ButtonSegment(value: ScreenAudio.none, label: Text('None'), icon: Icon(Icons.volume_off_outlined)),
            ],
            selected: {_audio},
            onSelectionChanged: (value) => setState(() => _audio = value.first),
          ),
          const SizedBox(height: 8),
          const Text(
            "Apps that protect their content (Netflix and similar) show black, and some apps don't allow their sound "
            'to be captured.',
            style: TextStyle(color: Palette.inkFaint, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              widget.controller.shareScreen(quality: _quality, audio: _audio);
            },
            icon: const Icon(Icons.screen_share),
            label: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Start sharing')),
          ),
        ],
      ),
    ),
  );
}
