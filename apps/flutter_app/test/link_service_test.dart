import 'package:arcade_clipboard/models.dart';
import 'package:arcade_clipboard/services/link_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_fakes/fake_core_api.dart';

ClipboardItem photo({int size = 100}) => ClipboardItem(
    id: 'photo',
    originDevice: 'phone',
    sourceName: 'Phone',
    createdAt: DateTime.now(),
    text: '',
    kind: 'image',
    pinned: false,
    size: size);

Map<String, dynamic> offer({String? reason, int? max}) => {
      'peer': 'arcade.look',
      'action': 'look.preview',
      'title': 'Quick Look',
      'shortcut': 'Q',
      'available': reason == null,
      'reason': reason,
      'max_bytes': max,
      'limit_reason': 'Too large for Arcade Look (limit 16 MB).',
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('launch mode stays separate from preferences and connection toggles',
      () {
    final core = FakeCoreApi(hasMesh: false);
    expect(
        LinkService(core).settings('CTRL+SHIFT+SPACE')['mode'], 'foreground');
    expect(
        LinkService(core, startedInBackground: true)
            .settings('CTRL+SHIFT+SPACE')['mode'],
        'background');
  });
  testWidgets(
      'late peers update cached actions; absent, toggled and limited entries stay safe',
      (tester) async {
    final core = FakeCoreApi(hasMesh: true);
    final service = LinkService(core);
    addTearDown(service.close);
    await service.load();
    service.listen();
    await tester.pumpAndSettle();
    expect(service.actionsFor(photo()), isEmpty);
    core.linkOffers = {
      'image': [offer(max: 16 * 1024 * 1024)]
    };
    core.sendLinkEvent({'kind': 'registry_changed'});
    await tester.pumpAndSettle();
    final calls = core.calls.length;
    expect(service.actionsFor(photo()).single.title, 'Quick Look');
    expect(core.calls.length, calls); // A menu read makes no core calls.
    expect(service.actionsFor(photo(size: 17 * 1024 * 1024)).single.enabled,
        isFalse);
    expect(service.actionsFor(photo(), private: true).single.disabledReason,
        'Arcade Clipboard is in Private mode.');
    await service.setPeerEnabled('arcade.look', false, 'CTRL+SHIFT+SPACE');
    expect(service.actionsFor(photo()), isEmpty);
    await service.setPeerEnabled('arcade.look', true, 'CTRL+SHIFT+SPACE');
    core.linkOffers = {
      'image': [
        offer(reason: "Arcade Look can't do this yet: preview is disabled.")
      ]
    };
    await service.refresh();
    expect(service.actionsFor(photo()), isEmpty);
    core.linkShortcuts = [
      {'name': 'Arcade Box', 'accelerator': 'Alt+Control+Space'}
    ];
    await service.refresh();
    expect(service.shortcutOwner('CTRL+ALT+SPACE'), 'Arcade Box');
    expect(service.shortcutOwner('CTRL+SHIFT+SPACE'), isNull);
    await service.setEnabled(false, 'CTRL+SHIFT+SPACE');
    expect(service.actionsFor(photo()), isEmpty);
  });

  testWidgets(
      'an immediate completion before the request acknowledgement is retained',
      (tester) async {
    final core = FakeCoreApi(hasMesh: true);
    final service = LinkService(core);
    addTearDown(service.close);
    service.listen();
    await tester.pumpAndSettle();
    core.replies['link_invoke'] = (_) async {
      core.sendLinkEvent({
        'kind': 'invoke_done',
        'request': 42,
        'result': {'message': 'Previewing'}
      });
      await Future<void>.value();
      return {'request': 42};
    };
    final result =
        await service.invoke(LinkItemAction(offer()), itemId: 'photo');
    expect((result['result'] as Map)['message'], 'Previewing');
    expect(service.busy, isFalse);
  });
}
