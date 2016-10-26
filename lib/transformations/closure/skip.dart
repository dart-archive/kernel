// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO(ahe): Delete this file, eventually all procedures should be converted.
library kernel.transformations.closure_conversion.skip;

import '../../ast.dart' show
    Class,
    Procedure;

/// Set of fully-qualified names of procedures that we don't perform closure
/// conversion on. Set is represented as a map as that can be a compile-time
/// constant.
const Map<String, int> skippedProcedures = const <String, int>{
  // TODO(ahe): This triggers an assertion about a VariableDeclaration in a
  // try-catch statement, fix that.
  "dart:async::_Future::_chainForeignFuture": 0,
};

/// Returns true if [node] should be closure converted.
bool convertClosures(Procedure node) {
  String lib = "${node.enclosingLibrary.importUri}";
  String name = node.name.name;
  String fqn = node.parent is Class
      ? "$lib::${node.enclosingClass.name}::$name"
      : "$lib::$name";
  return !skippedProcedures.containsKey(fqn);
}
