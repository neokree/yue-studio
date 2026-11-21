import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/engine/protocol.dart';

void main() {
  test('generate request json matches PROTOCOL.md', () {
    const r = GenerateRequest(job: 'j1', out: '/o', style: 's', lyrics: 'l', cot: CotMode.melody, seed: 7);
    expect(r.toJson(), {'type': 'generate', 'job': 'j1', 'out': '/o', 'style': 's', 'lyrics': 'l', 'cot': 'melody', 'seed': 7});
    expect(const GenerateRequest(job: 'j', out: '/o', style: 's', lyrics: 'l', cot: CotMode.full, seed: 1, abc: 'X:1').toJson()['abc'], 'X:1');
  });

  test('other requests', () {
    expect(const TranscribeRequest(job: 'j', audio: '/a.wav', out: '/o', mode: 'melody').toJson(),
        {'type': 'transcribe', 'job': 'j', 'audio': '/a.wav', 'out': '/o', 'mode': 'melody'});
    expect(const CancelRequest('j').toJson(), {'type': 'cancel', 'job': 'j'});
    expect(const ShutdownRequest().toJson(), {'type': 'shutdown'});
  });

  EngineEvent parse(String line) => EngineEvent.fromJson(jsonDecode(line) as Map<String, dynamic>);

  test('events parse, extra fields ignored', () {
    expect(parse('{"type":"ready","version":1,"fake":true,"x":1}'), isA<ReadyEvent>().having((e) => e.fake, 'fake', true));
    final p = parse('{"type":"progress","job":"j","stage":"nar","done":3,"total":10}') as ProgressEvent;
    expect((p.stage, p.done, p.total), ('nar', 3, 10));
    expect((parse('{"type":"progress","job":"j","stage":"abc","done":25,"total":null}') as ProgressEvent).total, isNull);
    final r = parse('{"type":"result","job":"j","dir":"/d","audio":"audio.wav","seed":5,"duration":1.5}') as ResultEvent;
    expect((r.dir, r.audio, r.seed, r.duration), ('/d', 'audio.wav', 5, 1.5));
    final e = parse('{"type":"error","job":null,"message":"busy","cancelled":false}') as ErrorEvent;
    expect((e.job, e.message, e.cancelled), (null, 'busy', false));
    expect(r.timings, isNull);
    final t = parse('{"type":"result","job":"j","dir":"/d","timings":{"load":0,"abc":17.5,"nar":80}}') as ResultEvent;
    expect(t.timings, {'load': 0.0, 'abc': 17.5, 'nar': 80.0});
    expect((r.engine, t.engine), (null, null));
    String? eng(String ar) => (parse('{"type":"result","job":"j","dir":"/d","engine":{"ar":"$ar","nar":"torch"}}') as ResultEvent).engine;
    expect((eng('mlx-q8'), eng('mlx-bf16'), eng('torch')), ('mlx', 'mlx', 'torch'));
    expect(parse('{"type":"future"}'), isA<UnknownEvent>());
  });
}
