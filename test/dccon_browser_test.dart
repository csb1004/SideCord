import 'dart:convert';

import 'package:emotion_cord/dccon_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'loadLatest uses the first listing request as the session request',
    () async {
      var latestRequests = 0;
      final client = DcconClient(
        client: MockClient((request) async {
          if (request.url.path == '/new/1') {
            latestRequests += 1;
            return http.Response(
              '''
            <ul>
              <li class="div_package" package_idx="1">
                <strong class="dcon_name">신규콘</strong>
              </li>
            </ul>
            ''',
              200,
              headers: {
                'content-type': 'text/html; charset=utf-8',
                'set-cookie': 'ci_c=session-token; path=/',
              },
            );
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(client.close);

      final packages = await client.loadLatest();

      expect(latestRequests, 1);
      expect(packages.single.title, '신규콘');
    },
  );

  test('search parses dccon package cards', () async {
    final client = DcconClient(
      client: MockClient((request) async {
        if (request.url.path == '/new/1') {
          return http.Response(
            '<html></html>',
            200,
            headers: {'set-cookie': 'ci_c=session-token; path=/'},
          );
        }
        if (request.url.path.startsWith('/hot/1/title/')) {
          return http.Response(
            '''
            <ul>
              <li class="div_package " package_idx="99492">
                <img class="thumb_img" src="//dcimg5.dcinside.com/dccon.php?no=thumb_path">
                <strong class="dcon_name">해외야구 동물콘</strong>
                <span class="dcon_seller">Lincecum</span>
              </li>
            </ul>
            ''',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(client.close);

    final packages = await client.search('야구');

    expect(packages, hasLength(1));
    expect(packages.single.id, '99492');
    expect(packages.single.title, '해외야구 동물콘');
    expect(packages.single.seller, 'Lincecum');
    expect(
      packages.single.thumbnailUrl,
      'https://dcimg5.dcinside.com/dccon.php?no=thumb_path',
    );
  });

  test('loadPopular parses jsonp ranking packages', () async {
    final client = DcconClient(
      client: MockClient((request) async {
        if (request.url.host == 'json2.dcinside.com' &&
            request.url.path == '/json1/dccon_day_top100.php') {
          return http.Response(
            '''
            cb([
              {
                "package_idx": "171367",
                "title": "밤우 스피키콘 2",
                "nick_name": "밤우",
                "img": "//dcimg5.dcinside.com/dccon.php?no=thumb_path"
              }
            ])
            ''',
            200,
            headers: {'content-type': 'application/javascript; charset=utf-8'},
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(client.close);

    final packages = await client.loadPopular(DcconListMode.daily);

    expect(packages, hasLength(1));
    expect(packages.single.id, '171367');
    expect(packages.single.title, '밤우 스피키콘 2');
    expect(packages.single.seller, '밤우');
    expect(
      packages.single.thumbnailUrl,
      'https://dcimg5.dcinside.com/dccon.php?no=thumb_path',
    );
  });

  test('loadDetail posts session token and maps icons', () async {
    var postedSessionToken = '';
    var postedCookieHeader = '';
    final client = DcconClient(
      client: MockClient((request) async {
        if (request.url.path == '/new/1') {
          return http.Response(
            '<html></html>',
            200,
            headers: {
              'set-cookie':
                  'PHPSESSID=abc; path=/; HttpOnly, '
                  'ci_c=session-token; expires=Mon, 08-Jun-2026 19:25:21 GMT; '
                  'Max-Age=7200; path=/',
            },
          );
        }
        if (request.url.path == '/index/package_detail') {
          postedSessionToken = request.bodyFields['ci_t'] ?? '';
          postedCookieHeader = request.headers['cookie'] ?? '';
          expect(request.bodyFields['package_idx'], '172078');
          return http.Response(
            jsonEncode({
              'info': {
                'title': '이상낙원 컷신',
                'seller_name': '성설',
                'description': 'ㅇㅅㅇ',
                'main_img_path': 'main_path',
              },
              'detail': [
                {'title': '1', 'ext': 'gif', 'path': 'icon_path'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(client.close);

    final detail = await client.loadDetail(
      const DcconPackage(
        id: '172078',
        title: 'fallback',
        seller: 'fallback seller',
        thumbnailUrl: 'fallback_thumb',
      ),
    );

    expect(postedSessionToken, 'session-token');
    expect(postedCookieHeader, contains('ci_c=session-token'));
    expect(postedCookieHeader, isNot(contains('Max-Age')));
    expect(detail.package.title, '이상낙원 컷신');
    expect(detail.package.seller, '성설');
    expect(detail.package.thumbnailUrl, contains('dccon.php?no=main_path'));
    expect(detail.description, 'ㅇㅅㅇ');
    expect(detail.icons, hasLength(1));
    expect(detail.icons.single.extension, 'gif');
    expect(detail.icons.single.imageUrl, contains('dccon.php?no=icon_path'));
  });

  group('DcconInstallStore', () {
    const package = DcconPackage(
      id: '42',
      title: '업데이트 테스트콘',
      seller: 'tester',
      thumbnailUrl: 'thumb',
    );
    const icons = [
      DcconIcon(title: 'one', imageUrl: 'https://image/1', extension: 'png'),
      DcconIcon(title: 'two', imageUrl: 'https://image/2', extension: 'png'),
      DcconIcon(title: 'three', imageUrl: 'https://image/3', extension: 'gif'),
    ];

    test('uses recorded URLs to return only newly added icons', () async {
      SharedPreferences.setMockInitialValues({
        'image_folders': jsonEncode({
          '업데이트 테스트콘': ['one.png', 'two.png'],
        }),
        'dccon_packages': jsonEncode({
          '42': {
            'folderName': '업데이트 테스트콘',
            'importedUrls': ['https://image/1', 'https://image/2'],
          },
        }),
      });

      final status = await DcconInstallStore().statusFor(package, icons);

      expect(status.installed, isTrue);
      expect(status.installedIcons, icons.take(2));
      expect(status.missingIcons, [icons.last]);
    });

    test(
      'treats legacy folder items as the beginning of the package',
      () async {
        SharedPreferences.setMockInitialValues({
          'image_folders': jsonEncode({
            '업데이트 테스트콘': ['legacy-one.png', 'legacy-two.png'],
          }),
        });

        final status = await DcconInstallStore().statusFor(package, icons);

        expect(status.installed, isTrue);
        expect(status.installedIcons, icons.take(2));
        expect(status.missingIcons, [icons.last]);
      },
    );

    test('recordImport merges existing and downloaded icon URLs', () async {
      SharedPreferences.setMockInitialValues({});
      final store = DcconInstallStore();

      await store.recordImport(
        package,
        [icons.last],
        catalogIcons: icons,
        existingIcons: icons.take(2).toList(),
      );
      final status = await store.statusFor(package, icons);

      expect(status.installedIcons, icons);
      expect(status.missingIcons, isEmpty);
    });
  });
}
