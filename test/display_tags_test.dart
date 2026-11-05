import 'package:flutter_test/flutter_test.dart';
import 'package:singlet/utils/display_tags.dart';

void main() {
  test('strips singlet- and sbg- prefixes in rule strings', () {
    expect(
      DisplayTags.sanitize(
        'rule_set=singlet-geosite-cn => route(direct)',
      ),
      'rule_set=geosite-cn => route(direct)',
    );
    expect(
      DisplayTags.sanitize('sbg-geoip-cn'),
      'geoip-cn',
    );
    expect(DisplayTags.sanitize('final'), 'final');
  });
}
