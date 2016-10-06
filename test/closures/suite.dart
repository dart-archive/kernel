// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library test.kernel.closures.suite;

import 'dart:async' show
    Future;

import 'dart:io' show
    Directory,
    File,
    IOSink,
    Platform;

import 'package:analyzer/src/generated/sdk.dart' show
    DartSdk;

import 'package:kernel/analyzer/loader.dart' show
    DartLoader,
    DartOptions,
    createDartSdk;

import 'package:kernel/kernel.dart' show
    loadProgramFromBinary;

import 'package:kernel/target/targets.dart' show
    Target,
    TargetFlags,
    getTarget;

import 'package:kernel/text/ast_to_text.dart' show
    Printer;

import 'package:kernel/repository.dart' show
    Repository;

import 'package:testing/testing.dart' show
    Chain,
    ChainContext,
    Result,
    StdioProcess,
    Step,
    TestDescription;

import 'package:kernel/ast.dart' show
    Library,
    Program;

import 'package:kernel/checks.dart' show
    runSanityChecks;

import 'package:kernel/transformations/closure_conversion.dart' as
    closure_conversion;

import 'package:kernel/binary/ast_to_binary.dart' show
    BinaryPrinter;

import 'package:package_config/discovery.dart' show
    loadPackagesFile;

const bool generateExpectations =
    const bool.fromEnvironment("generateExpectations");

class TestContext extends ChainContext {
  final Uri vm;

  final Uri packages;

  final DartOptions options;

  final DartSdk dartSdk;

  final List<Step> steps = const <Step>[
      const Kernel(),
      const Print(),
      const ClosureConversion(),
      const Print(),
      const MatchExpectation<TestContext>(".expect"),
      const WriteDill(),
      const ReadDill(),
      const Run(),
  ];

  TestContext(String sdk, this.vm, Uri packages, bool strongMode,
      this.dartSdk)
      : packages = packages,
        options = new DartOptions(strongMode: strongMode, sdk: sdk,
            packagePath: packages.toFilePath());

  Future<DartLoader> createLoader() async {
    Repository repository = new Repository();
    return new DartLoader(repository, options, await loadPackagesFile(packages),
        dartSdk: dartSdk);
  }
}

enum Environment {
  directory,
  file,
}

Future<String> getEnvironmentVariable(
    String name, Environment kind, String undefined, notFound(String n)) async {
  String result = Platform.environment[name];
  if (result == null) {
    throw undefined;
  }
  switch (kind) {
    case Environment.directory:
      if (!await new Directory(result).exists()) throw notFound(result);
      break;

    case Environment.file:
      if (!await new File(result).exists()) throw notFound(result);
      break;
  }
  return result;
}

Future<bool> fileExists(Uri base, String path) async {
  return await new File.fromUri(base.resolve(path)).exists();
}

Future<TestContext> createContext(Chain suite) async {
  const String suggestion =
      "Try checking the value of environment variable 'DART_AOT_SDK', "
      "it should point to a patched SDK.";
  String sdk = await getEnvironmentVariable(
      "DART_AOT_SDK", Environment.directory,
      "Please define environment variable 'DART_AOT_SDK' to point to a "
      "patched SDK.",
      (String n) => "Couldn't locate '$n'. $suggestion");
  Uri sdkUri = Uri.base.resolve("$sdk/");
  const String asyncDart = "lib/async/async.dart";
  if (!await fileExists(sdkUri, asyncDart)) {
    throw "Couldn't find '$asyncDart' in '$sdk'. $suggestion";
  }
  const String asyncSources = "lib/async/async_sources.gypi";
  if (await fileExists(sdkUri, asyncSources)) {
    throw "Found '$asyncSources' in '$sdk', so it isn't a patched SDK. "
        "$suggestion";
  }

  String vmPath = await getEnvironmentVariable("DART_AOT_VM", Environment.file,
      "Please define environment variable 'DART_AOT_VM' to point to a "
      "Dart VM that reads .dill files.",
      (String n) => "Couldn't locate '$n'. Please check the value of "
          "environment variable 'DART_AOT_VM', it should point to a "
          "Dart VM that reads .dill files.");
  Uri vm = Uri.base.resolve(vmPath);

  Uri packages = Uri.base.resolve(".packages");
  bool strongMode = false;
  return new TestContext(sdk, vm, packages, strongMode,
      createDartSdk(sdk, strongMode: strongMode));
}

class Kernel extends Step<TestDescription, Program, TestContext> {
  const Kernel();

  String get name => "kernel";

  Future<Result<Program>> run(
      TestDescription description, TestContext testContext) async {
    try {
      DartLoader loader = await testContext.createLoader();
      Target target = getTarget(
          "vm", new TargetFlags(strongMode: testContext.options.strongMode));
      Program program =
          loader.loadProgram(description.file.path, target: target);
      for (var error in loader.errors) {
        return new Result<Program>.fail(program, "$error");
      }
      target.transformProgram(program);
      runSanityChecks(program);
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
      runSanityChecks(program);
      return new Result<Program>.pass(program);
    } catch (e, s) {
      return new Result<Program>.crash(e, s);
    }
  }
}

class MatchExpectation<C extends ChainContext>
    extends Step<Program, Program, C> {
  final String suffix;

  const MatchExpectation(this.suffix);

  String get name => "match expectations";

  Future<Result<Program>> run(Program program, C context) async {
    Library library = program.mainMethod.parent;
    Uri uri = library.importUri;
    StringBuffer buffer = new StringBuffer();
    new Printer(buffer).writeLibraryFile(library);

    File expectedFile = new File("${uri.toFilePath()}$suffix");
    if (await expectedFile.exists()) {
      String expected = await expectedFile.readAsString();
      if (expected.trim() != "$buffer".trim()) {
        String diff = await runDiff(expectedFile.uri, "$buffer");
        return new Result<Program>.fail(
            null, "$uri doesn't match ${expectedFile.uri}\n$diff");
      }
    } else if (generateExpectations) {
      await openWrite(expectedFile.uri, (IOSink sink) {
          sink.writeln("$buffer".trim());
        });
      return new Result<Program>.fail(program, "Generated ${expectedFile.uri}");
    } else {
      return new Result<Program>.fail(program, """
Please create file ${expectedFile.path} with this content:
$buffer""");
    }
    return new Result<Program>.pass(program);
  }
}

class WriteDill extends Step<Program, Uri, TestContext> {
  const WriteDill();

  String get name => "write .dill";

  Future<Result<Uri>> run(Program program, TestContext context) async {
    Directory tmp = await Directory.systemTemp.createTemp();
    Uri uri = tmp.uri.resolve("generated.dill");
    File generated = new File.fromUri(uri);
    IOSink sink = generated.openWrite();
    try {
      new BinaryPrinter(sink).writeProgramFile(program);
    } catch (e, s) {
      return new Result<Uri>.fail(uri, e, s);
    } finally {
      print("Wrote `${generated.path}`");
      await sink.close();
    }
    return new Result<Uri>.pass(uri);
  }
}

class ReadDill extends Step<Uri, Uri, TestContext> {
  const ReadDill();

  String get name => "read .dill";

  Future<Result<Uri>> run(Uri uri, TestContext context) async {
    try {
      loadProgramFromBinary(uri.toFilePath());
    } catch (e, s) {
      return new Result<Uri>.fail(uri, e, s);
    }
    return new Result<Uri>.pass(uri);
  }
}

class Run extends Step<Uri, int, TestContext> {
  const Run();

  String get name => "run";

  Future<Result<int>> run(Uri uri, TestContext context) async {
    File generated = new File.fromUri(uri);
    StdioProcess process;
    try {
      process = await StdioProcess.run(
          context.vm.toFilePath(), [generated.path, "Hello, World!"]);
    } finally {
      generated.parent.delete(recursive: true);
    }
    return process.toResult();
  }
}

Future<String> runDiff(Uri expected, String actual) async {
  StdioProcess process = await StdioProcess.run(
      "diff", <String>["-u", expected.toFilePath(), "-"], input: actual);
  return process.output;
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
