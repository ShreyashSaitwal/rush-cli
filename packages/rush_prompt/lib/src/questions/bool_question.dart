import 'dart:io' show stdin;

import 'package:dart_console/dart_console.dart';
import 'package:rush_prompt/rush_prompt.dart';

class BoolQuestion extends Question {
  String? _question;
  bool? _default;

  BoolQuestion({
    required String id,
    required String question,
    bool? defaultAnswer,
  }) {
    this.id = id;
    _question = question;
    _default = defaultAnswer;
  }

  @override
  List<dynamic> ask() {
    var suffix = '(Y/N)';
    var answer;

    if (_default != null && _default!) {
      suffix = '(Y/n)';
      answer = true;
    } else if (_default != null && !_default!) {
      suffix = '(y/N)';
      answer = false;
    }

    console
      ..setForegroundColor(ConsoleColor.green)
      ..write('? ')
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..write('$_question $suffix ')
      ..setForegroundColor(ConsoleColor.cyan);

    var input = stdin.readLineSync();
    final validYesAnswers = ['y', 'yes', 'yeah', 'yep', 'ya', 'ye'];
    final validNoAnswers = ['n', 'no', 'nah', 'never'];

    while (true) {
      if (validYesAnswers.contains(input!.toLowerCase())) {
        answer = true;
        break;
      } else if (validNoAnswers.contains(input.toLowerCase())) {
        answer = false;
        break;
      } else {
        console
          ..setForegroundColor(ConsoleColor.brightWhite)
          ..writeLine('Please enter a valid answer.')
          ..setForegroundColor(ConsoleColor.green)
          ..write('? ')
          ..setForegroundColor(ConsoleColor.brightWhite)
          ..write('$_question $suffix ')
          ..setForegroundColor(ConsoleColor.blue);

        input = stdin.readLineSync();
      }
    }

    console.resetColorAttributes();
    return [id, answer];
  }
}
