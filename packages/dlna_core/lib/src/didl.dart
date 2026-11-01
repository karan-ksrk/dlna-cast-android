import 'xml.dart';

const _mimeTypes = {
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.3gp': 'video/3gpp',
  '.mov': 'video/quicktime',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm',
  '.avi': 'video/x-msvideo',
  '.ts': 'video/mp2t',
  '.m2ts': 'video/mp2t',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.flac': 'audio/flac',
  '.wav': 'audio/wav',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/ogg',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
};

String extensionOf(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

String mimeTypeFor(String path) => _mimeTypes[extensionOf(path)] ?? 'application/octet-stream';

/// Files: OP=01 (byte-range seeking); flags for streaming transfer, background transfer, connection stall, DLNA 1.5.
const dlnaFileFlags = '01700000000000000000000000000000';

/// Live: OP=00 (no seeking), CI=1 (transcoded); flags add sender-paced, as DLNA describes for live streams.
const dlnaLiveFlags = '8D100000000000000000000000000000';

String contentFeatures({bool live = false}) => live
    ? 'DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=$dlnaLiveFlags'
    : 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$dlnaFileFlags';

String _upnpClass(String mimeType) {
  if (mimeType.startsWith('audio/')) return 'object.item.audioItem.musicTrack';
  if (mimeType.startsWith('image/')) return 'object.item.imageItem.photo';
  return 'object.item.videoItem';
}

String buildDidl({required String url, required String title, required String mimeType, int? size, bool live = false}) {
  final sizeAttribute = size != null ? ' size="$size"' : '';
  return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1">'
      '<dc:title>${xmlEscape(title)}</dc:title>'
      '<upnp:class>${_upnpClass(mimeType)}</upnp:class>'
      '<res protocolInfo="http-get:*:${xmlEscape(mimeType)}:${contentFeatures(live: live)}"$sizeAttribute>'
      '${xmlEscape(url)}</res>'
      '</item></DIDL-Lite>';
}
