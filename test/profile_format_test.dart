import 'package:flutter_test/flutter_test.dart';
import 'package:singlet/services/subscription_service.dart';
import 'package:singlet/utils/profile_format.dart';

void main() {
  test('traffic and relative time formatting', () {
    expect(
      ProfileFormat.trafficLine(used: 197 * 1024 * 1024 * 1024, total: 260 * 1024 * 1024 * 1024),
      contains('GB'),
    );
    final now = DateTime(2026, 11, 3, 14);
    final past = now.subtract(const Duration(hours: 3));
    expect(ProfileFormat.relativeTime(past, now: now), '3 小时前');
    expect(ProfileFormat.expirePill(DateTime(2026, 11, 13)), '2026-11-13');
  });

  test('parses subscription-userinfo header', () {
    final info = SubscriptionService.parseSubscriptionUserInfo({
      'subscription-userinfo':
          'upload=100; download=200; total=1000; expire=1794240000',
    });
    expect(info, isNotNull);
    expect(info!.upload, 100);
    expect(info.download, 200);
    expect(info.total, 1000);
    expect(info.expire, 1794240000);
    expect(info.expireAt, isNotNull);
  });
}
