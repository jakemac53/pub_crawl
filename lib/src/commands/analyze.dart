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

import 'dart:async';
import 'dart:io' as io;
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/generated/engine.dart' // ignore: implementation_imports
    show
        AnalysisEngine,
        AnalysisErrorInfo,
        AnalysisErrorInfoImpl;
import 'package:analyzer/src/generated/source.dart'; // ignore: implementation_imports
import 'package:args/args.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;

import '../../hooks/criteria/analyze.dart';
import '../../hooks/visitors/dart.dart';
import '../../hooks/visitors/options.dart';
import '../../hooks/visitors/package.dart';
import '../../hooks/visitors/pubspec.dart';
import '../common.dart';

class AnalyzeCommand extends BaseCommand {
  // todo (pq): move this into cache object add it to .gitignore?
  static final Directory cacheDir = io.Directory('third_party/cache');
  static final String cachePath = cacheDir.absolute.path;

  @override
  String get description => 'analyze packages.';

  @override
  String get name => 'analyze';

  bool get color => argResults['color'];

  AnalyzeCommand() {
    argParser.addFlag('verbose', help: 'verbose output.');
    argParser.addFlag('color', help: 'color output.');

    argParser.addFlag('install',
        negatable: true,
        defaultsTo: true,
        help: 'install package dependencies.');
    argParser.addFlag('no-errors', help: 'do not report analysis errors.');
  }

  bool get showErrors => !argResults['no-errors'];

  @override
  @mustCallSuper
  FutureOr run() async {
    // todo (pq): check for commandline-defined criteria.
    final criteria = defaultAnalyzeCriteria;
    final packages = cache.list(matching: criteria);

    final visitor = PackageVisitor();
    for (final package in packages) {
      visitor.visit(cache.getSourceDir(package));
    }
    visitor.postVisit();

    await _analyze(packages.map((p) => '$cachePath/${p.sourcePath}').toList());

    return Future.value();
  }

  Future _analyze(List<String> sourceDirs) async {
    if (sourceDirs.isEmpty) {
      print('Specify one or more files and directories.');
      return;
    }
    ResourceProvider resourceProvider = PhysicalResourceProvider.INSTANCE;
    final results = await _analyzeFiles(resourceProvider, sourceDirs);
    print('Finished.');
    if (showErrors) {
      _printAnalysisResults(results);
    }
  }

  /// Hook to influence context before analysis.
  void preAnalyze(AnalysisContext context) {}

  final visitor = AstVisitor();

  Future<List<ErrorsResult>> _analyzeFiles(
      ResourceProvider resourceProvider, List<String> analysisRoots) async {
    final results = <ErrorsResult>[];
    final collection = AnalysisContextCollection(
        includedPaths: analysisRoots, resourceProvider: resourceProvider);
    for (var context in collection.contexts) {
      final relativePath =
          context.contextRoot.root.path.split('$cachePath/')[1];

      print('$commandVerb $relativePath...');

      preAnalyze(context);

      for (var filePath in context.contextRoot.analyzedFiles()) {
        if (AnalysisEngine.isDartFileName(filePath)) {
          if (showErrors) {
            final result = await context.currentSession.getErrors(filePath);
            if (result.errors.isNotEmpty) {
              results.add(result);
            }
          }

          // todo (pq): move this up and collect errors from the resolved result.
          final result = await context.currentSession.getResolvedUnit(filePath);

          // AST Visitor callback.
          result.unit.accept(visitor);
        }

        if (AnalysisEngine.isAnalysisOptionsFileName(filePath)) {
          // Options Visitor callback.
          final optionsFile = AnalysisOptionsFile(filePath);
          OptionsVisitor().visit(optionsFile);
        }

        if (path.basename(filePath) == 'pubspec.yaml') {
          // Pubspec Visitor callback.
          final pubspec = PubspecFile(filePath);
          PubspecVisitor().visit(pubspec);
        }
      }
    }
    visitor.onVisitFinish();

    return results;
  }

  void _printAnalysisResults(List<ErrorsResult> results) {
    final infos = <AnalysisErrorInfo>[];
    for (var result in results) {
      final errors = result.errors.where(showError).toList();
      if (errors.isNotEmpty) {
        infos.add(AnalysisErrorInfoImpl(errors, result.lineInfo));
      }
    }
    final stats = AnalysisStats();
    final options = CommandLineOptions.fromArgs(argResults);
    final formatter = HumanErrorFormatter(io.stdout, options, stats);
    formatter.formatErrors(infos);
    formatter.flush();
    stats.print();
  }

  bool showError(AnalysisError element) => true;

  String get commandVerb => 'Analyzing';
}

final Map<String, int> _severityCompare = {
  'error': 5,
  'warning': 4,
  'info': 3,
  'lint': 2,
  'hint': 1,
};

String _pluralize(String word, int count) => count == 1 ? word : '${word}s';

/// Given an absolute path, return a relative path if the file is contained in
/// the current directory; return the original path otherwise.
String _relative(String file) =>
    file.startsWith(path.current) ? path.relative(file) : file;

/// Returns the given error's severity.
ErrorSeverity _severityIdentity(AnalysisError error) =>
    error.errorCode.errorSeverity;

/// Returns desired severity for the given [error] (or `null` if it's to be
/// suppressed).
typedef SeverityProcessor = ErrorSeverity Function(AnalysisError error);

/// Analysis statistics counter.
class AnalysisStats {
  int unfilteredCount = 0;

  int errorCount = 0;
  int hintCount = 0;
  int lintCount = 0;
  int warnCount = 0;

  AnalysisStats();

  /// The total number of diagnostics reported to the user.
  int get filteredCount => errorCount + warnCount + hintCount + lintCount;

  /// Print statistics to [out].
  void print([StringSink out]) {
    out ??= io.stdout;
    final hasErrors = errorCount != 0;
    final hasWarns = warnCount != 0;
    final hasHints = hintCount != 0;
    final hasLints = lintCount != 0;
    var hasContent = false;
    if (hasErrors) {
      out.write(errorCount);
      out.write(' ');
      out.write(_pluralize('error', errorCount));
      hasContent = true;
    }
    if (hasWarns) {
      if (hasContent) {
        if (!hasHints && !hasLints) {
          out.write(' and ');
        } else {
          out.write(', ');
        }
      }
      out.write(warnCount);
      out.write(' ');
      out.write(_pluralize('warning', warnCount));
      hasContent = true;
    }
    if (hasLints) {
      if (hasContent) {
        out.write(hasHints ? ', ' : ' and ');
      }
      out.write(lintCount);
      out.write(' ');
      out.write(_pluralize('lint', lintCount));
      hasContent = true;
    }
    if (hasHints) {
      if (hasContent) {
        out.write(' and ');
      }
      out.write(hintCount);
      out.write(' ');
      out.write(_pluralize('hint', hintCount));
      hasContent = true;
    }
    if (hasContent) {
      out.writeln(' found.');
    } else {
      out.writeln('No issues found!');
    }
  }
}

/// Helper for formatting [AnalysisError]s.
///
/// The two format options are a user consumable format and a machine consumable
/// format.
abstract class ErrorFormatter {
  final StringSink out;
  final CommandLineOptions options;
  final AnalysisStats stats;
  SeverityProcessor _severityProcessor;

  ErrorFormatter(this.out, this.options, this.stats,
      {SeverityProcessor severityProcessor}) {
    _severityProcessor = severityProcessor ?? _severityIdentity;
  }

  /// Call to write any batched up errors from [formatErrors].
  void flush();

  void formatError(
      Map<AnalysisError, LineInfo> errorToLine, AnalysisError error);

  void formatErrors(List<AnalysisErrorInfo> errorInfos) {
    stats.unfilteredCount += errorInfos.length;

    final errors = <AnalysisError>[];
    final errorToLine = <AnalysisError, LineInfo>{};
    for (var errorInfo in errorInfos) {
      for (var error in errorInfo.errors) {
        if (_computeSeverity(error) != null) {
          errors.add(error);
          errorToLine[error] = errorInfo.lineInfo;
        }
      }
    }

    for (var error in errors) {
      formatError(errorToLine, error);
    }
  }

  /// Compute the severity for this [error] or `null` if this error should be
  /// filtered.
  ErrorSeverity _computeSeverity(AnalysisError error) =>
      _severityProcessor(error);
}

class AnsiLogger {
  final bool useAnsi;

  AnsiLogger(this.useAnsi);
  String get blue => _code('\u001b[34m');
  String get bold => _code('\u001b[1m');
  String get bullet => !Platform.isWindows ? '•' : '-';
  String get cyan => _code('\u001b[36m');
  String get gray => _code('\u001b[1;30m');
  String get green => _code('\u001b[32m');
  String get magenta => _code('\u001b[35m');
  String get noColor => _code('\u001b[39m');
  String get none => _code('\u001b[0m');

  String get red => _code('\u001b[31m');

  String get yellow => _code('\u001b[33m');

  String _code(String ansiCode) => useAnsi ? ansiCode : '';
}

/// An [AnalysisError] with line and column information.
class CLIError implements Comparable<CLIError> {
  final String severity;
  final String sourcePath;
  final int offset;
  final int line;
  final int column;
  final String message;
  final String errorCode;
  final String correction;

  CLIError({
    this.severity,
    this.sourcePath,
    this.offset,
    this.line,
    this.column,
    this.message,
    this.errorCode,
    this.correction,
  });

  @override
  int get hashCode =>
      severity.hashCode ^ sourcePath.hashCode ^ errorCode.hashCode ^ offset;
  bool get isError => severity == 'error';
  bool get isHint => severity == 'hint';
  bool get isLint => severity == 'lint';

  bool get isWarning => severity == 'warning';

  @override
  bool operator ==(other) {
    if (other is! CLIError) return false;

    return severity == other.severity &&
        sourcePath == other.sourcePath &&
        errorCode == other.errorCode &&
        offset == other.offset;
  }

  @override
  int compareTo(CLIError other) {
    // severity
    var compare = _severityCompare[other.severity] - _severityCompare[severity];
    if (compare != 0) return compare;

    // path
    compare = Comparable.compare(
        sourcePath.toLowerCase(), other.sourcePath.toLowerCase());
    if (compare != 0) return compare;

    // offset
    return offset - other.offset;
  }
}

class CommandLineOptions {
  /// Emit output in a verbose mode.
  final bool verbose;

  /// Use ANSI color codes for output.
  final bool color;

  CommandLineOptions({this.verbose = false, this.color = false});

  CommandLineOptions.fromArgs(ArgResults args)
      : this(verbose: args['verbose'], color: args['color']);
}

class HumanErrorFormatter extends ErrorFormatter {
  AnsiLogger ansi;

  // This is a Set in order to de-dup CLI errors.
  final Set<CLIError> batchedErrors = {};

  HumanErrorFormatter(
      StringSink out, CommandLineOptions options, AnalysisStats stats,
      {SeverityProcessor severityProcessor})
      : super(out, options, stats, severityProcessor: severityProcessor) {
    ansi = AnsiLogger(this.options.color);
  }

  @override
  void flush() {
    // sort
    final sortedErrors = batchedErrors.toList()..sort();

    // print
    for (var error in sortedErrors) {
      if (error.isError) {
        stats.errorCount++;
      } else if (error.isWarning) {
        stats.warnCount++;
      } else if (error.isLint) {
        stats.lintCount++;
      } else if (error.isHint) {
        stats.hintCount++;
      }

      // warning • 'foo' is not a bar at lib/foo.dart:1:2 • foo_warning
      final issueColor = (error.isError || error.isWarning) ? ansi.red : '';
      out.write('  $issueColor${error.severity}${ansi.none} '
          '${ansi.bullet} ${ansi.bold}${error.message}${ansi.none} ');
      out.write('at ${error.sourcePath}');
      out.write(':${error.line}:${error.column} ');
      out.write('${ansi.bullet} ${error.errorCode}');
      out.writeln();

      // If verbose, also print any associated correction.
      if (options.verbose && error.correction != null) {
        out.writeln(
            '${' '.padLeft(error.severity.length + 2)}${error.correction}');
      }
    }

    // clear out batched errors
    batchedErrors.clear();
  }

  @override
  void formatError(
      Map<AnalysisError, LineInfo> errorToLine, AnalysisError error) {
    final source = error.source;
    var location = errorToLine[error].getLocation(error.offset);

    final severity = _severityProcessor(error);

    // Get display name; translate INFOs into LINTS and HINTS.
    var errorType = severity.displayName;
    if (severity == ErrorSeverity.INFO) {
      if (error.errorCode.type == ErrorType.HINT ||
          error.errorCode.type == ErrorType.LINT) {
        errorType = error.errorCode.type.displayName;
      }
    }

    // warning • 'foo' is not a bar at lib/foo.dart:1:2 • foo_warning
    var message = error.message;
    // Remove any terminating '.' from the end of the message.
    if (message.endsWith('.')) {
      message = message.substring(0, message.length - 1);
    }
    String sourcePath;
    if (source.uriKind == UriKind.DART_URI) {
      sourcePath = source.uri.toString();
    } else if (source.uriKind == UriKind.PACKAGE_URI) {
      sourcePath = _relative(source.fullName);
      if (sourcePath == source.fullName) {
        // If we weren't able to shorten the path name, use the package: version.
        sourcePath = source.uri.toString();
      }
    } else {
      sourcePath = _relative(source.fullName);
    }

    batchedErrors.add(CLIError(
      severity: errorType,
      sourcePath: sourcePath,
      offset: error.offset,
      line: location.lineNumber,
      column: location.columnNumber,
      message: message,
      errorCode: error.errorCode.name.toLowerCase(),
      correction: error.correction,
    ));
  }
}
