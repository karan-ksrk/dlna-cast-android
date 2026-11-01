import 'dart:io';

final _ipv4Pattern = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

bool isIPv4(String ip) {
  final match = _ipv4Pattern.firstMatch(ip);
  return match != null && [1, 2, 3, 4].every((i) => int.parse(match[i]!) <= 255);
}

/// Private, loopback, link-local and carrier-grade NAT IPv4 ranges.
bool isLanAddress(String ip) {
  if (!isIPv4(ip)) return false;
  final [a, b, ...] = ip.split('.').map(int.parse).toList();
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254) ||
      (a == 100 && b >= 64 && b <= 127);
}

class LanInterface {
  const LanInterface(this.name, this.address, this.networkInterface);
  final String name;
  final InternetAddress address;
  final NetworkInterface networkInterface;
}

/// Non-loopback IPv4 interfaces on a LAN address. On a phone that is usually just `wlan0` (and `ap0` when the
/// phone is a hotspot); mobile data has a public or CGNAT address and is filtered out unless it is CGNAT.
Future<List<LanInterface>> lanInterfaces() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  return [
    for (final ni in interfaces)
      for (final address in ni.addresses)
        if (!address.isLoopback && isLanAddress(address.address)) LanInterface(ni.name, address, ni),
  ];
}

/// The local address a device can reach us on: the interface sharing its subnet, else the first LAN interface.
Future<String?> localAddressFor(String remoteIp) async {
  if (remoteIp.startsWith('127.')) return '127.0.0.1';
  return pickLocalAddress(remoteIp, [for (final i in await lanInterfaces()) i.address.address]);
}

/// Dart doesn't expose netmasks (and a client Socket's `address` is the remote one), so the subnet match is
/// approximated by the longest common bit prefix, the way a routing table picks a route.
String? pickLocalAddress(String remoteIp, List<String> candidates) {
  if (candidates.isEmpty) return null;
  final remote = _toUint32(remoteIp);
  int sharedBits(String ip) {
    final diff = _toUint32(ip) ^ remote;
    return diff == 0 ? 32 : 32 - diff.bitLength;
  }

  var best = candidates.first;
  for (final candidate in candidates.skip(1)) {
    if (sharedBits(candidate) > sharedBits(best)) best = candidate;
  }
  return best;
}

int _toUint32(String ip) => ip.split('.').map(int.parse).fold(0, (value, octet) => (value << 8) | octet);
