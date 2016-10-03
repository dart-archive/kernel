// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library test.kernel.closures.suite;

import 'dart:async' show
    Future;

import 'dart:convert' show
    UTF8;

import 'dart:io' show
    Directory,
    File,
    IOSink,
    Platform,
    Process;

import 'package:analyzer/src/generated/engine.dart' show
    AnalysisContext;

import 'package:kernel/analyzer/loader.dart' show
    AnalyzerLoader,
    createContext,
    createDartSdk;

import 'package:kernel/kernel.dart' show
    Repository;

import 'package:kernel/target/targets.dart' show
    Target,
    TargetFlags,
    getTarget;

import 'package:kernel/text/ast_to_text.dart' show
    Printer;

import 'package:analyzer/src/generated/sdk.dart' show
    DartSdk;

import 'package:testing/testing.dart' show
    TestDescription;

import 'package:testing/src/test_root.dart' show
    Compilation;

import 'package:testing/src/compilation_runner.dart' show
    Result,
    Step,
    SuiteContext;

import 'package:kernel/ast.dart' show
    Library,
    Program;

import 'package:kernel/checks.dart' show
    CheckParentPointers;

import 'package:kernel/transformations/closure_conversion.dart' as
    closure_conversion;

const bool generateExpectations =
    const bool.fromEnvironment("generateExpectations");

class TestContext extends SuiteContext {
  final String sdk;

  final String packageRoot;

  final bool strongMode;

  final DartSdk dartSdk;

  final List<Step> steps = const <Step>[
      const Kernel(),
      const Print(),
      const ClosureConversion(),
      const Print(),
      const MatchExpectation<TestContext>(".expect"),
  ];

  TestContext(this.sdk, this.packageRoot, this.strongMode, this.dartSdk);

  AnalysisContext createAnalysisContext() {
    return createContext(sdk, packageRoot, strongMode, dartSdk: dartSdk);
  }
}

Future<TestContext> createSuiteContext(Compilation suite) async {
  String sdk = Platform.environment["DART_AOT_SDK"];
  if (sdk == null) {
    throw "The environment variable 'DART_AOT_SDK' isn't defined, "
        "it should point to a patched SDK.";
  }
  const String suggestion =
      "Try checking the value of environment variable 'DART_AOT_SDK', "
      "it should point to a patched SDK.";
  if (!await new Directory(sdk).exists()) {
    throw "Couldn't locate '$sdk'. $suggestion";
  }
  Future<bool> fileExists(Uri base, String path) async {
    return await new File.fromUri(base.resolve(path)).exists();
  }
  Uri sdkUri = Uri.base.resolve("$sdk/");
  if (!await fileExists(sdkUri, "lib/async/async.dart")) {
    throw "Couldn't find 'lib/async/async.dart' in '$sdk'. $suggestion";
  }
  if (await fileExists(sdkUri, "lib/async/async_sources.gypi")) {
    throw "Found 'lib/async/async_sources.gypi' in '$sdk', "
        "so it isn't a patched SDK. $suggestion";
  }
  String packageRoot = Uri.base.resolve("packages").toFilePath();
  bool strongMode = false;
  return new TestContext(
      sdk, packageRoot, strongMode, createDartSdk(sdk, strongMode));
}

class Kernel extends Step<TestDescription, Program, TestContext> {
  const Kernel();

  String get name => "kernel";

  Future<Result<Program>> run(
      TestDescription description, TestContext testContext) async {
    try {
      Repository repository = new Repository(
          sdk: testContext.sdk, packageRoot: testContext.packageRoot);
      AnalysisContext context = testContext.createAnalysisContext();
      AnalyzerLoader loader = new AnalyzerLoader(repository, context: context);
      Target target =
          getTarget("vm", new TargetFlags(strongMode: testContext.strongMode));
      Program program =
          loader.loadProgram(description.file.path, target: target);
      // TODO(ahe): Use `runSanityChecks` when merging with master.
      CheckParentPointers.check(program);
      return new Result<Program>.pass(program);
    } catch (e, s) {
      return new Result<Program>.crash(e, s);
    }
  }
}

class Print extends Step<Program, Program, TestContext> {
  const Print();

  String get name => "print";

  Future<Result<Program>> run(Program program, TestContext testContext) async {
    StringBuffer sb = new StringBuffer();
    Printer printer = new Printer(sb);
    printer.writeLibraryFile(program.mainMethod.enclosingLibrary);
    print("$sb");
    return new Result<Program>.pass(program);
  }
}

class ClosureConversion extends Step<Program, Program, TestContext> {
  const ClosureConversion();

  String get name => "closure conversion";

  Future<Result<Program>> run(Program program, TestContext testContext) async {
    try {
      program = closure_conversion.transformProgram(program);
      CheckParentPointers.check(program);
      return new Result<Program>.pass(program);
    } catch (e, s) {
      return new Result<Program>.crash(e, s);
    }
  }
}

class MatchExpectation<C extends SuiteContext> extends Step<Program, Null, C> {
  final String suffix;

  const MatchExpectation(this.suffix);

  String get name => "match expectations";

  Future<Result<Null>> run(Program program, C context) async {
    Library library = program.mainMethod.parent;
    Uri uri = library.importUri;
    StringBuffer buffer = new StringBuffer();
    new Printer(buffer).writeLibraryFile(library);

    File expectedFile = new File("${uri.toFilePath()}$suffix");
    if (await expectedFile.exists()) {
      String expected = await expectedFile.readAsString();
      if (expected.trim() != "$buffer".trim()) {
        String diff = await runDiff(expectedFile.uri, "$buffer");
        return new Result<Null>.fail(
            null, "$uri doesn't match ${expectedFile.uri}\n$diff");
      }
    } else if (generateExpectations) {
      await openWrite(expectedFile.uri, (IOSink sink) {
          sink.writeln("$buffer".trim());
        });
      return new Result<Null>.fail(null, "Generated ${expectedFile.uri}");
    } else {
      return new Result<Null>.fail(null, """
Please create file ${expectedFile.path} with this content:
$buffer""");
    }
    return new Result<Null>.pass(null);
  }
}

Future<String> runDiff(Uri expected, String actual) async {
  Process diff = await Process.start(
      "diff", <String>["-u", expected.toFilePath(), "-"]);
  diff.stdin.write(actual);
  Future closeFuture = diff.stdin.close();
  Future<List<String>> stdoutFuture =
      diff.stdout.transform(UTF8.decoder).toList();
  Future<List<String>> stderrFuture =
      diff.stderr.transform(UTF8.decoder).toList();
  StringBuffer sb = new StringBuffer();
  sb.writeAll(await stdoutFuture);
  sb.writeAll(await stderrFuture);
  await closeFuture;
  return "$sb";
}

Future openWrite(Uri uri, f(IOSink sink)) async {
  IOSink sink = new File.fromUri(uri).openWrite();
  try {
    await f(sink);
  } finally {
    await sink.close();
  }
  print("Wrote $uri");
}
