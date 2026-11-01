import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../cast_controller.dart';
import 'brand.dart';
import 'gallery_page.dart';
import 'now_playing.dart';
import 'screen_share_sheet.dart';
import 'theme.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller});
  final CastController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _Header(controller: controller),
            const SizedBox(height: 20),
            _RendererCard(controller: controller),
            const SizedBox(height: 24),
            if (controller.snapshot case final snapshot?) ...[
              NowPlaying(controller: controller, snapshot: snapshot),
              const SizedBox(height: 24),
            ],
            if (controller.busy case final busy?) ...[
              _BusyBanner(text: busy, onCancel: controller.cancelBusy),
              const SizedBox(height: 24),
            ],
            _CastSection(controller: controller),
            const SizedBox(height: 24),
            _ActivityLog(entries: controller.log),
          ],
        ),
      ),
    ),
  );
}

/// The Beam mark and wordmark, with search as a status pill rather than a bare icon.
class _Header extends StatelessWidget {
  const _Header({required this.controller});
  final CastController controller;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const BeamMark(size: 34),
      const SizedBox(width: 10),
      const Expanded(child: Wordmark(size: 22)),
      Material(
        color: Palette.panel,
        shape: const StadiumBorder(side: BorderSide(color: Palette.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: controller.discovering ? null : controller.discover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller.discovering)
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Palette.violet),
                  )
                else
                  const Icon(Icons.refresh_rounded, size: 16, color: Palette.inkDim),
                const SizedBox(width: 6),
                Text(
                  controller.discovering ? 'Searching' : 'Search',
                  style: const TextStyle(color: Palette.inkDim, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(color: Palette.inkFaint, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.4),
  );
}

/// The selected renderer, front and centre, with a status chip and quick switching between the others.
class _RendererCard extends StatelessWidget {
  const _RendererCard({required this.controller});
  final CastController controller;

  Future<void> _addByIp(BuildContext context) async {
    final field = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a renderer by IP'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: '192.168.1.42'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, field.text), child: const Text('Add')),
        ],
      ),
    );
    if (ip != null && ip.trim().isNotEmpty) await controller.addByIp(ip);
  }

  @override
  Widget build(BuildContext context) {
    final selected = controller.selected;
    final live = controller.snapshot != null && controller.snapshot!.device.key == selected?.key;
    final (status, statusColor) = switch (selected) {
      _ when live => ('Live', Palette.violet),
      null when controller.discovering => ('Searching', Palette.inkDim),
      null => ('None found', Palette.coral),
      _ => ('Ready', Palette.amber),
    };
    final others = controller.devices.where((d) => d.key != selected?.key).toList();

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Palette.line),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF30334A), Palette.panel],
        ),
      ),
      child: Stack(
        children: [
          const Positioned(right: -36, top: -18, child: BeamArcs(size: 150)),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _Label('Renderer'),
                    const SizedBox(width: 10),
                    _StatusChip(text: status, color: statusColor),
                  ],
                ),
                const SizedBox(height: 14),
                if (selected != null)
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Palette.violet.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.connected_tv_rounded, color: Palette.violet),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              selected.friendlyName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Palette.ink, fontSize: 19, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                selected.modelName ?? selected.manufacturer,
                                selected.host,
                              ].whereType<String>().join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Palette.inkDim, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    controller.discovering
                        ? 'Looking for TVs, goggles and speakers on your Wi-Fi. Goggles can take a few seconds to '
                              'announce themselves.'
                        : 'Nothing answered. Turn the device on, join the same Wi-Fi, and search again.',
                    style: const TextStyle(color: Palette.inkDim, height: 1.4),
                  ),
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final device in others)
                        ActionChip(
                          avatar: const Icon(Icons.swap_horiz_rounded, size: 16, color: Palette.inkDim),
                          label: Text(device.friendlyName),
                          labelStyle: const TextStyle(color: Palette.ink, fontSize: 13),
                          backgroundColor: Palette.field,
                          side: const BorderSide(color: Palette.line),
                          shape: const StadiumBorder(),
                          onPressed: () => controller.select(device),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: Palette.inkDim),
                  onPressed: () => _addByIp(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add by IP address'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(99)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _BusyBanner extends StatelessWidget {
  const _BusyBanner({required this.text, this.onCancel});
  final String text;
  final Future<void> Function()? onCancel;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text('$text…')),
          if (onCancel case final cancel?) TextButton(onPressed: cancel, child: const Text('Cancel')),
        ],
      ),
    ),
  );
}

class _CastSection extends StatelessWidget {
  const _CastSection({required this.controller});
  final CastController controller;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.selected != null && controller.busy == null;
    void openGallery(RequestType type, String title) => Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => GalleryPage(controller: controller, type: type, title: title),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('Cast'),
        const SizedBox(height: 10),
        _ShareScreenCard(onTap: enabled ? () => showScreenShareSheet(context, controller) : null),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _CastTile(
                icon: Icons.movie_rounded,
                title: 'Videos',
                tint: Palette.amber,
                onTap: enabled ? () => openGallery(RequestType.video, 'Videos') : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CastTile(
                icon: Icons.photo_rounded,
                title: 'Photos',
                tint: Palette.violet,
                onTap: enabled ? () => openGallery(RequestType.image, 'Photos') : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CastTile(
                icon: Icons.music_note_rounded,
                title: 'Music',
                tint: Palette.coral,
                onTap: enabled ? () => openGallery(RequestType.audio, 'Music') : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The main action: an amber card in the mark's gradient, with the broadcast arcs behind it.
class _ShareScreenCard extends StatelessWidget {
  const _ShareScreenCard({this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final ink = enabled ? Palette.amberInk : Palette.inkFaint;
    return Material(
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(20),
      color: Palette.panel,
      child: Ink(
        decoration: enabled
            ? const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [beamAmberLight, beamAmberDeep],
                ),
              )
            : null,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              Positioned(
                right: -28,
                top: -10,
                child: BeamArcs(size: 120, color: enabled ? Palette.amberInk : Palette.inkFaint, opacity: 0.12),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: enabled ? Palette.amberInk : Palette.field,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.screen_share_rounded,
                        color: enabled ? beamAmberLight : Palette.inkFaint,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Share screen',
                            style: TextStyle(color: ink, fontSize: 18, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Your phone screen live, with its sound',
                            style: TextStyle(color: ink.withValues(alpha: 0.75), fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.arrow_forward_rounded, color: ink),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CastTile extends StatelessWidget {
  const _CastTile({required this.icon, required this.title, required this.tint, this.onTap});
  final IconData icon;
  final String title;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? tint : Palette.inkFaint;
    return Material(
      color: Palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Palette.line),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: TextStyle(
                  color: enabled ? Palette.ink : Palette.inkFaint,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityLog extends StatelessWidget {
  const _ActivityLog({required this.entries});
  final List<LogEntry> entries;

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      title: const Text('Activity', style: TextStyle(fontSize: 15)),
      subtitle: entries.isEmpty
          ? null
          : Text(
              entries.first.message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: entries.first.error ? Palette.coral : Palette.inkFaint, fontSize: 12.5),
            ),
      shape: const Border(),
      children: [
        for (final entry in entries.take(50))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _time(entry.at),
                  style: const TextStyle(
                    color: Palette.inkFaint,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.message,
                    style: TextStyle(color: entry.error ? Palette.coral : Palette.inkDim, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
