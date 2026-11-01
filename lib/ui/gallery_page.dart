import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../cast_controller.dart';
import 'theme.dart';

const _pageSize = 60;

/// The phone's videos, photos or music from MediaStore. Tapping one casts it straight from its file, without a copy.
class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, required this.controller, required this.type, required this.title});
  final CastController controller;
  final RequestType type;
  final String title;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  final _assets = <AssetEntity>[];
  var _page = 0;
  var _loading = false;
  var _hasMore = true;
  PermissionState? _permission;

  @override
  void initState() {
    super.initState();
    _requestAndLoad();
  }

  Future<void> _requestAndLoad() async {
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: PermissionRequestOption(
        androidPermission: AndroidPermission(type: widget.type, mediaLocation: false),
      ),
    );
    if (!mounted) return;
    setState(() => _permission = permission);
    if (permission.hasAccess) await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    final page = await PhotoManager.getAssetListPaged(page: _page, pageCount: _pageSize, type: widget.type);
    if (!mounted) return;
    setState(() {
      _assets.addAll(page);
      _page++;
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _cast(AssetEntity asset) async {
    final file = await asset.originFile;
    if (file == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("This item isn't available on the phone")));
      }
      return;
    }
    final title = asset.title?.replaceFirst(RegExp(r'\.[^.]+$'), '') ?? widget.title;
    if (mounted) Navigator.pop(context);
    await switch (asset.type) {
      AssetType.image => widget.controller.castPhoto(file, title: title),
      AssetType.video => widget.controller.castVideo(file, title: title, mimeType: asset.mimeType),
      _ => widget.controller.castFile(file, title: title, mimeType: asset.mimeType),
    };
  }

  @override
  Widget build(BuildContext context) {
    final permission = _permission;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: switch (permission) {
        null => const Center(child: CircularProgressIndicator()),
        PermissionState(hasAccess: false) => _NoAccess(onOpenSettings: PhotoManager.openSetting),
        _ when _assets.isEmpty && !_loading => Center(
          child: Text('No ${widget.title.toLowerCase()} on this phone', style: const TextStyle(color: Palette.inkDim)),
        ),
        _ => NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 600) _loadMore();
            return false;
          },
          child: widget.type == RequestType.audio ? _musicList() : _grid(),
        ),
      },
    );
  }

  Widget _grid() => GridView.builder(
    padding: const EdgeInsets.all(4),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 130,
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
    ),
    itemCount: _assets.length,
    itemBuilder: (context, index) => _Thumbnail(asset: _assets[index], onTap: () => _cast(_assets[index])),
  );

  Widget _musicList() => ListView.builder(
    itemCount: _assets.length,
    itemBuilder: (context, index) {
      final asset = _assets[index];
      return ListTile(
        leading: const Icon(Icons.music_note, color: Palette.amber),
        title: Text(asset.title ?? 'Track', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(_duration(asset.duration), style: const TextStyle(color: Palette.inkFaint)),
        onTap: () => _cast(asset),
      );
    },
  );
}

String _duration(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.asset, required this.onTap});
  final AssetEntity asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<Uint8List?>(
          future: asset.thumbnailDataWithSize(const ThumbnailSize.square(240)),
          builder: (context, snapshot) => snapshot.data == null
              ? const ColoredBox(color: Palette.field)
              : Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true),
        ),
        if (asset.type == AssetType.video)
          Positioned(
            right: 4,
            bottom: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(_duration(asset.duration), style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          ),
      ],
    ),
  );
}

class _NoAccess extends StatelessWidget {
  const _NoAccess({required this.onOpenSettings});
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'dlna-cast needs access to your media to cast it.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Palette.inkDim),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: onOpenSettings, child: const Text('Open settings')),
        ],
      ),
    ),
  );
}
