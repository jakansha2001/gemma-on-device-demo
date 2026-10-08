import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:gemma_vision_demo/theme.dart';

/// One item on the model-managed to-do list.
@immutable
class DemoTask {
  const DemoTask({required this.title, this.done = false});

  final String title;
  final bool done;

  DemoTask complete() => DemoTask(title: title, done: true);
}

/// Mutable state the tools act on — owned by the screen and passed in, so the
/// tool implementations stay pure functions of (args, state).
class ToolWorkspace {
  final List<DemoTask> tasks = [];
  Color accent = AppColors.tool;

  int get openCount => tasks.where((t) => !t.done).length;
}

/// The tool declarations handed to the model, and the Dart that runs them.
///
/// Worth being precise about who does what: flutter_edge_ai **parses** the
/// model's call into a [FunctionCallResponse] and drives the loop, but it
/// never executes anything. Tools are app actions, so running them — and
/// deciding what a failure looks like — is entirely our job. That is why
/// [execute] catches everything and returns an error *value*: an exception
/// thrown here would tear down the generation stream, whereas an
/// `{'error': ...}` map goes back to the model, which can then apologise,
/// correct itself or try a different call.
///
/// The set is deliberately shaped so tools **compose**. `add_task` and
/// `complete_task` mutate the list; `list_tasks` reads it back. Asking
/// "add buy milk, then tell me what's on my list" makes the model call two
/// tools in sequence in a single turn — which is the interesting thing to
/// demonstrate, and something a single self-contained tool cannot show.
abstract final class DemoTools {
  /// Guard rails on model-supplied values. The model can call these tools in
  /// a loop, so every unbounded quantity is a way for it to wedge the app:
  /// a 10 000-character title destroys the layout, an ever-growing list bloats
  /// the context that `list_tasks` feeds back, and deeply nested parentheses
  /// recurse `_Arithmetic` into a stack overflow.
  static const maxTitleLength = 120;
  static const maxTasks = 25;
  static const maxExpressionLength = 200;

  static const declarations = <Tool>[
    Tool(
      name: 'add_task',
      description:
          'Add one task to the user\'s on-screen to-do list. Use this whenever '
          'the user wants to remember, track, add or schedule something. '
          'Never ask the user to repeat the task name — take it from what '
          'they already said.',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            // Spelling out the extraction is what stops the model calling this
            // with an empty title and then asking the user for one they
            // already gave. Small models take descriptions literally; a worked
            // example is worth more than an adjective.
            'description':
                'The activity itself, taken verbatim from the user. For '
                '"add working out to my list" the title is "working out".',
          },
        },
        'required': ['title'],
      },
    ),
    Tool(
      name: 'list_tasks',
      description:
          'Read back every task currently on the list, with its done/pending '
          'state. Call this before answering any question about what is on '
          'the list, how many tasks there are, or what is left to do — never '
          'guess, and never rely on memory of earlier turns.',
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
    ),
    Tool(
      name: 'complete_task',
      description:
          'Mark a task on the list as done. Match the task the user names, '
          'even if they abbreviate it.',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description':
                'The task to mark done. A partial name is fine — "milk" '
                'matches "buy milk".',
          },
        },
        'required': ['title'],
      },
    ),
    Tool(
      name: 'set_accent_color',
      description:
          'Change the accent color of the app interface. Use when the user '
          'asks to recolor or restyle the app.',
      parameters: {
        'type': 'object',
        'properties': {
          'color': {
            'type': 'string',
            'description':
                'One of: red, orange, yellow, green, teal, blue, purple, pink',
          },
        },
        'required': ['color'],
      },
    ),
    Tool(
      name: 'get_current_time',
      description:
          'Get the current date and time from the device clock. Use this '
          'instead of guessing — you have no reliable sense of the time.',
      // Explicitly typed: a bare `{}` here would infer as
      // Map<dynamic, dynamic>, which is the wrong shape for something that
      // gets serialized into the model's tool declarations.
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
    ),
    Tool(
      name: 'calculate',
      description:
          'Evaluate an arithmetic expression exactly. Supports + - * / and '
          'parentheses. Prefer this over doing mental arithmetic.',
      parameters: {
        'type': 'object',
        'properties': {
          'expression': {
            'type': 'string',
            'description': 'e.g. "(1200 * 0.18) + 45"',
          },
        },
        'required': ['expression'],
      },
    ),
  ];

  /// The colours `set_accent_color` understands by name.
  ///
  /// Only jade and sand belong to the app's own palette; the rest are extra
  /// tints kept light enough to stay readable on a warm near-black. They have
  /// to match the colour the person actually asked for — saying "make it
  /// purple" and getting green reads as a broken demo, not a styled one.
  static const _palette = <String, Color>{
    'red': AppColors.danger,
    'orange': Color(0xFFF09A4B),
    'yellow': AppColors.warning,
    'green': AppColors.accent,
    'teal': Color(0xFF4FD1C5),
    'blue': Color(0xFF6AA9FF),
    'purple': Color(0xFFB197FC),
    'pink': Color(0xFFFF8BBD),
  };

  /// Run one call. Never throws — see the class doc.
  static Map<String, dynamic> execute(
    FunctionCallResponse call,
    ToolWorkspace workspace,
  ) {
    try {
      switch (call.name) {
        case 'add_task':
          // The model controls these values, so treat them as untrusted input:
          // a missing or wrongly-typed arg must not crash the app.
          final title = _string(call.args['title']);
          if (title == null) {
            return {'error': 'title is required and cannot be empty'};
          }
          if (title.length > maxTitleLength) {
            return {
              'error': 'title is too long (max $maxTitleLength characters)',
            };
          }
          if (workspace.tasks.length >= maxTasks) {
            return {
              'error': 'the list is full (max $maxTasks tasks)',
              'hint': 'complete or remove a task first',
            };
          }
          // Adding the same thing twice is almost always the model
          // double-calling, not the user wanting two identical tasks — and it
          // makes complete_task ambiguous afterwards.
          final duplicate = workspace.tasks.indexWhere(
            (t) => t.title.toLowerCase() == title.toLowerCase(),
          );
          if (duplicate != -1) {
            return {
              'ok': true,
              'already_present': workspace.tasks[duplicate].title,
              'total_tasks': workspace.tasks.length,
              'pending': workspace.openCount,
            };
          }
          workspace.tasks.add(DemoTask(title: title));
          return {
            'ok': true,
            'added': title,
            'total_tasks': workspace.tasks.length,
            'pending': workspace.openCount,
          };

        case 'list_tasks':
          return {
            'count': workspace.tasks.length,
            'pending': workspace.openCount,
            'tasks': [
              for (final t in workspace.tasks)
                {'title': t.title, 'done': t.done},
            ],
          };

        case 'complete_task':
          final query = _string(call.args['title']);
          if (query == null) {
            return {'error': 'title is required'};
          }
          final matches = _findTasks(workspace, query);
          if (matches.length > 1) {
            // Two tasks match equally well. Picking one silently would mark
            // the wrong thing done; let the model disambiguate with the user.
            return {
              'error': 'several tasks match "$query"',
              'matches': [for (final i in matches) workspace.tasks[i].title],
              'hint': 'ask the user which one they meant',
            };
          }
          final index = matches.isEmpty ? -1 : matches.first;
          if (index == -1) {
            // Hand back the real list so the model can correct itself on the
            // next turn instead of inventing a task.
            return {
              'error': 'no task matching "$query"',
              'available': [for (final t in workspace.tasks) t.title],
            };
          }
          if (workspace.tasks[index].done) {
            return {'ok': true, 'already_done': workspace.tasks[index].title};
          }
          workspace.tasks[index] = workspace.tasks[index].complete();
          return {
            'ok': true,
            'completed': workspace.tasks[index].title,
            'pending': workspace.openCount,
          };

        case 'set_accent_color':
          final name = _string(call.args['color'])?.toLowerCase();
          var color = _palette[name];
          // Models reach for hex constantly even when the description lists
          // names. Accepting it is friendlier than a wasted tool round-trip.
          color ??= _parseHex(name);
          if (color == null) {
            return {
              'error': 'unknown color "$name"',
              'supported': _palette.keys.toList(),
            };
          }
          workspace.accent = color;
          return {'ok': true, 'accent': name};

        case 'get_current_time':
          final now = DateTime.now();
          return {
            'iso8601': now.toIso8601String(),
            'readable':
                '${_weekday(now)}, ${now.day} ${_month(now)} ${now.year}',
            'time_24h':
                '${now.hour.toString().padLeft(2, '0')}:'
                '${now.minute.toString().padLeft(2, '0')}',
            'timezone_offset_minutes': now.timeZoneOffset.inMinutes,
          };

        case 'calculate':
          final expr = _string(call.args['expression']);
          if (expr == null) return {'error': 'expression is required'};
          if (expr.length > maxExpressionLength) {
            return {
              'error':
                  'expression is too long '
                  '(max $maxExpressionLength characters)',
            };
          }
          return {'expression': expr, 'result': _Arithmetic(expr).evaluate()};

        default:
          // The model invented a tool. Tell it so, rather than failing.
          return {
            'error': 'unknown tool "${call.name}"',
            'available': declarations.map((t) => t.name).toList(),
          };
      }
    } catch (e) {
      return {'error': '$e'};
    }
  }

  /// Coerce an untrusted arg to a non-empty string, or null.
  static String? _string(Object? value) {
    final text = value?.toString().trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  /// `#rrggbb`, `rrggbb`, or `#aarrggbb`.
  static Color? _parseHex(String? raw) {
    if (raw == null) return null;
    final hex = raw.replaceAll('#', '').trim();
    if (hex.length != 6 && hex.length != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return Color(hex.length == 6 ? 0xFF000000 | value : value);
  }

  /// Find every task the user could have meant.
  ///
  /// Exact match, then substring, then word overlap. The third tier handles
  /// the common real case: the model says "buy the milk" for a task stored as
  /// "buy milk". Neither contains the other as a substring, so substring
  /// matching alone silently fails and the model is told it does not exist.
  ///
  /// Returns every equally-good candidate so the caller can refuse to guess
  /// when there is more than one.
  static List<int> _findTasks(ToolWorkspace workspace, String query) {
    final q = query.toLowerCase().trim();

    final exact = <int>[
      for (var i = 0; i < workspace.tasks.length; i++)
        if (workspace.tasks[i].title.toLowerCase() == q) i,
    ];
    if (exact.isNotEmpty) return exact;

    final substring = <int>[
      for (var i = 0; i < workspace.tasks.length; i++)
        if (workspace.tasks[i].title.toLowerCase().contains(q) ||
            q.contains(workspace.tasks[i].title.toLowerCase()))
          i,
    ];
    if (substring.isNotEmpty) return substring;

    // Ignore filler words so "buy the milk" and "buy milk" agree.
    const stopWords = {'the', 'a', 'an', 'my', 'to', 'of', 'for', 'and'};
    Set<String> meaningfulWords(String text) => text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.isNotEmpty && !stopWords.contains(w))
        .toSet();

    final queryWords = meaningfulWords(q);
    if (queryWords.isEmpty) return const [];

    var best = 0.0;
    final scored = <int, double>{};
    for (var i = 0; i < workspace.tasks.length; i++) {
      final taskWords = meaningfulWords(workspace.tasks[i].title);
      if (taskWords.isEmpty) continue;
      final shared = taskWords.intersection(queryWords).length;
      if (shared == 0) continue;
      // Score against whichever side is shorter, so a terse query still
      // matches a wordy task and vice versa.
      final score =
          shared /
          (taskWords.length < queryWords.length
              ? taskWords.length
              : queryWords.length);
      scored[i] = score;
      if (score > best) best = score;
    }
    // Require a clear majority: one shared word out of five is a coincidence.
    if (best < 0.6) return const [];
    return [
      for (final entry in scored.entries)
        if (entry.value == best) entry.key,
    ];
  }

  static String _weekday(DateTime d) => const [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ][d.weekday - 1];

  static String _month(DateTime d) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][d.month - 1];
}

/// Minimal recursive-descent arithmetic parser.
///
/// Dart has no `eval`, and pulling in an expression library for four operators
/// is not worth it. This accepts only digits, `. + - * / ( )` and whitespace —
/// anything else throws, which [DemoTools.execute] turns into an error value.
class _Arithmetic {
  _Arithmetic(this._src);

  final String _src;
  int _pos = 0;

  num evaluate() {
    final value = _expression();
    _skipSpace();
    if (_pos != _src.length) {
      throw FormatException('Unexpected character at position $_pos', _src);
    }
    if (value.isNaN || value.isInfinite) {
      throw const FormatException('Result is not a finite number');
    }
    // Present 7.0 as 7, but keep genuine decimals.
    return value == value.roundToDouble() && value.abs() < 1e15
        ? value.round()
        : value;
  }

  double _expression() {
    var left = _term();
    while (true) {
      _skipSpace();
      if (_eat('+')) {
        left += _term();
      } else if (_eat('-')) {
        left -= _term();
      } else {
        return left;
      }
    }
  }

  double _term() {
    var left = _factor();
    while (true) {
      _skipSpace();
      if (_eat('*')) {
        left *= _factor();
      } else if (_eat('/')) {
        final divisor = _factor();
        if (divisor == 0) throw const FormatException('Division by zero');
        left /= divisor;
      } else {
        return left;
      }
    }
  }

  double _factor() {
    _skipSpace();
    if (_eat('-')) return -_factor();
    if (_eat('+')) return _factor();
    if (_eat('(')) {
      final value = _expression();
      _skipSpace();
      if (!_eat(')')) throw const FormatException('Unbalanced parentheses');
      return value;
    }
    final start = _pos;
    while (_pos < _src.length &&
        (_isDigit(_src.codeUnitAt(_pos)) || _src[_pos] == '.')) {
      _pos++;
    }
    if (start == _pos) {
      throw FormatException('Expected a number at position $_pos', _src);
    }
    final text = _src.substring(start, _pos);
    final parsed = double.tryParse(text);
    if (parsed == null) throw FormatException('Bad number "$text"', _src);
    return parsed;
  }

  bool _eat(String ch) {
    _skipSpace();
    if (_pos < _src.length && _src[_pos] == ch) {
      _pos++;
      return true;
    }
    return false;
  }

  void _skipSpace() {
    while (_pos < _src.length && _src[_pos].trim().isEmpty) {
      _pos++;
    }
  }

  static bool _isDigit(int code) => code >= 0x30 && code <= 0x39;
}
