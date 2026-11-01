import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'didl.dart';

const serverHeader = 'dlna-cast-android/0.1 UPnP/1.0 DLNADOC/1.50';

sealed class RangeResult {
  const RangeResult();
}

class ByteRange extends RangeResult {
  const ByteRange(this.start, this.end);

  /// Inclusive, like the header.
  final int start;
  final int end;

  @override
  bool operator ==(Object other) => other is ByteRange && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'ByteRange($start, $end)';
}

class Unsatisfiable extends RangeResult {
  const Unsatisfiable();
}

final _rangePattern = RegExp(r'^bytes=(\d*)-(\d*)$');

/// Returns null to serve the whole file (no, malformed or multi-range header), [Unsatisfiable], or a [ByteRange].
RangeResult? parseRange(String? header, int size) {
  if (header == null) return null;
  final match = _rangePattern.firstMatch(header.trim());
  if (match == null || (match[1] == '' && match[2] == '')) return null;
  if (match[1] == '') {
    final suffix = int.parse(match[2]!);
    if (suffix == 0 || size == 0) return const Unsatisfiable();
    return ByteRange(max(0, size - suffix), size - 1);
  }
  final start = int.parse(match[1]!);
  if (match[2] != '' && int.parse(match[2]!) < start) return null;
  if (start >= size) return const Unsatisfiable();
  final end = match[2] == '' ? size - 1 : min(int.parse(match[2]!), size - 1);
  return ByteRange(start, end);
}

String _stripMappedPrefix(String ip) => ip.startsWith('::ffff:') ? ip.substring(7) : ip;

String _nonce() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

typedef RequestReport = ({String method, String path, String? range, int status, String remote});

class MediaServerStats {
  int requests = 0;
  int bytesServed = 0;
}

/// Serves one file, with byte ranges, at an unguessable path. Only addresses in [allow] (the renderer) may fetch it.
class MediaServer {
  MediaServer._(this._server, this.url, this.mimeType, this.size, this.stats);

  final HttpServer _server;
  final String url;
  final String mimeType;
  final int size;
  final MediaServerStats stats;

  static Future<MediaServer> start({
    required File file,
    required String host,
    int port = 0,
    String? mimeType,
    List<String>? allow,
    void Function(RequestReport)? onRequest,
  }) async {
    final size = await file.length();
    final type = mimeType ?? mimeTypeFor(file.path);
    // An unguessable path so other devices on the network can't find the media.
    final mediaPath = '/media/${_nonce()}/media${extensionOf(file.path)}';
    final allowed = allow?.toSet();
    final stats = MediaServerStats();

    final server = await HttpServer.bind(host, port);
    server.defaultResponseHeaders.clear();
    server.serverHeader = serverHeader;
    server.listen((request) async {
      stats.requests++;
      final response = request.response;
      final remote = _stripMappedPrefix(request.connectionInfo?.remoteAddress.address ?? '');
      void report(int status) => onRequest?.call((
        method: request.method,
        path: request.uri.toString(),
        range: request.headers.value(HttpHeaders.rangeHeader),
        status: status,
        remote: remote,
      ));
      Future<void> reject(int status, [Map<String, String> headers = const {}]) async {
        response.statusCode = status;
        response.persistentConnection = false;
        response.contentLength = 0;
        headers.forEach((name, value) => response.headers.set(name, value, preserveHeaderCase: true));
        report(status);
        await response.close();
      }

      if (allowed != null && !allowed.contains(remote)) return reject(HttpStatus.forbidden);
      if (request.uri.path != mediaPath) return reject(HttpStatus.notFound);
      if (request.method != 'GET' && request.method != 'HEAD') {
        return reject(HttpStatus.methodNotAllowed, {'Allow': 'GET, HEAD'});
      }

      final range = parseRange(request.headers.value(HttpHeaders.rangeHeader), size);
      if (range is Unsatisfiable) {
        return reject(HttpStatus.requestedRangeNotSatisfiable, {'Content-Range': 'bytes */$size'});
      }

      final (start, end) = range is ByteRange ? (range.start, range.end) : (0, size - 1);
      final length = size == 0 ? 0 : end - start + 1;
      final status = range is ByteRange ? HttpStatus.partialContent : HttpStatus.ok;
      response.statusCode = status;
      response.contentLength = length;
      // Renderers are known to match DLNA header names case-sensitively.
      for (final (name, value) in [
        ('Content-Type', type),
        ('transferMode.dlna.org', 'Streaming'),
        ('contentFeatures.dlna.org', contentFeatures()),
        ('Accept-Ranges', 'bytes'),
        if (range is ByteRange) ('Content-Range', 'bytes $start-$end/$size'),
      ]) {
        response.headers.set(name, value, preserveHeaderCase: true);
      }
      report(status);
      if (request.method == 'HEAD' || length == 0) return response.close();

      try {
        await response.addStream(
          file.openRead(start, end + 1).map((chunk) {
            stats.bytesServed += chunk.length;
            return chunk;
          }),
        );
        await response.close();
      } catch (_) {
        // Renderers routinely drop a connection mid-file when they seek; that is not an error.
      }
    });

    return MediaServer._(server, 'http://$host:${server.port}$mediaPath', type, size, stats);
  }

  Future<void> close() => _server.close(force: true);
}
