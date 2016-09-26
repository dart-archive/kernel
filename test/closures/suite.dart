// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library test.kernel.closures.suite;

import 'dart:async' show
    Future;

import 'dart:io' show
    Platform;

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
    Program;

class TestContext extends SuiteContext {
  final String sdk;

  final String packageRoot;

  final bool strongMode;

  final DartSdk dartSdk;

  final List<Step> steps = const <Step>[
      const Kernel(),
      const Print(),
  ];

  TestContext(this.sdk, this.packageRoot, this.strongMode, this.dartSdk);

  AnalysisContext createAnalysisContext() {
    return createContext(sdk, packageRoot, strongMode, dartSdk: dartSdk);
  }
}

Future<TestContext> createSuiteContext(Compilation suite) async {
  String sdk = Platform.environment["DART_AOT_SDK"];
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
      return new Result.pass(program);
    } catch (e, s) {
      return new Result.crash(e, s);
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
