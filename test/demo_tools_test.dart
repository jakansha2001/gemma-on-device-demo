import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_vision_demo/gemma/demo_tools.dart';

/// The model controls every argument these tools receive, so the contract that
/// matters is: whatever comes in, `execute` returns a map and never throws.
void main() {
  late ToolWorkspace workspace;

  setUp(() => workspace = ToolWorkspace());

  Map<String, dynamic> call(String name, [Map<String, dynamic> args = const {}]) =>
      DemoTools.execute(
        FunctionCallResponse(name: name, args: args),
        workspace,
      );

  group('calculate', () {
    test('evaluates precedence and parentheses', () {
      expect(call('calculate', {'expression': '2 + 3 * 4'})['result'], 14);
      expect(call('calculate', {'expression': '(2 + 3) * 4'})['result'], 20);
      expect(call('calculate', {'expression': '-5 + 8'})['result'], 3);
    });

    test('keeps genuine decimals but tidies whole results', () {
      expect(call('calculate', {'expression': '1840 * 0.18'})['result'], 331.2);
      expect(call('calculate', {'expression': '10 / 2'})['result'], 5);
    });

    test('returns an error value rather than throwing', () {
      // Each of these would be an exception escaping into the generation
      // stream if execute() did not contain it.
      for (final bad in ['2 +', '((1)', 'DROP TABLE users', '1/0', '']) {
        final result = call('calculate', {'expression': bad});
        expect(result.containsKey('error'), isTrue, reason: 'input: "$bad"');
      }
    });

    test('missing argument is reported, not crashed on', () {
      expect(call('calculate').containsKey('error'), isTrue);
    });
  });

  group('add_task', () {
    test('adds a task and reports the running total', () {
      final result = call('add_task', {'title': 'Rehearse'});
      expect(result['ok'], isTrue);
      expect(result['total_tasks'], 1);
      expect(workspace.tasks.single.title, 'Rehearse');
      expect(workspace.tasks.single.done, isFalse);
    });

    test('rejects an empty or missing title', () {
      expect(call('add_task', {'title': '   '}).containsKey('error'), isTrue);
      expect(call('add_task').containsKey('error'), isTrue);
      expect(workspace.tasks, isEmpty);
    });

    test('survives a wrongly typed argument', () {
      // A model that emits a number where a string was declared must not
      // produce a TypeError.
      final result = call('add_task', {'title': 42});
      expect(result['ok'], isTrue);
      expect(workspace.tasks.single.title, '42');
    });
  });

  group('list_tasks', () {
    test('reads back what add_task wrote — the sequential-call path', () {
      call('add_task', {'title': 'buy milk'});
      call('add_task', {'title': 'book tickets'});
      final result = call('list_tasks');
      expect(result['count'], 2);
      expect(result['pending'], 2);
      expect(
        (result['tasks'] as List).map((t) => (t as Map)['title']),
        ['buy milk', 'book tickets'],
      );
    });

    test('is safe on an empty list', () {
      final result = call('list_tasks');
      expect(result['count'], 0);
      expect(result['tasks'], isEmpty);
    });
  });

  group('complete_task', () {
    setUp(() => call('add_task', {'title': 'buy milk'}));

    test('matches an abbreviated name', () {
      final result = call('complete_task', {'title': 'milk'});
      expect(result['completed'], 'buy milk');
      expect(workspace.tasks.single.done, isTrue);
      expect(result['pending'], 0);
    });

    test('matches an expanded name', () {
      expect(call('complete_task', {'title': 'buy the milk'})['ok'], isTrue);
    });

    test('is idempotent', () {
      call('complete_task', {'title': 'milk'});
      expect(call('complete_task', {'title': 'milk'})['already_done'], 'buy milk');
    });

    test('does not match an unrelated task on one shared filler word', () {
      call('add_task', {'title': 'buy tickets'});
      // "buy" alone must not be enough to pick either task confidently.
      final result = call('complete_task', {'title': 'buy a car'});
      expect(result.containsKey('error'), isTrue);
    });

    test('hands back the real list when nothing matches', () {
      final result = call('complete_task', {'title': 'walk the dog'});
      expect(result['error'], contains('walk the dog'));
      expect(result['available'], ['buy milk']);
    });
  });

  group('edge cases the model can actually cause', () {
    test('a duplicate add is absorbed, not duplicated', () {
      call('add_task', {'title': 'buy milk'});
      final result = call('add_task', {'title': 'Buy Milk'});
      expect(result['already_present'], 'buy milk');
      expect(workspace.tasks, hasLength(1));
    });

    test('an over-long title is refused, not rendered', () {
      final result = call('add_task', {'title': 'x' * 500});
      expect(result['error'], contains('too long'));
      expect(workspace.tasks, isEmpty);
    });

    test('the list cannot grow without bound', () {
      for (var i = 0; i < DemoTools.maxTasks + 5; i++) {
        call('add_task', {'title': 'task $i'});
      }
      expect(workspace.tasks, hasLength(DemoTools.maxTasks));
      expect(call('add_task', {'title': 'one more'})['error'], contains('full'));
    });

    test('an ambiguous complete refuses to guess', () {
      call('add_task', {'title': 'call mum'});
      call('add_task', {'title': 'call the bank'});
      final result = call('complete_task', {'title': 'call'});
      expect(result['error'], contains('several'));
      expect(result['matches'], hasLength(2));
      expect(workspace.tasks.every((t) => !t.done), isTrue);
    });

    test('a deeply nested expression cannot blow the stack', () {
      final bomb = '${'(' * 5000}1${')' * 5000}';
      final result = call('calculate', {'expression': bomb});
      expect(result['error'], contains('too long'));
    });

    test('division by zero is an error value, not a crash', () {
      expect(call('calculate', {'expression': '5/0'})['error'], isNotNull);
    });
  });

  group('set_accent_color', () {
    test('accepts a known color', () {
      expect(call('set_accent_color', {'color': 'Purple'})['ok'], isTrue);
    });

    test('accepts a hex value the model volunteered', () {
      expect(call('set_accent_color', {'color': '#ff0000'})['ok'], isTrue);
      expect(call('set_accent_color', {'color': '00FF00'})['ok'], isTrue);
    });

    test('lists the supported colors when given a bad one', () {
      final result = call('set_accent_color', {'color': 'chartreuse'});
      expect(result['error'], contains('chartreuse'));
      expect(result['supported'], isA<List<String>>());
    });
  });

  group('get_current_time', () {
    test('returns a parseable timestamp', () {
      final result = call('get_current_time');
      expect(DateTime.tryParse(result['iso8601'] as String), isNotNull);
      expect(result['time_24h'], matches(RegExp(r'^\d{2}:\d{2}$')));
    });
  });

  test('an invented tool name is reported with the real list', () {
    final result = call('order_a_pizza');
    expect(result['error'], contains('order_a_pizza'));
    expect(result['available'], containsAll(['calculate', 'add_task']));
  });

  test('every declaration is a valid JSON Schema object', () {
    for (final tool in DemoTools.declarations) {
      expect(tool.name, isNotEmpty);
      expect(tool.description, isNotEmpty);
      expect(tool.parameters['type'], 'object');
      expect(tool.parameters['properties'], isA<Map<String, dynamic>>());
    }
  });
}
