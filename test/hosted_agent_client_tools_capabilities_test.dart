import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/hosted_ai_capabilities.dart';

void main() {
  Map<String, dynamic> payload() => {
    'chat': {
      'models': ['mimo-v2.5'],
    },
    'summary': {
      'models': ['mimo-v2.5'],
    },
    'agent': {
      'available': true,
      'protocolVersion': 3,
      'clientTools': {
        'available': true,
        'version': 1,
        'models': ['mimo-v2.5'],
        'tools': ['local_search', 'read_article'],
        'limits': {
          'maxTotalCalls': 6,
          'maxLocalSearchCalls': 4,
          'maxReadArticleCalls': 4,
          'maxResultBytes': 65536,
          'leaseSeconds': 60,
          'waitSeconds': 600,
          'wallSeconds': 900,
          'localSearch': {
            'maxResults': 5,
            'maxSnippetsPerResult': 2,
            'maxResultBytes': 16384,
            'maxResultTokens': 1200,
          },
          'readArticle': {'maxResultBytes': 24576, 'maxResultTokens': 4000},
        },
      },
    },
  };

  test('accepts the exact protocol-v3 client-tools contract', () {
    final parsed = HostedAiCapabilities.fromJson(payload());
    final tools = hostedAgentClientToolsForModel(parsed, 'mimo-v2.5');

    expect(tools, isNotNull);
    expect(tools!.version, 1);
    expect(tools.tools, {'local_search', 'read_article'});
    expect(tools.localSearch.maxResults, 5);
    expect(tools.readArticle.maxResultBytes, 24576);
  });

  test('fails closed for v2, wrong model, missing nested limit or tool', () {
    final v2 = payload();
    (v2['agent'] as Map<String, dynamic>)['protocolVersion'] = 2;
    expect(HostedAiCapabilities.fromJson(v2).agentClientTools, isNull);

    final parsed = HostedAiCapabilities.fromJson(payload());
    expect(hostedAgentClientToolsForModel(parsed, 'other-model'), isNull);
    expect(hostedAgentClientToolsForModel(parsed, 'MIMO-V2.5'), isNull);

    final missing = payload();
    final limits =
        ((missing['agent'] as Map)['clientTools'] as Map)['limits'] as Map;
    (limits['localSearch'] as Map).remove('maxResultTokens');
    expect(HostedAiCapabilities.fromJson(missing).agentClientTools, isNull);

    final wrongTools = payload();
    ((wrongTools['agent'] as Map)['clientTools'] as Map)['tools'] = [
      'local_search',
    ];
    expect(HostedAiCapabilities.fromJson(wrongTools).agentClientTools, isNull);

    final extra = payload();
    ((extra['agent'] as Map)['clientTools'] as Map)['futureField'] = true;
    expect(HostedAiCapabilities.fromJson(extra).agentClientTools, isNull);
  });

  test('fails closed for unusable and inconsistent limits', () {
    final tiny = payload();
    final tinyLimits =
        ((tiny['agent'] as Map)['clientTools'] as Map)['limits'] as Map;
    tinyLimits['maxResultBytes'] = 32;
    expect(HostedAiCapabilities.fromJson(tiny).agentClientTools, isNull);

    final lease = payload();
    final leaseLimits =
        ((lease['agent'] as Map)['clientTools'] as Map)['limits'] as Map;
    leaseLimits['leaseSeconds'] = 700;
    expect(HostedAiCapabilities.fromJson(lease).agentClientTools, isNull);

    final nested = payload();
    final nestedLimits =
        ((nested['agent'] as Map)['clientTools'] as Map)['limits'] as Map;
    (nestedLimits['readArticle'] as Map)['maxResultBytes'] = 70000;
    expect(HostedAiCapabilities.fromJson(nested).agentClientTools, isNull);
  });
}
