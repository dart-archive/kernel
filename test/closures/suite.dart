// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library test.kernel.closures.suite;

import 'dart:async' show
    Future;

import 'package:testing/src/test_root.dart' show
    Compilation;

import 'package:testing/src/compilation_runner.dart' show
    Step,
    SuiteContext;

class TestContext extends SuiteContext {
  final List<Step> steps = const <Step>[];
}

Future<TestContext> createSuiteContext(Compilation suite) async {
  return new TestContext();
}
