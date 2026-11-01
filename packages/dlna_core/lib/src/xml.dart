// Namespace-prefix-tolerant lookups. Enough for UPnP descriptions and SOAP replies; not a general XML parser.

const _namedEntities = {'lt': '<', 'gt': '>', 'amp': '&', 'quot': '"', 'apos': "'"};
final _entityPattern = RegExp(r'&(#x[0-9a-f]+|#\d+|lt|gt|amp|quot|apos);', caseSensitive: false);

String decodeXml(String text) => text.replaceAllMapped(_entityPattern, (match) {
  final entity = match[1]!;
  if (entity[0] != '#') return _namedEntities[entity.toLowerCase()]!;
  final hex = entity[1].toLowerCase() == 'x';
  return String.fromCharCode(hex ? int.parse(entity.substring(2), radix: 16) : int.parse(entity.substring(1)));
});

String xmlEscape(Object value) => value
    .toString()
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

RegExp _elementPattern(String tag) => RegExp('<(?:[\\w-]+:)?$tag(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[\\w-]+:)?$tag>');

String? elementContent(String xml, String tag) => _elementPattern(tag).firstMatch(xml)?[1];

List<String> elementBlocks(String xml, String tag) => _elementPattern(tag).allMatches(xml).map((m) => m[1]!).toList();

final _cdataPattern = RegExp(r'^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$');

String? elementText(String xml, String tag) {
  final content = elementContent(xml, tag);
  if (content == null) return null;
  final cdata = _cdataPattern.firstMatch(content);
  return cdata != null ? cdata[1] : decodeXml(content.trim());
}
