import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test('normalizes secure endpoint input', () {
    final endpoint = ValidatedEndpoint.parse('https://nas.example:8443');
    expect(
      endpoint.connectionUri.toString(),
      'wss://nas.example:8443/api/current',
    );
  });

  test('preserves original input and normalizes default paths', () {
    final endpoint = ValidatedEndpoint.parse(' wss://nas.example/ ');
    expect(endpoint.originalInput, ' wss://nas.example/ ');
    expect(endpoint.connectionUri.toString(), 'wss://nas.example/api/current');
    expect(
      ValidatedEndpoint.parse('wss://nas.example/custom/api').connectionUri
          .toString(),
      'wss://nas.example/custom/api',
    );
  });

  for (final input in [
    'http://nas.example',
    'ws://nas.example',
    'https://user@nas.example',
    'https://nas.example?a=b',
    'https://nas.example#part',
    'https:///api/current',
  ]) {
    test('rejects insecure or structurally unsafe input: $input', () {
      expect(
        () => ValidatedEndpoint.parse(input),
        throwsA(isA<EndpointValidationException>()),
      );
    });
  }
}
