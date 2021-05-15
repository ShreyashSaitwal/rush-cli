import 'dart:io' show stdin;

import 'package:dart_console/dart_console.dart';
import 'package:rush_prompt/rush_prompt.dart';

class BoolQuestion extends Question {
  String? _question;

  BoolQuestion({
    required String id,
    required String question,
  }) {
    this.id = id;
    _question = question;
  }

  @override
  List<dynamic> ask() {
    var suffix = '(Y/N)';
    var answer;

    console
      ..setForegroundColor(ConsoleColor.green)
      ..write('? ')
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..write('$_question $suffix ')
      ..setForegroundColor(ConsoleColor.cyan);

    var input = stdin.readLineSync();
    final validYesAnswers = ['y', 'yes', 'yeah', 'yep', 'ya', 'ye'];
    final validNoAnswers = ['n', 'no', 'nope', 'nah', 'never'];

    if (validYesAnswers.contains(input!.toLowerCase())) {
      answer = true;
    } else if (validNoAnswers.contains(input.toLowerCase())) {
      answer = false;
    } else {
      return ask();
    }

    console.resetColorAttributes();
    return [id, answer];
  }
}
