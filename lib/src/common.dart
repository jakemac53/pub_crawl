//  Copyright 2019 Google LLC
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import 'cache.dart';
import 'package.dart';

final _client = http.Client();

Future<String> getBody(String url) async => (await getResponse(url)).body;

Future<http.Response> getResponse(String url) async =>
    _client.get(url, headers: const {'User-Agent': 'dart.pkg.pub_crawl'});

int toInt(Object value) {
  if (value is int) {
    return value;
  }
  try {
    return int.parse(value);
  } on FormatException catch (e) {
    print('expected int value but got "$value": ${e.message}');
    rethrow;
  }
}

double toDouble(Object value) {
  if (value is double) {
    return value;
  }
  try {
    return double.parse(value);
  } on FormatException catch (e) {
    print('expected double value but got "$value": ${e.message}');
    rethrow;
  }
}

abstract class BaseCommand extends Command {
  /// Shared cache object.
  static Cache _cache;

  Cache get cache => _cache ??= Cache();

  bool get verbose => argResults['verbose'];
}

typedef PackageMatcher = bool Function(Package package);
typedef FailDescription = String Function(Package package);

class Criteria {
  final FailDescription onFail;
  final PackageMatcher matches;

  Criteria({@required this.matches, @required this.onFail});

  static List<Criteria> fromArgs(String argString) {
    if (argString == null) {
      return null;
    }
    final args = argString?.split(',') ?? <String>[];
    return args
        .map((name) => Criteria.forName(name))
        .where((c) => c != null)
        .toList();
  }

  factory Criteria.forName(String name) {
    switch (name) {
      case 'flutter':
        return Criteria(
          matches: (p) => p.dependencies?.containsKey('flutter') == true,
          onFail: (_) => 'does not use flutter',
        );
    }
    if (name.startsWith('min_score:')) {
      final score = toDouble(name.split(':')[1]);
      return Criteria(
        matches: (p) => p.overallScore >= score,
        onFail: (p) => 'score too low: ${p.overallScore}',
      );
    }
    return null;
  }
}

/// A simple visitor for analysis options files.
abstract class AnalysisOptionsVisitor {
  void visit(AnalysisOptionsFile file) {}
}

class AnalysisOptionsFile {
  final File file;

  /// Can throw a [FormatException] if yaml is malformed.
  YamlMap get yaml => _yaml ??= _readYamlFromString(contents);

  String get contents => _contents ??= file.readAsStringSync();
  String _contents;

  YamlMap _yaml;

  AnalysisOptionsFile(String path) : file = File(path);
}

/// A simple visitor for pubspec files.
abstract class PubspecFileVisitor {
  void visit(PubspecFile file) {}
}

/// A simple visitor for package roots.
abstract class PackageRootVisitor {
  void visit(Directory root) {}
}

class PubspecFile {
  final File file;

  /// Can throw a [FormatException] if yaml is malformed.
  YamlMap get yaml => _yaml ??= _readYamlFromString(contents);

  String get contents => _contents ??= file.readAsStringSync();
  String _contents;

  YamlMap _yaml;

  PubspecFile(String path) : file = File(path);
}

YamlMap _readYamlFromString(String optionsSource) {
  if (optionsSource == null) {
    return YamlMap();
  }
  try {
    final doc = loadYamlNode(optionsSource);
    if (doc is YamlMap) {
      return doc;
    }
    return YamlMap();
  } on YamlException catch (e) {
    throw FormatException(e.message, e.span);
  } catch (e) {
    throw FormatException('Unable to parse YAML document.');
  }
}
